import type { MutationDescriptor } from 'local-sync-backend';
import { execFileSync } from 'node:child_process';
import * as path from 'node:path';

import {
  generatedContract,
  generatedMutations,
} from '../../generated/backend/backend_contract';

/**
 * The two generated projections of one `mutation` declaration, compared as
 * data (CAP-439).
 *
 * The Dart client builds an act as a value and the Backend decodes it as an
 * arguments object; both are emitted from the same declaration, and the whole
 * point of naming a mutation is that the two sides mean the same act. So the
 * Dart side is read by BUILDING each mutation and asking the value what it
 * holds — the same thing `mutate` reads — and compared slot for slot against
 * the descriptors the executor decodes with. Neither side is the trusted
 * answer; a drifting emitter is named rather than outvoted.
 */

type OperationFacts = { model: string; operation: string };

type BindingFacts = { operation: number; fields: string[]; parent: number };

type UpdateProjectionFacts = { operation: number; fields: string[] };

type MutationFacts = {
  name: string;
  version: number;
  operations: OperationFacts[];
  /**
   * The act's declared wiring, by operation index. The Dart manifest states
   * one fact per bound row; the Backend half is derived per slot — both are
   * always present (empty when nothing binds), so the general equality
   * compares them for every act by default.
   */
  bindings: BindingFacts[];
  /** One entry per update slot, carrying the complete declared capability. */
  updateProjections: UpdateProjectionFacts[];
};

const conformanceRoot = path.resolve(__dirname, '../..');

describe('every generated projection of the declared mutations', () => {
  let dart: MutationFacts[];
  const backend = fromGeneratedBackend();

  beforeAll(() => {
    dart = fromDartValues();
  }, 300_000);

  it('agrees, act for act and slot for slot', () => {
    // Every declared slot is a wire slot (CAP-488), so the two projections
    // are compared whole: there is nothing left for one side to hold that the
    // other does not.
    expect(dart.map(wireHalf)).toEqual(backend);
  });

  it('states a companion act as its declared slot alone', () => {
    // The device-only note the act writes is a direct write inside its
    // callback, not a slot — so it appears in neither projection, which is
    // exactly what makes it device-only.
    expect(byName(dart, 'CaptionWithNote').operations).toEqual([
      { model: 'Moment', operation: 'update' },
    ]);
    expect(
      generatedMutations.mutations.captionWithNote.v1.slots.map(
        (slot) => slot.model,
      ),
    ).toEqual(['Moment']);
  });

  it('carries every declared fact into both', () => {
    expect(dart.map((mutation) => mutation.name)).toEqual([
      'CaptionWithNote',
      'CaptureMoment',
      'CreateSpace',
      'DeleteSpace',
      'DiscardMoment',
      'KeepMoment',
      'PublishNote',
      'RecaptionWithNote',
      'RecordSample',
      'RegisterUser',
      'RenameSpace',
      'ReviseMoment',
      'ReviseSample',
      'SaveAccountState',
      'Unstar',
      'WriteMoment',
    ]);

    // Declaration order is execution order, and the composite spans Models
    // with no reference between them: fate is declared by the word.
    expect(byName(dart, 'CaptureMoment').operations).toEqual([
      { model: 'Moment', operation: 'create' },
      { model: 'Star', operation: 'create' },
      { model: 'StarTag', operation: 'create' },
    ]);
    expect(byName(dart, 'ReviseMoment').operations).toEqual([
      { model: 'Moment', operation: 'update' },
      { model: 'StarTag', operation: 'delete' },
      { model: 'StarTag', operation: 'create' },
      { model: 'Star', operation: 'delete' },
    ]);

    // One `(Model, op)` pair, two acts: the name is the whole of the
    // difference, and the resolver key is the act, never the Model.
    expect(byName(dart, 'RenameSpace').operations).toEqual([
      { model: 'Space', operation: 'update' },
    ]);
    expect(byName(dart, 'RenameSpace').updateProjections).toEqual([
      { operation: 0, fields: ['name', 'avatarKey', 'kind'] },
    ]);
    expect(Object.keys(generatedMutations.mutations)).toContain('renameSpace');
    expect(Object.keys(generatedMutations.mutations)).toContain('deleteSpace');
  });

  it('states each slot once, with its declared cardinality', () => {
    expect(generatedMutations.mutations.captureMoment.v1.slots).toEqual([
      {
        name: 'moment',
        model: 'Moment',
        operation: 'create',
        cardinality: 'single',
      },
      {
        name: 'star',
        model: 'Star',
        operation: 'create',
        cardinality: 'single',
        bindings: [
          { relation: 'moment', fields: ['momentId'], slot: 'moment' },
        ],
      },
      {
        name: 'tags',
        model: 'StarTag',
        operation: 'create',
        cardinality: 'list',
        bindings: [
          { relation: 'star', fields: ['userId', 'momentId'], slot: 'star' },
          { relation: 'moment', fields: ['momentId'], slot: 'moment' },
        ],
      },
    ]);
    expect(
      generatedMutations.mutations.reviseMoment.v1.slots.map(
        (slot) => `${slot.name}:${slot.cardinality}`,
      ),
    ).toEqual([
      'moment:single',
      'removedTags:list',
      'addedTags:list',
      'star:optional',
    ]);
  });

  // Slot bindings ride the general equality above — both halves always carry
  // a `bindings` list, so a newly bound act (or a spuriously emitted binding
  // on any act) is compared without anyone extending a hand-written list.
  // One literal stays as the golden for the multi-parent shape.
  it('pins the multi-parent wiring literally', () => {
    expect(byName(dart, 'CaptureMoment').bindings).toEqual([
      { operation: 1, fields: ['momentId'], parent: 0 },
      { operation: 2, fields: ['userId', 'momentId'], parent: 1 },
      { operation: 2, fields: ['momentId'], parent: 0 },
    ]);
  });

  it('carries every declared act to the Backend, whichever Model it names', () => {
    // Device-only work is a `localSync.write`, never a declaration (CAP-488),
    // so there is no act for a Backend projection to omit — including one on
    // the Model the journeys also write directly.
    const names = Object.values(generatedMutations.mutations)
      .map((versions) => Object.values(versions).at(-1)!)
      .map((mutation) => mutation.name);
    expect(names).toContain('PublishNote');
    expect(names).not.toContain('SaveNote');
    expect(names).not.toContain('DiscardNote');
  });
});

