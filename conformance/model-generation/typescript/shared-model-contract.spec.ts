import { execFileSync } from 'node:child_process';
import * as path from 'node:path';

import { generatedContract } from '../../generated/backend/backend_contract';
import contractJson from '../../generated/model-contract.json';

/**
 * The three generated projections of one definition set, compared as data.
 *
 * Each side alone can be internally consistent and still disagree with the
 * others: the Dart registry, the language-neutral contract and the Backend
 * bindings come from three emitters. The JSON contract is the shared
 * vocabulary here, not the trusted answer — all three are normalized into one
 * shape and compared pairwise, so a drifting emitter is named rather than
 * outvoted.
 */

type ScalarType = { kind: 'scalar'; name: string };

type FieldType =
  | ScalarType
  | { kind: 'enum'; name: string; values: string[] }
  | { kind: 'list'; element: ScalarType };

type FieldFacts = { name: string; type: FieldType; nullable: boolean };

type ModelFacts = {
  identity: string[];
  fields: FieldFacts[];
};

/** Every synced Model, by name — the name is the key, never a field of it. */
type Manifest = Record<string, ModelFacts>;

type JsonFieldType =
  | ScalarType
  | { kind: 'enum'; name: string }
  | { kind: 'list'; element: ScalarType };

type JsonContract = {
  enums: { name: string; values: string[] }[];
  models: {
    name: string;
    identity: string[];
    fields: { name: string; type: JsonFieldType; nullable: boolean }[];
  }[];
};

const conformanceRoot = path.resolve(__dirname, '../..');

describe('every generated projection of the definitions', () => {
  let dart: Manifest;
  const json = fromJsonContract();
  const backend = fromGeneratedBackend();

  beforeAll(() => {
    dart = fromDartRegistry();
  }, 300_000);

  it('agrees, Model for Model and field for field', () => {
    expect(dart).toEqual(json);
    expect(json).toEqual(backend);
    expect(backend).toEqual(dart);
  });

  it('carries every declared fact into all three', () => {
    // One assertion per thing a Model can declare, read off the projection the
    // runtime itself builds. Equality above makes each of these a claim about
    // all three at once.
    expect(Object.keys(dart)).toEqual([
      'AccountState',
      'LocalNote',
      'Moment',
      'MomentLink',
      'ScalarSample',
      'Space',
      'Star',
      'StarTag',
      'User',
    ]);
    // A composite identity, in declaration order — the one order that means
    // something.
    expect(dart.Star!.identity).toEqual(['userId', 'momentId']);
    expect(dart.AccountState!.identity).toEqual(['userId']);

    expect(field(dart, 'Moment', 'caption')).toEqual({
      name: 'caption',
      type: { kind: 'scalar', name: 'string' },
      nullable: true,
    });
    expect(field(dart, 'Moment', 'capturedAt').nullable).toBe(false);
    expect(field(dart, 'Space', 'kind')).toEqual({
      name: 'kind',
      type: { kind: 'enum', name: 'SpaceKind', values: ['personal', 'group'] },
      nullable: false,
    });
    expect(field(dart, 'AccountState', 'spaceOrder')).toEqual({
      name: 'spaceOrder',
      type: { kind: 'list', element: { kind: 'scalar', name: 'uuid' } },
      nullable: false,
    });
    expect(
      dart.ScalarSample!.fields.map((declared) => [
        declared.name,
        typeToken(declared),
      ]),
    ).toEqual([
      ['enabled', 'boolean'],
      ['id', 'uuid'],
      ['optionalAt', 'dateTime?'],
      ['optionalUuid', 'uuid?'],
      ['rank', 'int'],
      ['score', 'float'],
    ]);

    // A Model the definitions kept local has no wire form, so no projection
    // may know it.
    expect(dart.LocalNote).toBeDefined();
  });
});

/** The generated Dart runtime, asked through the registry it assembles. */
function fromDartRegistry(): Manifest {
  const stdout = execFileSync(
    'dart',
    ['run', 'model-generation/dart/model_manifest.dart'],
    { cwd: conformanceRoot, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 },
  );
  return normalize(parseManifest(stdout).models);
}

