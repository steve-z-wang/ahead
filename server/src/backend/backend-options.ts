import { LocalSyncBackendOptionsError } from './errors';
import {
  AuthenticatedPrincipal,
  BackendWriteContext,
  ScopeAuthorizer,
} from './context';
import {
  AnyBackendModelBinding,
  GeneratedBackendContract,
  GeneratedMutationContract,
  MutationDescriptor,
  MutationInputContract,
  SyncModelShape,
  MutationSlotDescriptor,
  SlotBindingDescriptor,
  SyncFieldDescriptor,
  SyncModelDescriptor,
} from './model-binding';
import { LocalSyncPersistence } from './persistence';

export const localSyncDownlinkPageSize = 50;

/**
 * Turns a domain refusal into the machine code the wire carries (CAP-441).
 *
 * Registered once, at wiring, so a resolver throws its own refusal bare and no
 * call site wraps anything. Returning null means "not a deterministic refusal"
 * — the defect aborts the request, as any unexpected error does.
 */
export type LocalSyncRejectionTranslator = (error: unknown) => string | null;

export interface LocalSyncBackendOptions<TTx> {
  readonly contract: GeneratedBackendContract;
  readonly models: Readonly<Record<string, object>>;
  readonly persistence: LocalSyncPersistence<TTx>;
  readonly scopeAuthorizer: ScopeAuthorizer<TTx>;
  readonly principalScope: (principal: AuthenticatedPrincipal) => string;
  /** The named write vocabulary, as generation states it (CAP-439). */
  readonly mutationContract?: GeneratedMutationContract;
  /** One resolver per declared mutation version, keyed by name and vN. */
  readonly mutations?: Readonly<Record<string, unknown>>;
  readonly translateRejection?: LocalSyncRejectionTranslator;
}

export interface BackendComponents<TTx> {
  readonly contract: GeneratedBackendContract;
  readonly models: Readonly<Record<string, AnyBackendModelBinding<TTx>>>;
  readonly persistence: LocalSyncPersistence<TTx>;
  readonly scopeAuthorizer: ScopeAuthorizer<TTx>;
  readonly principalScope: (principal: AuthenticatedPrincipal) => string;
  readonly downlinkPageSize: typeof localSyncDownlinkPageSize;
  readonly mutationContract: GeneratedMutationContract;
  readonly mutations: Readonly<
    Record<string, Readonly<Record<string, MutationResolver<TTx>>>>
  >;
  readonly translateRejection: LocalSyncRejectionTranslator;
}

/**
 * The Downlink scope whose committed head makes one accepted mutation visible.
 *
 * A resolver may omit this while products migrate; omission preserves the
 * historical principal-scope settlement rule.
 */
export interface MutationSettlement {
  readonly scope: string;
}

export type MutationResolver<TTx> = (
  context: BackendWriteContext<TTx>,
  arguments_: never,
) => Promise<MutationSettlement | void>;

const noMutations: GeneratedMutationContract = Object.freeze({
  mutations: Object.freeze({}),
});

/** No product translator: only the framework's own refusals are refusals. */
const noTranslation: LocalSyncRejectionTranslator = () => null;