/** A mutation's operations as the wire carries them: synced Models only. */
const wireModels = new Set<string>(
  Object.values(generatedContract.models).map((model) => model.name),
);

function wireHalf(mutation: MutationFacts): MutationFacts {
  // Spread first, so any future MutationFacts field is compared by default —
  // narrowing this to a hand-picked list is what let bindings slip out of
  // the general equality once already.
  const kept: number[] = [];
  mutation.operations.forEach((operation, index) => {
    if (wireModels.has(operation.model)) kept.push(index);
  });
  const wireIndex = new Map(kept.map((fullIndex, index) => [fullIndex, index]));
  const remap = (fullIndex: number): number => {
    const mapped = wireIndex.get(fullIndex);
    if (mapped === undefined) {
      // A binding referencing a local operation is unrepresentable (local
      // Models declare no relations); reaching here means an emitter drifted.
      throw new Error(
        `mutation "${mutation.name}" binds operation ${fullIndex}, which the wire does not carry`,
      );
    }
    return mapped;
  };
  return {
    ...mutation,
    operations: kept.map((index) => mutation.operations[index]),
    bindings: mutation.bindings.map((binding) => ({
      ...binding,
      operation: remap(binding.operation),
      parent: remap(binding.parent),
    })),
    updateProjections: mutation.updateProjections.map((projection) => ({
      ...projection,
      operation: remap(projection.operation),
    })),
  };
}

/** The generated Dart values, asked the way `mutate` asks them. */
function fromDartValues(): MutationFacts[] {
  const stdout = execFileSync(
    'dart',
    ['run', 'model-generation/dart/mutation_manifest.dart'],
    { cwd: conformanceRoot, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 },
  );
  return parseManifest(stdout).mutations;
}

/**
 * One line of JSON, but not the only thing on stdout: on a cold pub cache
 * `dart run` interleaves toolchain progress without a newline. Scan lines from
 * the end and parse from each line's first brace — the same reason and remedy
 * as the Model manifest beside this one.
 */
function parseManifest(stdout: string): { mutations: MutationFacts[] } {
  const lines = stdout.trim().split('\n').filter(Boolean);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const brace = lines[index].indexOf('{');
    if (brace === -1) continue;
    try {
      return JSON.parse(lines[index].slice(brace)) as {
        mutations: MutationFacts[];
      };
    } catch {
      // Not the manifest; keep scanning.
    }
  }
  throw new Error(`the mutation manifest printed no JSON object\n${stdout}`);
}

/**
 * The generated Backend descriptors, flattened the way one operation per slot
 * flattens on the client — which is what the Dart manifest builds.
 */
function fromGeneratedBackend(): MutationFacts[] {
  return Object.values(generatedMutations.mutations)
    .map((versions) => Object.values(versions).at(-1)!)
    .map((mutation: MutationDescriptor) => {
      const slotIndex = new Map(
        mutation.slots.map((slot, index) => [slot.name, index]),
      );
      return {
        name: mutation.name,
        version: mutation.version,
        operations: mutation.slots.map((slot) => ({
          model: slot.model,
          operation: slot.operation as string,
        })),
        // One fact per bound slot; the manifest builds one row per slot, so
        // operation index N IS slot index N and the two halves compare
        // binding for binding.
        bindings: mutation.slots.flatMap((slot, index) =>
          ('bindings' in slot ? (slot.bindings ?? []) : []).map((binding) => ({
            operation: index,
            fields: [...binding.fields],
            parent: slotIndex.get(binding.slot)!,
          })),
        ),
        updateProjections: mutation.slots.flatMap((slot, index) =>
          slot.allowedPatchFields !== undefined
            ? [
                {
                  operation: index,
                  fields: [...slot.allowedPatchFields],
                },
              ]
            : [],
        ),
      };
    })
    .sort((left, right) => left.name.localeCompare(right.name));
}

function byName(mutations: MutationFacts[], name: string): MutationFacts {
  const found = mutations.find((mutation) => mutation.name === name);
  if (found === undefined) throw new Error(`no mutation named ${name}`);
  return found;
}
