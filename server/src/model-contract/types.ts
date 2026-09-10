export type ModelScalarType =
  | 'string'
  | 'boolean'
  | 'int'
  | 'float'
  | 'dateTime'
  | 'uuid';

export interface ModelScalarValueType {
  readonly kind: 'scalar';
  readonly name: ModelScalarType;
}

export interface ModelEnumValueType {
  readonly kind: 'enum';
  readonly name: string;
}

export interface ModelScalarListValueType {
  readonly kind: 'list';
  readonly element: ModelScalarValueType;
}

export type ModelValueType =
  | ModelScalarValueType
  | ModelEnumValueType
  | ModelScalarListValueType;

export interface ModelEnumContract {
  readonly name: string;
  readonly values: readonly string[];
}

export interface ModelFieldContract {
  readonly name: string;
  readonly type: ModelValueType;
  readonly nullable: boolean;
}

export interface ModelContractEntry {
  readonly name: string;
  readonly identity: readonly string[];
  readonly fields: readonly ModelFieldContract[];
}

export interface ModelContract {
  readonly enums: readonly ModelEnumContract[];
  readonly models: readonly ModelContractEntry[];
}