export function validateBackendOptions<TTx>(
  options: LocalSyncBackendOptions<TTx>,
): BackendComponents<TTx> {
  if (!isRecord(options)) fail('options must be an object');
  const generatedContract = captureContract(options.contract);
  const modelEntries = Object.entries(generatedContract.models);
  if (modelEntries.length === 0)
    fail('generated contract must contain a Model');

  // The registered loaders ARE the Downlink surface (CAP-488). A Model
  // describes a row shape and says nothing about replication, so the contract
  // names every generated Model and the Backend chooses which of them it
  // actually persists and exposes to Downlink. Partial, but exact: every key must name a
  // generated Model, and every value must be a valid binding.
  const models = record(options.models, 'models');
  const contractKeys = new Set(modelEntries.map(([key]) => key));
  const capturedModels: Record<string, AnyBackendModelBinding<TTx>> = {};
  for (const key of Object.keys(models)) {
    if (!contractKeys.has(key)) {
      fail(`Model binding "${key}" is not in the generated contract`);
    }
    const binding = record(models[key], `binding "${key}"`);
    validateBinding(binding, key);
    capturedModels[key] = binding as unknown as AnyBackendModelBinding<TTx>;
  }

  const persistence = capturePersistence<TTx>(options.persistence);
  const scopeAuthorizer = captureScopeAuthorizer<TTx>(options.scopeAuthorizer);
  functionValue(options.principalScope, 'principalScope');
  const mutationContract = captureMutationContract(options.mutationContract);
  return Object.freeze({
    contract: generatedContract,
    models: Object.freeze(capturedModels),
    persistence,
    scopeAuthorizer,
    principalScope: options.principalScope,
    downlinkPageSize: localSyncDownlinkPageSize,
    mutationContract,
    mutations: captureMutations<TTx>(options.mutations, mutationContract),
    translateRejection: captureTranslator(options.translateRejection),
  });
}

function captureScopeAuthorizer<TTx>(value: unknown): ScopeAuthorizer<TTx> {
  const authorizer = record(value, 'scopeAuthorizer');
  functionValue(authorizer.canRead, 'scopeAuthorizer.canRead');
  return Object.freeze({
    canRead: authorizer.canRead as ScopeAuthorizer<TTx>['canRead'],
  });
}

function captureMutationContract(value: unknown): GeneratedMutationContract {
  if (value === undefined) return noMutations;
  const contract = record(value, 'mutationContract');
  const mutations = record(contract.mutations, 'mutationContract.mutations');
  const captured: Record<
    string,
    Readonly<Record<string, MutationDescriptor>>
  > = {};
  for (const [key, rawVersions] of Object.entries(mutations)) {
    const versions = record(rawVersions, `mutationContract.mutations.${key}`);
    if (Object.keys(versions).length === 0)
      fail(`mutation "${key}" must declare a version`);
    const capturedVersions: Record<string, MutationDescriptor> = {};
    for (const [versionKey, rawDescriptor] of Object.entries(versions)) {
      const label = `mutationContract.mutations.${key}.${versionKey}`;
      const descriptor = record(rawDescriptor, label);
      const name = nonblank(descriptor.name, `${label}.name`);
      if (key !== `${name[0].toLowerCase()}${name.slice(1)}`) {
        fail(`mutation key "${key}" does not match descriptor "${name}"`);
      }
      const version = descriptor.version;
      if (
        typeof version !== 'number' ||
        !Number.isSafeInteger(version) ||
        version < 1 ||
        versionKey !== `v${version}`
      ) {
        fail(`${label} must name its positive safe integer version`);
      }
      if (!Array.isArray(descriptor.slots) || descriptor.slots.length === 0) {
        fail(`${label} must declare a slot`);
      }
      const slotNames = new Set<string>();
      const slots = descriptor.slots.map((value_, index) =>
        captureSlot(value_, `${label}.slots[${index}]`, slotNames),
      );
      functionValue(descriptor.forward, `${label}.forward`);
      capturedVersions[versionKey] = Object.freeze({
        name,
        version,
        input: captureInputContract(descriptor.input),
        slots: Object.freeze(slots),
        forward: descriptor.forward as (
          ...arguments_: never[]
        ) => Promise<unknown>,
      });
    }
    captured[key] = Object.freeze(capturedVersions);
  }
  return Object.freeze({ mutations: Object.freeze(captured) });
}

