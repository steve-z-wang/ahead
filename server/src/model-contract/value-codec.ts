import { ProtocolCodecError } from '../errors';
import { JsonValue } from '../json';
import { isValidUuid } from '../uuid';
import {
  ModelEnumContract,
  ModelFieldContract,
  ModelScalarType,
} from './types';

const utcDateTimePattern =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

export function decodeModelValue(
  field: ModelFieldContract,
  input: unknown,
  allowNull: boolean,
  enums: ReadonlyMap<string, ModelEnumContract>,
): JsonValue {
  if (input === null) {
    if (allowNull) return null;
    invalid(`field "${field.name}" cannot be null`);
  }
  const type = field.type;
  switch (type.kind) {
    case 'scalar':
      return decodeScalar(field.name, type.name, input);
    case 'enum': {
      const declaration = enums.get(type.name);
      if (declaration === undefined) {
        throw new Error(`missing enum contract ${type.name}`);
      }
      if (typeof input !== 'string' || !declaration.values.includes(input)) {
        invalid(`field "${field.name}" has an invalid ${type.name} value`);
      }
      return input;
    }
    case 'list':
      if (!Array.isArray(input)) {
        invalid(`field "${field.name}" must be a list`);
      }
      return Object.freeze(
        input.map((element) => decodeScalar(field.name, type.element.name, element)),
      );
  }
}

function decodeScalar(
  fieldName: string,
  type: ModelScalarType,
  input: unknown,
): Exclude<JsonValue, JsonValue[] | ReadonlyArray<JsonValue> | object | null> {
  const valid = (() => {
    switch (type) {
      case 'string':
        return typeof input === 'string';
      case 'boolean':
        return typeof input === 'boolean';
      case 'int':
        return Number.isSafeInteger(input);
      case 'float':
        return typeof input === 'number' && Number.isFinite(input);
      case 'dateTime':
        return (
          typeof input === 'string' &&
          utcDateTimePattern.test(input) &&
          !Number.isNaN(Date.parse(input))
        );
      case 'uuid':
        return typeof input === 'string' && isValidUuid(input);
    }
  })();
  if (!valid) {
    invalid(`field "${fieldName}" has an invalid ${type} value`);
  }
  return input as string | number | boolean;
}

function invalid(message: string): never {
  throw new ProtocolCodecError(message);
}
