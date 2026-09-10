import { decodeModelContract } from 'local-sync-backend';
import contractJson from '../../generated/model-contract.json';

describe('generated Backend Model contract', () => {
  it('imports and decodes only the language-neutral validation projection', () => {
    const contract = decodeModelContract(contractJson);
    const accountState = contract.models.find(
      (model) => model.name === 'AccountState',
    );
    const space = contract.models.find((model) => model.name === 'Space');
    const star = contract.models.find((model) => model.name === 'Star');

    expect(space).toMatchObject({
      identity: ['id'],
      fields: expect.arrayContaining([
        { name: 'id', type: scalar('uuid'), nullable: false },
        { name: 'ownerId', type: scalar('uuid'), nullable: false },
        { name: 'name', type: scalar('string'), nullable: false },
        {
          name: 'kind',
          type: { kind: 'enum', name: 'SpaceKind' },
          nullable: false,
        },
      ]),
    });
    expect(accountState).toMatchObject({
      identity: ['userId'],
      fields: expect.arrayContaining([
        {
          name: 'spaceOrder',
          type: { kind: 'list', element: scalar('uuid') },
          nullable: false,
        },
      ]),
    });
    expect(star).toMatchObject({
      identity: ['userId', 'momentId'],
    });
    expect(Object.keys(contractJson)).toEqual(['enums', 'models']);
    expect(contract.enums).toContainEqual({
      name: 'SpaceKind',
      values: ['personal', 'group'],
    });
    // Every Model and every enum reachable from one (CAP-488).
    expect(contract.models.some((model) => model.name === 'LocalNote')).toBe(
      true,
    );
    expect(
      contract.enums.some((definition) => definition.name === 'LocalNoteStatus'),
    ).toBe(true);
    for (const model of contractJson.models) {
      expect(Object.keys(model).sort()).toEqual([
        'fields',
        'identity',
        'name',
      ]);
      expect(model).not.toHaveProperty('uniqueConstraints');
      expect(model).not.toHaveProperty('relations');
    }
  });
});

function scalar(name: string): { kind: 'scalar'; name: string } {
  return { kind: 'scalar', name };
}
