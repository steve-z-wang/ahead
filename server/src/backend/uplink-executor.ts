import { BackendComponents, MutationSettlement } from './backend-options';
import { BackendWriteContext, PrincipalUpload } from './context';
import {
  LocalSyncIdentityError,
  LocalSyncMutationRejected,
  LocalSyncMutationVersionUnsupported,
  LocalSyncOwnerMismatchError,
  LocalSyncProtocolError,
  LocalSyncSequenceError,
  machineName,
} from './errors';
import {
  MutationDescriptor,
  MutationInputContract,
  MutationSlotDescriptor,
  SyncFieldDescriptor,
  SyncModelShape,
} from './model-binding';
import {
  UplinkMutationEnvelope,
  decodeUplinkRequestEnvelope,
  encodeUplinkResponseEnvelope,
} from './json-envelope';
import { precheckSlotBindings } from './slot-binding-precheck';
import { normalizeScopes } from './scopes';
import { hashUplinkSemanticRequest } from './uplink-receipt';

const maximumSignedInt64 = (1n << 63n) - 1n;
const maximumBatchMutations = 20;

export interface UplinkExecutor {
  execute(input: PrincipalUpload): Promise<Uint8Array>;
}

export function createUplinkExecutor<TTx>(
  components: BackendComponents<TTx>,
): UplinkExecutor {
  return new DefaultUplinkExecutor(components);
}

class DefaultUplinkExecutor<TTx> implements UplinkExecutor {
  constructor(private readonly components: BackendComponents<TTx>) {}

  async execute(input: PrincipalUpload): Promise<Uint8Array> {
    if (
      typeof input.principal.userId !== 'string' ||
      input.principal.userId.trim().length === 0 ||
      !(input.requestBytes instanceof Uint8Array)
    ) {
      throw new LocalSyncProtocolError('invalid authenticated Uplink call');
    }
    const request = decodeUplinkRequestEnvelope(input.requestBytes);
    const requestHash = hashUplinkSemanticRequest(request.semanticValue);
    return this.components.persistence.transactions.write(
      async (transaction) => {
        const locked =
          await this.components.persistence.storage.claimAndLockUplink(
            transaction,
            {
              ownerUserId: input.principal.userId,
              clientId: request.clientId,
            },
          );
        if (locked.clientId !== request.clientId) {
          throw new Error(
            'LocalSync storage returned a different locked client',
          );
        }
        if (locked.ownerUserId !== input.principal.userId) {
          throw new LocalSyncOwnerMismatchError(
            'LocalSync client owner mismatch',
          );
        }
        if (request.batchSequence === locked.lastCommittedBatchSequence) {
          if (
            locked.requestHash !== requestHash ||
            locked.responseBytes === null
          ) {
            throw new LocalSyncSequenceError('request_conflict');
          }
          return Uint8Array.from(locked.responseBytes);
        }
        if (request.batchSequence < locked.lastCommittedBatchSequence) {
          throw new LocalSyncSequenceError('overlap');
        }
        if (request.batchSequence !== locked.lastCommittedBatchSequence + 1n) {
          throw new LocalSyncSequenceError('gap');
        }

        // Compatibility is checked before any effect. It must not be recorded as
        // a settled refusal that removes the client's pending optimism.
        for (const mutation of request.mutations) {
          const body = mutation.raw;
          if (typeof body.name !== 'string') continue;
          const found = findMutation(
            this.components.mutationContract.mutations,
            body.name,
          );
          if (found === null) continue;
          const version = body.version === undefined ? 1 : body.version;
          if (
            validMutationVersion(version) &&
            found.versions[`v${version}`] === undefined
          ) {
            throw new LocalSyncMutationVersionUnsupported(
              mutation.ordinal,
              body.name,
              version,
            );
          }
        }

        const principalScope = normalizeScope(
          this.components.principalScope(input.principal),
        );
        const rejections: Array<{ ordinal: bigint; code: string }> = [];
        const selectedScopes: string[] = [];
        for (const mutation of request.mutations) {
          // Decode first, execute second: `mutation.invalid` may only ever mean
          // "the envelope body was invalid" — an error thrown by a binding is a
          // server-side defect and must abort the batch, never become a
          // deterministic rejection the client treats as final.
          let execute: () => Promise<MutationSettlement | void>;
          try {
            execute = this.decodeMutation(
              transaction,
              input.principal.userId,
              mutation,
            );
          } catch (error) {
            const code = rejectionCode(error);
            if (code === null) throw error;
            rejections.push(Object.freeze({ ordinal: mutation.ordinal, code }));
            continue;
          }
          try {
            const settlement =
              await this.components.persistence.transactions.savepoint(
                transaction,
                execute,
              );
            selectedScopes.push(
              settlement === undefined
                ? principalScope
                : normalizeMutationSettlement(settlement),
            );
          } catch (error) {
            const code = this.refusalCodeOf(error);
            if (code === null) throw error;
            rejections.push(Object.freeze({ ordinal: mutation.ordinal, code }));
          }
        }
        if (selectedScopes.length === 0) selectedScopes.push(principalScope);
        const requiredScopes = uniqueSortedScopes(selectedScopes);
        const requiredCheckpoints: Array<{ scope: string; syncId: bigint }> =
          [];
        let legacyRequiredSyncId: bigint | undefined;
        for (const scope of requiredScopes) {
          const syncId = checkedDownlinkHead(
            await this.components.persistence.storage.readDownlinkHead(
              transaction,
              scope,
            ),
          );
          requiredCheckpoints.push(Object.freeze({ scope, syncId }));
          if (sameScope(scope, principalScope)) legacyRequiredSyncId = syncId;
        }
        legacyRequiredSyncId ??= checkedDownlinkHead(
          await this.components.persistence.storage.readDownlinkHead(
            transaction,
            principalScope,
          ),
        );
        const responseBytes = encodeUplinkResponseEnvelope({
          requiredCheckpoints: Object.freeze(requiredCheckpoints),
          requiredScope: principalScope,
          requiredSyncId: legacyRequiredSyncId,
          rejections,
        });
        await this.components.persistence.storage.saveUplinkReceipt(
          transaction,
          {
            ownerUserId: input.principal.userId,
            clientId: request.clientId,
            batchSequence: request.batchSequence,
            requestHash,
            responseBytes,
          },
        );
        return Uint8Array.from(responseBytes);
      },
    );
  }

