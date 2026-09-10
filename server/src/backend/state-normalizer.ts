import { SyncModelDescriptor } from './model-binding';

/**
 * Reduce a binding's visible state to the `state` a change carries: **every
 * non-identity field, always present**, null spelled as null.
 *
 * A binding hands back whatever its storage holds, identity fields included,
 * and they are dropped here — the change already carries `identity` beside
 * `state`, and a client that read the identity twice would have to decide
 * which copy wins. The client's decoder enforces the same set exactly, so
 * these two rules are one agreement written on both sides.
 *
 * Both rules used to read the other way, because this function was written for
 * the protobuf encoder (CAP-378): proto3 has no null, so omission *was* how a
 * nullable field said null, and the generated message took the whole field
 * set. CAP-410 replaced that encoder with JSON and revised only the rule that
 * broke loudly — see `wireInt` — leaving these two describing an encoder that
 * no longer exists, until CAP-428 found them by applying a real page.
 *
 * A missing non-nullable field is still a binding defect, not a value.
 *
 * Int is the one type whose in-memory form and wire form differ; `wireInt`
 * keeps that seam in the one place that already exists to reconcile the two.
 */
export function normalizeModelState(
  model: SyncModelDescriptor,
  state: object,
): Record<string, unknown> {
  const source = state as Record<string, unknown>;
  const known = new Set(model.fields.map((field) => field.name));
  for (const key of Object.keys(source)) {
    if (!known.has(key)) {
      throw new Error(
        `LocalSync ${model.name} state has an unknown field "${key}"`,
      );
    }
  }

  const identity = new Set(model.identityFields);
  const normalized: Record<string, unknown> = {};
  for (const field of model.fields) {
    if (identity.has(field.name)) continue;
    const value = source[field.name];
    if (field.type.kind === 'list') {
      if (!Array.isArray(value)) {
        throw new Error(
          `LocalSync ${model.name} state field "${field.name}" must be a list`,
        );
      }
      normalized[field.name] =
        field.type.element === 'int'
          ? value.map((element) => wireInt(model, field.name, element))
          : value;
      continue;
    }
    if (value === null || value === undefined) {
      if (!field.nullable) {
        throw new Error(
          `LocalSync ${model.name} state is missing "${field.name}"`,
        );
      }
      normalized[field.name] = null;
      continue;
    }
    normalized[field.name] =
      field.type.kind === 'scalar' && field.type.name === 'int'
        ? wireInt(model, field.name, value)
        : value;
  }
  return normalized;
}

/**
 * A Model `Int` rides the wire as a plain JSON number.
 *
 * It used to be widened to a bigint for protobuf's int64, which canonical JSON
 * cannot encode — so a page carrying any Int field would fail to serialize and
 * the client would loop on it forever. The range check stays: a value outside
 * the safe range is one no client could read back, and saying so here beats
 * truncating it silently.
 */
function wireInt(
  model: SyncModelDescriptor,
  field: string,
  value: unknown,
): number {
  const widened =
    typeof value === 'bigint'
      ? value
      : typeof value === 'number' && Number.isInteger(value)
        ? BigInt(value)
        : null;
  if (
    widened === null ||
    widened > BigInt(Number.MAX_SAFE_INTEGER) ||
    widened < BigInt(Number.MIN_SAFE_INTEGER)
  ) {
    throw new Error(
      `LocalSync ${model.name} state field "${field}" must be a safe integer`,
    );
  }
  return Number(widened);
}
