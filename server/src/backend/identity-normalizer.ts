import { canonicalJsonUtf8 } from '../canonical-json';
import {
  GeneratedBackendContract,
  SyncFieldDescriptor,
  SyncModelDescriptor,
} from './model-binding';
import { LocalSyncIdentityError } from './errors';

export interface NormalizedModelIdentity<TIdentity extends object = object> {
  readonly modelKey: string;
  readonly model: SyncModelDescriptor<TIdentity>;
  readonly value: Readonly<TIdentity>;
  readonly key: string;
  readonly bytes: Uint8Array;
}

export function normalizeModelIdentity<TIdentity extends object>(
  contract: GeneratedBackendContract,
  requestedModel: SyncModelDescriptor<TIdentity>,
  input: unknown,
): NormalizedModelIdentity<TIdentity> {
  const modelEntry = Object.entries(contract.models).find(
    ([, descriptor]) => descriptor.name === requestedModel.name,
  );
  if (modelEntry === undefined) {
    throw new LocalSyncIdentityError(
      `Model "${requestedModel.name}" is not in the generated Backend contract`,
    );
  }
  const [modelKey, model] = modelEntry;
  if (!isRecord(input)) {
    throw invalidIdentity(model.name, 'must be a plain object');
  }
  if (Object.getOwnPropertySymbols(input).length !== 0) {
    throw invalidIdentity(model.name, 'cannot contain symbol fields');
  }
  const actualFields = Object.keys(input).sort();
  const expectedFields = [...model.identityFields].sort();
  if (
    actualFields.length !== expectedFields.length ||
    actualFields.some((field, index) => field !== expectedFields[index])
  ) {
    throw invalidIdentity(model.name, 'must contain exactly its identity fields');
  }

  const fieldsByName = new Map(model.fields.map((field) => [field.name, field]));
  const normalized: Record<string, unknown> = {};
  for (const fieldName of model.identityFields) {
    const field = fieldsByName.get(fieldName);
    if (
      field === undefined ||
      !field.identity ||
      field.nullable ||
      field.type.kind !== 'scalar'
    ) {
      throw invalidIdentity(model.name, `has an invalid descriptor for "${fieldName}"`);
    }
    normalized[fieldName] = normalizeScalar(field, input[fieldName], model.name);
  }
  const value = Object.freeze(normalized) as Readonly<TIdentity>;
  const bytes = Uint8Array.from(canonicalJsonUtf8(value));
  return Object.freeze(
    new ProtectedNormalizedIdentity(
      modelKey,
      model as SyncModelDescriptor<TIdentity>,
      value,
      bytes,
    ),
  );
}

class ProtectedNormalizedIdentity<TIdentity extends object>
  implements NormalizedModelIdentity<TIdentity>
{
  readonly key: string;

  constructor(
    readonly modelKey: string,
    readonly model: SyncModelDescriptor<TIdentity>,
    readonly value: Readonly<TIdentity>,
    private readonly canonicalBytes: Uint8Array,
  ) {
    this.key = Buffer.from(canonicalBytes).toString('utf8');
  }

  get bytes(): Uint8Array {
    return Uint8Array.from(this.canonicalBytes);
  }
}

function normalizeScalar(
  field: SyncFieldDescriptor,
  value: unknown,
  modelName: string,
): string | number | boolean {
  if (field.type.kind !== 'scalar') {
    throw invalidIdentity(modelName, `field "${field.name}" is not scalar`);
  }
  switch (field.type.name) {
    case 'string':
      if (typeof value !== 'string') throw invalidField(modelName, field.name);
      return value;
    case 'boolean':
      if (typeof value !== 'boolean') throw invalidField(modelName, field.name);
      return value;
    case 'int':
      if (typeof value !== 'number' || !Number.isSafeInteger(value)) {
        throw invalidField(modelName, field.name);
      }
      return Object.is(value, -0) ? 0 : value;
    case 'float':
      if (typeof value !== 'number' || !Number.isFinite(value)) {
        throw invalidField(modelName, field.name);
      }
      return Object.is(value, -0) ? 0 : value;
    case 'dateTime': {
      if (typeof value !== 'string' || !dateTimeWithZone.test(value)) {
        throw invalidField(modelName, field.name);
      }
      const parsed = new Date(value);
      if (!Number.isFinite(parsed.getTime())) {
        throw invalidField(modelName, field.name);
      }
      return parsed.toISOString();
    }
    case 'uuid':
      if (typeof value !== 'string' || !uuid.test(value)) {
        throw invalidField(modelName, field.name);
      }
      return value.toLowerCase();
  }
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const dateTimeWithZone =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

function isRecord(value: unknown): value is Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return false;
  }
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function invalidField(modelName: string, fieldName: string): LocalSyncIdentityError {
  return invalidIdentity(modelName, `field "${fieldName}" has an invalid value`);
}

function invalidIdentity(
  modelName: string,
  detail: string,
): LocalSyncIdentityError {
  return new LocalSyncIdentityError(`invalid ${modelName} identity: ${detail}`);
}