function captureSlot(
  value: unknown,
  description: string,
  seen: Set<string>,
): MutationSlotDescriptor {
  const slot = record(value, description);
  const name = nonblank(slot.name, `${description}.name`);
  if (!seen.add(name)) fail(`${description} duplicates slot "${name}"`);
  const operation = slot.operation;
  if (
    operation !== 'create' &&
    operation !== 'update' &&
    operation !== 'delete'
  ) {
    fail(`${description}.operation is not an operation`);
  }
  const cardinality = slot.cardinality;
  if (
    cardinality !== 'single' &&
    cardinality !== 'optional' &&
    cardinality !== 'list'
  ) {
    fail(`${description}.cardinality is not a cardinality`);
  }
  return Object.freeze({
    name,
    model: nonblank(slot.model, `${description}.model`),
    operation,
    cardinality,
    ...captureAllowedPatchFields(
      slot.allowedPatchFields,
      operation,
      description,
    ),
    ...(slot.bindings === undefined
      ? {}
      : { bindings: captureSlotBindings(slot.bindings, description) }),
  });
}

function captureAllowedPatchFields(
  value: unknown,
  operation: MutationSlotDescriptor['operation'],
  description: string,
): Readonly<{ allowedPatchFields?: readonly string[] }> {
  if (operation !== 'update') {
    if (value !== undefined) {
      fail(`${description}: only update slots may declare allowedPatchFields`);
    }
    return Object.freeze({});
  }
  if (value === undefined) {
    fail(`${description} must declare allowedPatchFields`);
  }
  if (!Array.isArray(value) || value.length === 0) {
    fail(`${description}.allowedPatchFields must be a nonempty array`);
  }
  const fields = (value as unknown[]).map((field, index) =>
    nonblank(field, `${description}.allowedPatchFields[${index}]`),
  );
  const seen = new Set<string>();
  for (const field of fields) {
    if (seen.has(field)) {
      fail(
        `${description}.allowedPatchFields contains duplicate field "${field}"`,
      );
    }
    seen.add(field);
  }
  return Object.freeze({ allowedPatchFields: Object.freeze(fields) });
}

function captureSlotBindings(
  value: unknown,
  description: string,
): readonly SlotBindingDescriptor[] {
  if (!Array.isArray(value) || value.length === 0) {
    fail(`${description}.bindings must be a nonempty array when present`);
  }
  return Object.freeze(
    (value as unknown[]).map((entry, index) => {
      const binding = record(entry, `${description}.bindings[${index}]`);
      const fields = binding.fields;
      if (!Array.isArray(fields) || fields.length === 0) {
        fail(`${description}.bindings[${index}].fields must be nonempty`);
      }
      return Object.freeze({
        relation: nonblank(
          binding.relation,
          `${description}.bindings[${index}].relation`,
        ),
        fields: Object.freeze(
          (fields as unknown[]).map((field, fieldIndex) =>
            nonblank(
              field,
              `${description}.bindings[${index}].fields[${fieldIndex}]`,
            ),
          ),
        ),
        slot: nonblank(binding.slot, `${description}.bindings[${index}].slot`),
      });
    }),
  );
}

