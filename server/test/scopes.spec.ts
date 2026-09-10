import { normalizeScopes } from '../src/backend/scopes';

describe('normalizeScopes', () => {
  it('sorts and deduplicates opaque text scopes', () => {
    expect(normalizeScopes(['Book:z', '', 'User:A', 'Book:z'])).toEqual([
      '',
      'Book:z',
      'User:A',
    ]);
  });

  it('does not interpret or normalize scope text', () => {
    expect(normalizeScopes(['user:not-a-uuid', ' User:A ', 'User:a'])).toEqual([
      ' User:A ',
      'User:a',
      'user:not-a-uuid',
    ]);
  });
});