/**
 * The manifest is one line of JSON, but it is not the only thing on stdout: on
 * a cold pub cache `dart run` interleaves toolchain progress ("Running build
 * hooks...") without a newline, gluing it onto the line. So scan lines from the
 * end and parse from each line's first brace — the same reason, and the same
 * remedy, as `drive()` in the wire harness. A developer's cache is warm and
 * never shows this; CI's is cold and always does.
 */
function parseManifest(stdout: string): {
  models: (ModelFacts & { name: string })[];
} {
  const lines = stdout.trim().split('\n').filter(Boolean);
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const brace = lines[index].indexOf('{');
    if (brace === -1) continue;
    try {
      return JSON.parse(lines[index].slice(brace)) as {
        models: (ModelFacts & { name: string })[];
      };
    } catch {
      // Not the manifest; keep scanning.
    }
  }
  throw new Error(`the model manifest printed no JSON object\n${stdout}`);
}

/** The language-neutral contract, whose enum values live in their own list. */
function fromJsonContract(): Manifest {
  const contract = contractJson as unknown as JsonContract;
  const enumValues = new Map(
    contract.enums.map((definition) => [definition.name, definition.values]),
  );
  return normalize(
    contract.models.map((model) => ({
      name: model.name,
      identity: [...model.identity],
      fields: model.fields.map((declared) => ({
        name: declared.name,
        type:
          declared.type.kind === 'enum'
            ? withValues(declared.type.name, enumValues)
            : declared.type,
        nullable: declared.nullable,
      })),
    })),
  );
}

/** The generated Backend bindings, whose list elements are bare scalar names. */
function fromGeneratedBackend(): Manifest {
  const enumValues = new Map(
    Object.entries(
      generatedContract.enumValues as Readonly<
        Record<string, readonly string[]>
      >,
    ).map(([name, values]) => [name, [...values]]),
  );
  return normalize(
    Object.values(generatedContract.models).map((model) => ({
      name: model.name,
      identity: [...model.identityFields],
      fields: model.fields.map((declared) => ({
        name: declared.name,
        type:
          declared.type.kind === 'enum'
            ? withValues(declared.type.name, enumValues)
            : declared.type.kind === 'list'
              ? { kind: 'list' as const, element: scalar(declared.type.element) }
              : scalar(declared.type.name),
        nullable: declared.nullable,
      })),
    })),
  );
}

/**
 * The one shape all three are read into: Models keyed by name, fields sorted
 * by name.
 *
 * Field order is normalized away because it is not a fact any consumer can
 * observe — a state is a keyed object on the wire, and the Backend emitter
 * already sorts. Identity order is left alone: a composite identity is
 * declared in an order, and that order is the declaration.
 */
function normalize(models: (ModelFacts & { name: string })[]): Manifest {
  const manifest: Manifest = {};
  for (const model of [...models].sort((left, right) =>
    left.name.localeCompare(right.name),
  )) {
    manifest[model.name] = {
      identity: model.identity,
      fields: [...model.fields].sort((left, right) =>
        left.name.localeCompare(right.name),
      ),
    };
  }
  return manifest;
}

function withValues(
  name: string,
  values: ReadonlyMap<string, string[]>,
): FieldType {
  const declared = values.get(name);
  if (declared === undefined) {
    throw new Error(`enum "${name}" has no declared values`);
  }
  return { kind: 'enum', name, values: [...declared] };
}

function scalar(name: string): ScalarType {
  return { kind: 'scalar', name };
}

function field(manifest: Manifest, model: string, name: string): FieldFacts {
  const found = manifest[model]?.fields.find((each) => each.name === name);
  if (found === undefined) throw new Error(`no field ${model}.${name}`);
  return found;
}

/** A field's declared type as one readable token, for the scalar sweep. */
function typeToken(declared: FieldFacts): string {
  const base =
    declared.type.kind === 'scalar' ? declared.type.name : declared.type.kind;
  return declared.nullable ? `${base}?` : base;
}