function captureMutations<TTx>(
  value: unknown,
  mutationContract: GeneratedMutationContract,
): Readonly<Record<string, Readonly<Record<string, MutationResolver<TTx>>>>> {
  const declared = Object.keys(mutationContract.mutations).sort();
  if (value === undefined) {
    if (declared.length > 0) {
      fail('mutation resolvers must exactly match the generated contract');
    }
    return Object.freeze({});
  }
  const resolvers = record(value, 'mutations');
  if (!sameStrings(declared, Object.keys(resolvers).sort())) {
    fail('mutation resolvers must exactly match the generated contract');
  }
  const captured: Record<
    string,
    Readonly<Record<string, MutationResolver<TTx>>>
  > = {};
  for (const [key, versions] of Object.entries(mutationContract.mutations)) {
    const handlers = record(resolvers[key], `mutations.${key}`);
    if (
      !sameStrings(Object.keys(versions).sort(), Object.keys(handlers).sort())
    ) {
      fail(
        `mutation "${key}" version resolvers must exactly match the generated contract`,
      );
    }
    const capturedVersions: Record<string, MutationResolver<TTx>> = {};
    for (const [versionKey, descriptor] of Object.entries(versions)) {
      const modelsByName = new Map(
        Object.values(descriptor.input.models).map((model) => [
          model.name,
          model,
        ]),
      );
      const modelNames = new Set(modelsByName.keys());
      for (const slot of descriptor.slots) {
        if (!modelNames.has(slot.model)) {
          fail(
            `mutation "${descriptor.name}" names unknown Model "${slot.model}"`,
          );
        }
        const model = modelsByName.get(slot.model)!;
        for (const fieldName of slot.allowedPatchFields ?? []) {
          const field = model.fields.find(
            (candidate) => candidate.name === fieldName,
          );
          if (field === undefined) {
            fail(
              `mutation "${descriptor.name}" slot "${slot.name}" ` +
                `allowedPatchFields names unknown field "${fieldName}"`,
            );
          }
          if (field.identity) {
            fail(
              `mutation "${descriptor.name}" slot "${slot.name}" ` +
                `allowedPatchFields cannot include identity field "${fieldName}"`,
            );
          }
        }
      }
      // Binding referents, settled here where both halves are in hand — the
      // executor's precheck runs on every uplink batch and must never discover
      // a contract defect at decode time, where a bare throw poisons the whole
      // batch instead of failing the boot.
      for (const slot of descriptor.slots) {
        for (const binding of slot.bindings ?? []) {
          const label =
            `mutation "${descriptor.name}" slot "${slot.name}" binding ` +
            `"${binding.relation}"`;
          const parent = descriptor.slots.find(
            (candidate) => candidate.name === binding.slot,
          );
          if (parent === undefined) {
            fail(`${label} names unknown slot "${binding.slot}"`);
          }
          if (parent.cardinality !== 'single') {
            fail(
              `${label} binds slot "${binding.slot}", which is not ` +
                'single-cardinality',
            );
          }
          const parentModel = modelsByName.get(parent.model);
          if (parentModel === undefined) {
            fail(
              `${label} binds slot "${binding.slot}" of unknown Model "${parent.model}"`,
            );
          }
          if (binding.fields.length !== parentModel.identityFields.length) {
            fail(
              `${label} names ${binding.fields.length} fields against ` +
                `"${parent.model}"'s identity of ` +
                `${parentModel.identityFields.length}`,
            );
          }
        }
      }
      functionValue(handlers[versionKey], `mutations.${key}.${versionKey}`);
      capturedVersions[versionKey] = handlers[
        versionKey
      ] as MutationResolver<TTx>;
    }
    captured[key] = Object.freeze(capturedVersions);
  }
  return Object.freeze(captured);
}

function captureTranslator(value: unknown): LocalSyncRejectionTranslator {
  if (value === undefined) return noTranslation;
  functionValue(value, 'translateRejection');
  return value as LocalSyncRejectionTranslator;
}

function captureContract(value: unknown): GeneratedBackendContract {
  const contract = record(value, 'contract');
  const shapes = captureInputContract(contract);
  const models = record(contract.models, 'contract.models');
  const captured: Record<string, SyncModelDescriptor> = {};
  for (const [key, shape] of Object.entries(shapes.models)) {
    const descriptor = record(models[key], `contract.models.${key}`);
    const forward = record(
      descriptor.forward,
      `contract.models.${key}.forward`,
    );
    functionValue(forward.read, `contract.models.${key}.forward.read`);
    captured[key] = Object.freeze({
      ...shape,
      forward: Object.freeze({
        read: forward.read as (...arguments_: never[]) => Promise<unknown>,
      }),
    });
  }
  return Object.freeze({
    enumValues: shapes.enumValues,
    models: Object.freeze(captured),
  });
}