  /**
   * A deterministic refusal RAISED BY THE WRITE ITSELF, or null when the
   * failure is a defect the whole request must abort on.
   *
   * Deliberately narrower than the decode phase's classification: a protocol
   * or identity error thrown by a binding or resolver is descriptor drift on
   * the server, and freezing it into a receipt would make the client delete a
   * valid write. Only an explicit refusal — the framework's, or one the
   * product's registered translator claims (CAP-441) — settles as a rejection.
   */
  private refusalCodeOf(error: unknown): string | null {
    if (error instanceof LocalSyncMutationRejected) return error.code;
    const translated = this.components.translateRejection(error);
    if (translated === null || translated === undefined) return null;
    // A translator that invents a code the wire cannot carry is a wiring
    // defect, not a refusal.
    return new LocalSyncMutationRejected(translated).code;
  }

  /**
   * Fully decodes one mutation and returns the deferred binding call. Every
   * validation error is raised here, before anything executes, so the caller
   * can classify decode failures separately from binding failures.
   */
  private decodeMutation(
    transaction: TTx,
    actorUserId: string,
    mutation: UplinkMutationEnvelope,
  ): () => Promise<MutationSettlement | void> {
    // Everything this mutation says is read here, inside the caller's
    // per-mutation guard, so a malformed one settles as a rejection rather
    // than refusing the batch.
    const body = mutation.raw;
    // Every mutation is a named act, decoded as one thing and executed as one
    // thing: the name tells the server which business to run, and the
    // operations tell it what the client already showed on screen (CAP-439).
    // An element without a name is not an older spelling of a write — it is a
    // shape this protocol has never had a resolver for (CAP-444).
    if (body.name === undefined) {
      throw new LocalSyncProtocolError('mutation must name an act');
    }
    return this.decodeNamedMutation(transaction, actorUserId, body);
  }

