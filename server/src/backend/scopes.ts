import { LocalSyncProtocolError } from './errors';

/** Sorts and deduplicates opaque scope text without interpreting it. */
export function normalizeScopes(values: readonly string[]): readonly string[] {
  if (!Array.isArray(values) || values.some((value) => typeof value !== 'string')) {
    throw new LocalSyncProtocolError('scopes must be an array of strings');
  }
  return Object.freeze([...new Set(values)].sort(compareText));
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