function captureInputContract(value: unknown): MutationInputContract {
  const contract = record(value, 'contract');
  const models = record(contract.models, 'contract.models');
  const enumValues = captureEnumValues(contract.enumValues);
  const capturedModels: Record<string, SyncModelShape> = {};
  const modelNames = new Set<string>();
  for (const [key, rawDescriptor] of Object.entries(models)) {
    if (key.trim().length === 0) fail('contract Model key must be nonblank');
    const descriptor = captureDescriptor(rawDescriptor, key);
    if (!modelNames.add(descriptor.name)) {
      fail(`duplicate generated Model descriptor "${descriptor.name}"`);
    }
    for (const field of descriptor.fields) {
      if (
        field.type.kind === 'enum' &&
        enumValues[field.type.name] === undefined
      ) {
        fail(
          `contract Model "${descriptor.name}" references unknown enum "${field.type.name}"`,
        );
      }
    }
    capturedModels[key] = descriptor;
  }
  return Object.freeze({ enumValues, models: Object.freeze(capturedModels) });
}

function captureEnumValues(
  value: unknown,
): Readonly<Record<string, readonly string[]>> {
  const definitions = record(value, 'contract.enumValues');
  const captured: Record<string, readonly string[]> = {};
  for (const [name, rawValues] of Object.entries(definitions)) {
    nonblank(name, 'contract enum name');
    if (!Array.isArray(rawValues) || rawValues.length === 0) {
      fail(`contract enum "${name}" must contain a value`);
    }
    const values = rawValues.map((entry, index) =>
      nonblank(entry, `contract.enumValues.${name}[${index}]`),
    );
    if (new Set(values).size !== values.length) {
      fail(`contract enum "${name}" contains duplicate values`);
    }
    captured[name] = Object.freeze(values);
  }
  return Object.freeze(captured);
}

function captureDescriptor(value: unknown, key: string): SyncModelShape {
  const descriptor = record(value, `contract.models.${key}`);
  const name = nonblank(descriptor.name, `contract.models.${key}.name`);
  const expectedKey = `${name[0].toLowerCase()}${name.slice(1)}`;
  if (key !== expectedKey) {
    fail(`contract Model key "${key}" does not match descriptor "${name}"`);
  }
  if (!Array.isArray(descriptor.identityFields)) {
    fail(`contract.models.${key}.identityFields must be an array`);
  }
  const identityFields = descriptor.identityFields.map((field, index) =>
    nonblank(field, `contract.models.${key}.identityFields[${index}]`),
  );
  if (
    identityFields.length === 0 ||
    new Set(identityFields).size !== identityFields.length
  ) {
    fail(`contract.models.${key} must have unique identity fields`);
  }
  if (!Array.isArray(descriptor.fields)) {
    fail(`contract.models.${key}.fields must be an array`);
  }
  const fields = descriptor.fields.map((field, index) =>
    captureField(field, `contract.models.${key}.fields[${index}]`),
  );
  const fieldsByName = new Map(fields.map((field) => [field.name, field]));
  if (fieldsByName.size !== fields.length) {
    fail(`contract.models.${key} contains duplicate fields`);
  }
  for (const identityField of identityFields) {
    const field = fieldsByName.get(identityField);
    if (field === undefined || !field.identity || field.nullable) {
      fail(`contract.models.${key} has an invalid identity field`);
    }
  }

  if (
    descriptor.knownFields !== undefined &&
    !Array.isArray(descriptor.knownFields)
  ) {
    fail(`contract.models.${key}.knownFields must be an array`);
  }
  const knownFields =
    descriptor.knownFields === undefined
      ? fields.map((field) => field.name)
      : (descriptor.knownFields as unknown[]).map((field, index) =>
          nonblank(field, `contract.models.${key}.knownFields[${index}]`),
        );
  if (
    new Set(knownFields).size !== knownFields.length ||
    fields.some((field) => !knownFields.includes(field.name))
  ) {
    fail(
      `contract.models.${key}.knownFields must uniquely contain all input fields`,
    );
  }

  return Object.freeze({
    name,
    identityFields: Object.freeze(identityFields),
    knownFields: Object.freeze(knownFields),
    fields: Object.freeze(fields),
  });
}