  /**
   * Decodes one named mutation into its typed arguments object and returns the
   * deferred resolver call.
   *
   * The slots are the schema's, so nothing here switches on what the payload
   * claims: each slot already fixes its `(Model, op)` pair and its
   * cardinality, and a body that does not answer exactly those slots is
   * refused before anything executes.
   */
  private decodeNamedMutation(
    transaction: TTx,
    actorUserId: string,
    body: Readonly<Record<string, unknown>>,
  ): () => Promise<MutationSettlement | void> {
    const name = stringValue(body.name, 'mutation name');
    const found = findMutation(
      this.components.mutationContract.mutations,
      name,
    );
    if (found === null) {
      throw new LocalSyncProtocolError('unknown mutation');
    }
    const version = body.version === undefined ? 1 : body.version;
    if (!validMutationVersion(version)) {
      throw new LocalSyncProtocolError(
        'mutation version must be a positive safe integer',
      );
    }
    const { key, versions } = found;
    const descriptor = versions[`v${version}`];
    if (descriptor === undefined)
      throw new Error('mutation version was not preflighted');
    const resolver = this.components.mutations[key][`v${version}`];
    if (resolver === undefined) {
      throw new Error(`LocalSync mutation "${name}" has no resolver`);
    }

    const operations = body.operations;
    if (!Array.isArray(operations)) {
      throw new LocalSyncProtocolError('mutation operations must be an array');
    }
    const arguments_: Record<string, unknown> = {};
    let position = 0;
    for (const slot of descriptor.slots) {
      const decoded: unknown[] = [];
      // Slot order is execution order, so the operations answer the slots in
      // the order they were declared, and a list slot takes as many as it is
      // given.
      while (
        position < operations.length &&
        matchesSlot(operations[position], slot)
      ) {
        decoded.push(
          this.decodeSlotOperation(
            key,
            descriptor.input,
            slot,
            operations[position] as unknown,
          ),
        );
        position += 1;
        if (slot.cardinality !== 'list') break;
      }
      if (slot.cardinality === 'list') {
        arguments_[slot.name] = Object.freeze(decoded);
      } else if (decoded.length === 1) {
        arguments_[slot.name] = decoded[0];
      } else if (slot.cardinality === 'optional') {
        arguments_[slot.name] = null;
      } else {
        throw new LocalSyncProtocolError(
          `mutation "${name}" is missing slot "${slot.name}"`,
        );
      }
    }
    if (position !== operations.length) {
      throw new LocalSyncProtocolError(
        `mutation "${name}" carries an operation no slot declared`,
      );
    }

    const context: BackendWriteContext<TTx> = Object.freeze({
      transaction,
      actorUserId,
    });
    const frozen = Object.freeze(arguments_);
    // The act's declared wiring, held against what its create rows actually
    // say — decode-phase, so a self-contradicting act settles as
    // `<mutation>.invalid` before anything executes
    // (spec 2026-08-16-slot-bindings).
    precheckSlotBindings(descriptor, key, frozen, descriptor.input.models);
    return () => callForwarder(descriptor.forward, [resolver, context, frozen]);
  }

  private decodeSlotOperation(
    mutationKey: string,
    input: MutationInputContract,
    slot: MutationSlotDescriptor,
    value: unknown,
  ): object {
    const operation = record(value, `${slot.name} operation`);
    const target = findMutationTarget(input.models, slot.model);
    if (target === null) {
      throw new Error(`LocalSync slot names unknown Model "${slot.model}"`);
    }
    const identity = decodeIdentity(input, target.model, operation.identity);
    if (slot.operation === 'delete') return Object.freeze({ identity });
    const values = record(operation.values, `${target.model.name} values`);
    if (slot.operation === 'create') {
      return Object.freeze({
        identity,
        data: decodeCompleteData(input, target.model, values),
      });
    }
    return Object.freeze({
      identity,
      patch: decodePatch(
        input,
        target.model,
        values,
        slot.allowedPatchFields!,
        mutationKey,
      ),
    });
  }
}

/// The mutation is a string parameter, so finding its resolver is a lookup by
/// name rather than a search through fused wire cases.
function validMutationVersion(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0;
}

function findMutation(
  mutations: Readonly<
    Record<string, Readonly<Record<string, MutationDescriptor>>>
  >,
  name: string,
): {
  readonly key: string;
  readonly versions: Readonly<Record<string, MutationDescriptor>>;
} | null {
  for (const [key, versions] of Object.entries(mutations)) {
    if (Object.values(versions)[0]?.name === name) return { key, versions };
  }
  return null;
}

