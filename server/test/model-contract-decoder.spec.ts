import {
  ModelContractError,
  decodeModelContract,
} from '../src';

function validContract(): Record<string, unknown> {
  return {
    enums: [{ name: 'SpaceKind', values: ['personal', 'group'] }],
    models: [
      {
        name: 'Space',
        identity: ['id'],
        fields: [
          { name: 'id', type: scalar('uuid'), nullable: false },
          { name: 'name', type: scalar('string'), nullable: false },
          { name: 'note', type: scalar('string'), nullable: true },
          { name: 'kind', type: { kind: 'enum', name: 'SpaceKind' }, nullable: false },
          {
            name: 'spaceOrder',
            type: { kind: 'list', element: scalar('uuid') },
            nullable: false,
          },
        ],
      },
      {
        name: 'Star',
        identity: ['userId', 'momentId'],
        fields: [
          { name: 'userId', type: scalar('uuid'), nullable: false },
          { name: 'momentId', type: scalar('uuid'), nullable: false },
        ],
      },
    ],
  };
}

function scalar(name: string): Record<string, unknown> {
  return { kind: 'scalar', name };
}

function models(contract: Record<string, unknown>): Record<string, unknown>[] {
  return contract.models as Record<string, unknown>[];
}

function fields(model: Record<string, unknown>): Record<string, unknown>[] {
  return model.fields as Record<string, unknown>[];
}

describe('decodeModelContract', () => {
  it('clones and freezes the exact language-neutral projection', () => {
    const input = validContract();
    const contract = decodeModelContract(input);

    expect(contract.models[0]).toEqual({
      name: 'Space',
      identity: ['id'],
      fields: [
        { name: 'id', type: scalar('uuid'), nullable: false },
        { name: 'name', type: scalar('string'), nullable: false },
        { name: 'note', type: scalar('string'), nullable: true },
        { name: 'kind', type: { kind: 'enum', name: 'SpaceKind' }, nullable: false },
        {
          name: 'spaceOrder',
          type: { kind: 'list', element: scalar('uuid') },
          nullable: false,
        },
      ],
    });
    expect(Object.isFrozen(contract)).toBe(true);
    expect(Object.isFrozen(contract.models)).toBe(true);
    expect(Object.isFrozen(contract.models[0].identity)).toBe(true);
    expect(Object.isFrozen(contract.models[0].fields[0])).toBe(true);
    expect(contract.enums[0]).toEqual({
      name: 'SpaceKind',
      values: ['personal', 'group'],
    });
    expect(Object.isFrozen(contract.enums)).toBe(true);

    models(input)[0].name = 'Changed';
    expect(contract.models[0].name).toBe('Space');
  });

  it.each([
    ['a non-object root', null],
    ['an empty Model list', { enums: [], models: [] }],
    ['an extra root key', { ...validContract(), formatVersion: 1 }],
  ])('rejects %s', (_label, input) => {
    expect(() => decodeModelContract(input)).toThrow(ModelContractError);
  });

  it('rejects duplicate and empty Model names', () => {
    const duplicate = validContract();
    models(duplicate)[1].name = 'Space';
    const empty = validContract();
    models(empty)[0].name = '';

    expect(() => decodeModelContract(duplicate)).toThrow(ModelContractError);
    expect(() => decodeModelContract(empty)).toThrow(ModelContractError);
  });

  it('rejects non-exact Model and field keys', () => {
    const modelExtra = validContract();
    models(modelExtra)[0].relations = [];
    const fieldExtra = validContract();
    fields(models(fieldExtra)[0])[0].unique = true;

    expect(() => decodeModelContract(modelExtra)).toThrow(ModelContractError);
    expect(() => decodeModelContract(fieldExtra)).toThrow(ModelContractError);
  });

  it('rejects unsupported scalar types and invalid field names', () => {
    const unsupported = validContract();
    fields(models(unsupported)[0])[1].type = scalar('json');
    const empty = validContract();
    fields(models(empty)[0])[1].name = '';
    const duplicate = validContract();
    fields(models(duplicate)[0])[1].name = 'id';

    for (const input of [unsupported, empty, duplicate]) {
      expect(() => decodeModelContract(input)).toThrow(ModelContractError);
    }
  });

  it('rejects invalid enum and list contracts', () => {
    const unknownEnum = validContract();
    (fields(models(unknownEnum)[0])[3].type as Record<string, unknown>).name =
      'Missing';
    const invalidList = validContract();
    (fields(models(invalidList)[0])[4].type as Record<string, unknown>).element = {
      kind: 'enum',
      name: 'SpaceKind',
    };
    const duplicateValue = validContract();
    ((duplicateValue.enums as Record<string, unknown>[])[0].values as string[])[1] =
      'personal';
    const nullableList = validContract();
    fields(models(nullableList)[0])[4].nullable = true;
    const collidingTypeName = validContract();
    models(collidingTypeName)[0].name = 'SpaceKind';

    for (const input of [
      unknownEnum,
      invalidList,
      duplicateValue,
      nullableList,
      collidingTypeName,
    ]) {
      expect(() => decodeModelContract(input)).toThrow(ModelContractError);
    }
  });

  it('rejects empty, duplicate, missing, and nullable identity fields', () => {
    const empty = validContract();
    models(empty)[0].identity = [];
    const duplicate = validContract();
    models(duplicate)[0].identity = ['id', 'id'];
    const missing = validContract();
    models(missing)[0].identity = ['missing'];
    const nullable = validContract();
    fields(models(nullable)[0])[0].nullable = true;

    for (const input of [empty, duplicate, missing, nullable]) {
      expect(() => decodeModelContract(input)).toThrow(ModelContractError);
    }
  });
});
