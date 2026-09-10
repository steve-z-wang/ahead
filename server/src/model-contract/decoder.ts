import { ModelContractError } from '../errors';
import {
  ModelContract,
  ModelContractEntry,
  ModelEnumContract,
  ModelFieldContract,
  ModelScalarType,
  ModelScalarValueType,
  ModelValueType,
} from './types';

const scalarTypes = new Set<ModelScalarType>([
  'string',
  'boolean',
  'int',
  'float',
  'dateTime',
  'uuid',
]);

export function decodeModelContract(input: unknown): ModelContract {
  const root = requireObject(input, 'contract');
  requireExactKeys(root, ['enums', 'models'], 'contract');
  if (!Array.isArray(root.enums)) {
    invalid('contract.enums must be an array');
  }
  const seenEnums = new Set<string>();
  const enums = root.enums.map((value, index) => {
    const decoded = decodeEnum(value, index);
    if (seenEnums.has(decoded.name)) {
      invalid(`duplicate enum name "${decoded.name}"`);
    }
    seenEnums.add(decoded.name);
    return decoded;
  });
  if (!Array.isArray(root.models) || root.models.length === 0) {
    invalid('contract.models must be a non-empty array');
  }

  const seenModels = new Set<string>();
  const models = root.models.map((value, index) => {
    const model = decodeModel(value, index, seenEnums);
    if (seenEnums.has(model.name)) {
      invalid(`duplicate type name "${model.name}"`);
    }
    if (seenModels.has(model.name)) {
      invalid(`duplicate Model name "${model.name}"`);
    }
    seenModels.add(model.name);
    return model;
  });
  return Object.freeze({
    enums: Object.freeze(enums),
    models: Object.freeze(models),
  });
}

function decodeEnum(input: unknown, index: number): ModelEnumContract {
  const path = `contract.enums[${index}]`;
  const value = requireObject(input, path);
  requireExactKeys(value, ['name', 'values'], path);
  const name = requireNonEmptyString(value.name, `${path}.name`);
  if (!Array.isArray(value.values) || value.values.length === 0) {
    invalid(`${path}.values must be a non-empty array`);
  }
  const seen = new Set<string>();
  const values = value.values.map((item, valueIndex) => {
    const decoded = requireNonEmptyString(item, `${path}.values[${valueIndex}]`);
    if (seen.has(decoded)) invalid(`${path} has duplicate value "${decoded}"`);
    seen.add(decoded);
    return decoded;
  });
  return Object.freeze({ name, values: Object.freeze(values) });
}

function decodeModel(
  input: unknown,
  index: number,
  enums: ReadonlySet<string>,
): ModelContractEntry {
  const path = `contract.models[${index}]`;
  const value = requireObject(input, path);
  requireExactKeys(
    value,
    ['name', 'identity', 'fields'],
    path,
  );
  const name = requireNonEmptyString(value.name, `${path}.name`);
  if (!Array.isArray(value.fields) || value.fields.length === 0) {
    invalid(`${path}.fields must be a non-empty array`);
  }

  const seenFields = new Set<string>();
  const fields = value.fields.map((field, fieldIndex) => {
    const decoded = decodeField(field, `${path}.fields[${fieldIndex}]`, enums);
    if (seenFields.has(decoded.name)) {
      invalid(`${path} has duplicate field "${decoded.name}"`);
    }
    seenFields.add(decoded.name);
    return decoded;
  });
  if (!Array.isArray(value.identity) || value.identity.length === 0) {
    invalid(`${path}.identity must be a non-empty array`);
  }
  const fieldsByName = new Map(fields.map((field) => [field.name, field]));
  const seenIdentity = new Set<string>();
  const identity = value.identity.map((item, identityIndex) => {
    const fieldName = requireNonEmptyString(
      item,
      `${path}.identity[${identityIndex}]`,
    );
    if (seenIdentity.has(fieldName)) {
      invalid(`${path} has duplicate identity field "${fieldName}"`);
    }
    seenIdentity.add(fieldName);
    const field = fieldsByName.get(fieldName);
    if (field === undefined) {
      invalid(`${path} identity field "${fieldName}" is missing`);
    }
    if (field.nullable) {
      invalid(`${path} identity field "${fieldName}" cannot be nullable`);
    }
    if (field.type.kind !== 'scalar') {
      invalid(`${path} identity field "${fieldName}" must be scalar`);
    }
    return fieldName;
  });
  return Object.freeze({
    name,
    identity: Object.freeze(identity),
    fields: Object.freeze(fields),
  });
}

function decodeField(
  input: unknown,
  path: string,
  enums: ReadonlySet<string>,
): ModelFieldContract {
  const value = requireObject(input, path);
  requireExactKeys(value, ['name', 'type', 'nullable'], path);
  const name = requireNonEmptyString(value.name, `${path}.name`);
  const type = decodeValueType(value.type, `${path}.type`, enums);
  if (typeof value.nullable !== 'boolean') {
    invalid(`${path}.nullable must be a boolean`);
  }
  if (type.kind === 'list' && value.nullable) {
    invalid(`${path} list field cannot be nullable`);
  }
  return Object.freeze({
    name,
    type,
    nullable: value.nullable,
  });
}

function decodeValueType(
  input: unknown,
  path: string,
  enums: ReadonlySet<string>,
): ModelValueType {
  const value = requireObject(input, path);
  if (value.kind === 'scalar') return decodeScalarType(value, path);
  if (value.kind === 'enum') {
    requireExactKeys(value, ['kind', 'name'], path);
    const name = requireNonEmptyString(value.name, `${path}.name`);
    if (!enums.has(name)) invalid(`${path} references unknown enum "${name}"`);
    return Object.freeze({ kind: 'enum' as const, name });
  }
  if (value.kind === 'list') {
    requireExactKeys(value, ['kind', 'element'], path);
    return Object.freeze({
      kind: 'list' as const,
      element: decodeScalarType(
        requireObject(value.element, `${path}.element`),
        `${path}.element`,
      ),
    });
  }
  invalid(`${path}.kind is unsupported`);
}

function decodeScalarType(
  value: Readonly<Record<string, unknown>>,
  path: string,
): ModelScalarValueType {
  requireExactKeys(value, ['kind', 'name'], path);
  if (value.kind !== 'scalar' || !scalarTypes.has(value.name as ModelScalarType)) {
    invalid(`${path} is not a supported scalar type`);
  }
  return Object.freeze({
    kind: 'scalar' as const,
    name: value.name as ModelScalarType,
  });
}

function requireObject(
  input: unknown,
  path: string,
): Readonly<Record<string, unknown>> {
  if (input === null || typeof input !== 'object' || Array.isArray(input)) {
    invalid(`${path} must be a JSON object`);
  }
  return input as Readonly<Record<string, unknown>>;
}

function requireExactKeys(
  input: Readonly<Record<string, unknown>>,
  expected: readonly string[],
  path: string,
): void {
  const actual = Object.keys(input).sort();
  const wanted = [...expected].sort();
  if (
    actual.length !== wanted.length ||
    actual.some((name, index) => name !== wanted[index])
  ) {
    invalid(`${path} has an invalid key set`);
  }
}

function requireNonEmptyString(input: unknown, path: string): string {
  if (typeof input !== 'string' || input.length === 0) {
    invalid(`${path} must be a non-empty string`);
  }
  return input;
}

function requirePositiveSafeInteger(input: unknown, path: string): number {
  if (!Number.isSafeInteger(input) || (input as number) <= 0) {
    invalid(`${path} must be a positive safe integer`);
  }
  return input as number;
}

function invalid(message: string): never {
  throw new ModelContractError(message);
}