/// Whether this operation is one the slot declared. The pair is the slot's, so
/// a payload can never claim an operation the schema did not declare.
function matchesSlot(value: unknown, slot: MutationSlotDescriptor): boolean {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }
  const operation = value as Record<string, unknown>;
  return operation.model === slot.model && operation.op === slot.operation;
}

/// The Model is a string parameter, so finding its binding is a lookup by
/// name rather than a search through fused wire cases.
function findMutationTarget(
  models: Readonly<Record<string, SyncModelShape>>,
  modelName: string,
): {
  readonly modelKey: string;
  readonly model: SyncModelShape;
} | null {
  for (const [modelKey, model] of Object.entries(models)) {
    if (model.name === modelName) return { modelKey, model };
  }
  return null;
}

function decodeIdentity(
  contract: MutationInputContract,
  model: SyncModelShape,
  value: unknown,
): object {
  return decodeFields(contract, model, value, model.identityFields, false);
}

function decodeCompleteData(
  contract: MutationInputContract,
  model: SyncModelShape,
  value: unknown,
): object {
  const fields = model.fields
    .filter((field) => !field.identity)
    .map((field) => field.name);
  return decodeFields(contract, model, value, fields, true);
}

function decodeFields(
  contract: MutationInputContract,
  model: SyncModelShape,
  value: unknown,
  fieldNames: readonly string[],
  nullableAbsenceIsNull: boolean,
): object {
  // A key this server does not know is a field a newer client added: §2's
  // unknown-fields-ignored rule runs in both directions, so it is dropped
  // rather than refused. Additive evolution means a client may legitimately
  // be one schema version ahead.
  const input = record(value, `${model.name} fields`);
  const descriptors = new Map(model.fields.map((field) => [field.name, field]));
  const result: Record<string, unknown> = {};
  for (const fieldName of fieldNames) {
    const field = descriptors.get(fieldName);
    if (field === undefined) throw new LocalSyncProtocolError('unknown field');
    const raw = input[fieldName];
    // On a create, a nullable field is null whether the client said so or
    // simply left it out — JSON can spell absence either way and both mean
    // the same thing about the row.
    if (
      field.nullable &&
      nullableAbsenceIsNull &&
      (raw === undefined || raw === null)
    ) {
      result[fieldName] = null;
    } else {
      result[fieldName] = decodeFieldValue(contract, field, raw);
    }
  }
  return Object.freeze(result);
}

/// An update names only the fields it touches. A key held at null is the
/// clear; a key that is absent was not touched at all.
function decodePatch(
  contract: MutationInputContract,
  model: SyncModelShape,
  value: unknown,
  allowedPatchFields: readonly string[],
  mutationKey: string,
): object {
  const input = record(value, `${model.name} patch`);
  const fields = new Map(model.fields.map((field) => [field.name, field]));
  const allowed = new Set(allowedPatchFields);
  const known = new Set(model.knownFields ?? fields.keys());
  const result: Record<string, unknown> = {};
  for (const [fieldName, raw] of Object.entries(input)) {
    const field = fields.get(fieldName);
    // A key this server does not know belongs to a newer additive Model
    // contract and remains ignorable for forward compatibility.
    if (!known.has(fieldName)) continue;
    if (!allowed.has(fieldName)) {
      throw new LocalSyncMutationRejected(
        `${machineName(mutationKey)}.not_allowed`,
      );
    }
    if (field === undefined) continue;
    if (raw === null) {
      if (!field.nullable) {
        throw new LocalSyncProtocolError(
          `${model.name}.${field.name} cannot be cleared`,
        );
      }
      result[fieldName] = null;
      continue;
    }
    result[fieldName] = decodeFieldValue(contract, field, raw);
  }
  if (Object.keys(result).length === 0) {
    throw new LocalSyncProtocolError(`${model.name} update is empty`);
  }
  return Object.freeze(result);
}