function captureField(
  value: unknown,
  description: string,
): SyncFieldDescriptor {
  const field = record(value, description);
  const type = record(field.type, `${description}.type`);
  const kind = type.kind;
  if (kind === 'scalar') {
    const name = nonblank(type.name, `${description}.type.name`);
    if (
      !['string', 'boolean', 'int', 'float', 'dateTime', 'uuid'].includes(name)
    ) {
      fail(`${description}.type has an unsupported scalar`);
    }
    return Object.freeze({
      name: nonblank(field.name, `${description}.name`),
      nullable: booleanValue(field.nullable, `${description}.nullable`),
      identity: booleanValue(field.identity, `${description}.identity`),
      type: Object.freeze({ kind, name }) as SyncFieldDescriptor['type'],
    });
  }
  if (kind === 'enum') {
    return Object.freeze({
      name: nonblank(field.name, `${description}.name`),
      nullable: booleanValue(field.nullable, `${description}.nullable`),
      identity: booleanValue(field.identity, `${description}.identity`),
      type: Object.freeze({
        kind,
        name: nonblank(type.name, `${description}.type.name`),
      }),
    });
  }
  if (kind === 'list') {
    const element = nonblank(type.element, `${description}.type.element`);
    if (
      !['string', 'boolean', 'int', 'float', 'dateTime', 'uuid'].includes(
        element,
      )
    ) {
      fail(`${description}.type has an unsupported list element`);
    }
    const nullable = booleanValue(field.nullable, `${description}.nullable`);
    if (nullable) fail(`${description} list cannot be nullable`);
    return Object.freeze({
      name: nonblank(field.name, `${description}.name`),
      nullable,
      identity: booleanValue(field.identity, `${description}.identity`),
      type: Object.freeze({ kind, element }) as SyncFieldDescriptor['type'],
    });
  }
  fail(`${description}.type has an unsupported kind`);
}

function validateBinding(binding: Record<string, unknown>, key: string): void {
  const read = record(binding.read, `binding "${key}".read`);
  functionValue(read.forViewer, `binding "${key}".read.forViewer`);
}

function capturePersistence<TTx>(value: unknown): LocalSyncPersistence<TTx> {
  const persistence = record(value, 'persistence');
  const transactions = record(
    persistence.transactions,
    'persistence.transactions',
  );
  for (const operation of ['write', 'readSnapshot', 'savepoint']) {
    functionValue(
      transactions[operation],
      `persistence.transactions.${operation}`,
    );
  }
  const storage = record(persistence.storage, 'persistence.storage');
  for (const operation of [
    'claimAndLockUplink',
    'saveUplinkReceipt',
    'lockOrCreateDownlinkHead',
    'writeDownlinkHead',
    'upsertInvalidation',
    'readDownlinkHead',
    'scanInvalidations',
    'findInvalidationScopes',
  ]) {
    functionValue(storage[operation], `persistence.storage.${operation}`);
  }
  const committedChanges = record(
    persistence.committedChanges,
    'persistence.committedChanges',
  );
  functionValue(
    committedChanges.subscribe,
    'persistence.committedChanges.subscribe',
  );
  functionValue(committedChanges.close, 'persistence.committedChanges.close');
  return Object.freeze({
    transactions:
      persistence.transactions as LocalSyncPersistence<TTx>['transactions'],
    storage: persistence.storage as LocalSyncPersistence<TTx>['storage'],
    committedChanges:
      persistence.committedChanges as LocalSyncPersistence<TTx>['committedChanges'],
  });
}

function record(value: unknown, description: string): Record<string, unknown> {
  if (!isRecord(value)) fail(`${description} must be an object`);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function nonblank(value: unknown, description: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    fail(`${description} must be a nonblank string`);
  }
  return value;
}

function booleanValue(value: unknown, description: string): boolean {
  if (typeof value !== 'boolean') fail(`${description} must be a boolean`);
  return value;
}

function functionValue(value: unknown, description: string): void {
  if (typeof value !== 'function') fail(`${description} must be a function`);
}

function sameStrings(
  left: readonly string[],
  right: readonly string[],
): boolean {
  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

function fail(message: string): never {
  throw new LocalSyncBackendOptionsError(message);
}