function decodeFieldValue(
  contract: MutationInputContract,
  field: SyncFieldDescriptor,
  value: unknown,
): unknown {
  if (field.type.kind === 'list') {
    if (!Array.isArray(value))
      throw new LocalSyncProtocolError('invalid list field');
    const element = field.type.element;
    return Object.freeze(value.map((item) => decodeScalar(element, item)));
  }
  if (field.type.kind === 'enum') {
    if (
      typeof value !== 'string' ||
      !contract.enumValues[field.type.name]?.includes(value)
    ) {
      throw new LocalSyncProtocolError('invalid enum field');
    }
    return value;
  }
  return decodeScalar(field.type.name, value);
}

function decodeScalar(
  type: 'string' | 'boolean' | 'int' | 'float' | 'dateTime' | 'uuid',
  value: unknown,
): string | number | boolean {
  if (type === 'boolean') {
    if (typeof value !== 'boolean')
      throw new LocalSyncProtocolError('invalid bool');
    return value;
  }
  if (type === 'int') {
    if (!Number.isSafeInteger(value)) {
      throw new LocalSyncProtocolError('invalid safe Model int');
    }
    return value as number;
  }
  if (type === 'float') {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
      throw new LocalSyncProtocolError('invalid float');
    }
    return Object.is(value, -0) ? 0 : value;
  }
  if (typeof value !== 'string') {
    throw new LocalSyncProtocolError(`invalid ${type}`);
  }
  if (type === 'uuid') {
    if (!uuid.test(value)) throw new LocalSyncProtocolError('invalid uuid');
    return value.toLowerCase();
  }
  if (type === 'dateTime') {
    if (!dateTimeWithZone.test(value)) {
      throw new LocalSyncProtocolError('invalid dateTime');
    }
    const parsed = new Date(value);
    if (!Number.isFinite(parsed.getTime())) {
      throw new LocalSyncProtocolError('invalid dateTime');
    }
    return parsed.toISOString();
  }
  return value;
}

const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const dateTimeWithZone =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

async function callForwarder(
  forwarder: (...arguments_: never[]) => Promise<unknown>,
  arguments_: readonly unknown[],
): Promise<MutationSettlement | void> {
  const call = forwarder as unknown as (
    ...values: readonly unknown[]
  ) => Promise<unknown>;
  return (await call(...arguments_)) as MutationSettlement | void;
}

function normalizeMutationSettlement(value: MutationSettlement): string {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error('LocalSync mutation returned an invalid settlement');
  }
  return normalizeScope(
    (value as unknown as { readonly scope: unknown }).scope,
  );
}

function normalizeScope(value: unknown): string {
  if (typeof value !== 'string') {
    throw new Error('LocalSync scope must be a string');
  }
  return value;
}

function uniqueSortedScopes(scopes: readonly string[]): readonly string[] {
  return normalizeScopes(scopes);
}

function sameScope(left: string, right: string): boolean {
  return left === right;
}

function checkedDownlinkHead(value: unknown): bigint {
  if (typeof value !== 'bigint' || value < 0n || value > maximumSignedInt64) {
    throw new Error('LocalSync storage returned an invalid Downlink head');
  }
  return value;
}

function rejectionCode(error: unknown): string | null {
  if (error instanceof LocalSyncMutationRejected) return error.code;
  if (
    error instanceof LocalSyncProtocolError ||
    error instanceof LocalSyncIdentityError
  ) {
    return 'mutation.invalid';
  }
  return null;
}

function record(value: unknown, description: string): Record<string, unknown> {
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value) ||
    (Object.getPrototypeOf(value) !== Object.prototype &&
      Object.getPrototypeOf(value) !== null)
  ) {
    throw new LocalSyncProtocolError(`${description} must be an object`);
  }
  return value as Record<string, unknown>;
}

function exactKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
  description: string,
): void {
  const actual = Object.keys(value)
    .filter((key) => value[key] !== undefined)
    .sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    throw new LocalSyncProtocolError(`${description} has invalid fields`);
  }
}

function stringValue(value: unknown, description: string): string {
  if (typeof value !== 'string') {
    throw new LocalSyncProtocolError(`${description} must be a string`);
  }
  return value;
}

function positiveInt64(value: unknown, description: string): bigint {
  if (typeof value !== 'bigint' || value <= 0n || value > maximumSignedInt64) {
    throw new LocalSyncProtocolError(`${description} must be a positive int64`);
  }
  return value;
}
