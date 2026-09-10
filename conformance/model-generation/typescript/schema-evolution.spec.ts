import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

/**
 * What a second generation over changed definitions is allowed to do to an
 * already published contract.
 *
 * The rule this repository publishes is names-only and additive: a Model or a
 * field that has once been generated may gain company and may never leave, and
 * a rename is a removal and an addition at once. Nothing here widens that rule
 * to identity, type, nullability or version — that would be a product ruling,
 * not a test.
 *
 * Asserted through the real CLI, on a definition set of this suite's own, so
 * what is proved is what a consumer's `generate_local_sync.sh` will meet.
 */

const compilerRoot = path.resolve(__dirname, '../../../compiler');

// Every case here compiles twice through a real process.
jest.setTimeout(300_000);

const baseline = `
model User {
  id     UUID
  handle String

  @@id(id)
}

model Note {
  id   UUID
  body String?

  @@id(id)
}
`;

const addedField = baseline.replace(
  '  body String?',
  '  body String?\n  mood String?',
);

const addedModel = `${baseline}
model Tag {
  id    UUID
  label String

  @@id(id)
}
`;

const removedModel = baseline.slice(0, baseline.indexOf('model Note'));

const renamedModel = baseline.replace('model Note {', 'model Page {');

const removedField = baseline.replace('  body String?\n', '');

const renamedField = baseline.replace('  body String?', '  text String?');

describe('a second generation over changed definitions', () => {
  let workspace: string;

  beforeEach(() => {
    workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'local-sync-evolution-'));
    expect(generate(workspace, baseline).status).toBe(0);
  });

  afterEach(() => {
    fs.rmSync(workspace, { recursive: true, force: true });
  });

  it('accepts a new field on a published Model', () => {
    const result = generate(workspace, addedField);

    expect(result.status).toBe(0);
    expect(fieldNames(workspace, 'Note')).toEqual(['id', 'body', 'mood']);
  });

  it('accepts a whole new Model', () => {
    const result = generate(workspace, addedModel);

    expect(result.status).toBe(0);
    expect(modelNames(workspace)).toEqual(['Note', 'Tag', 'User']);
  });

  it.each([
    ['a removed Model', removedModel, 'Model "Note"'],
    ['a renamed Model', renamedModel, 'Model "Note"'],
    ['a removed field', removedField, '"Note.body"'],
    ['a renamed field', renamedField, '"Note.body"'],
  ])('refuses %s, and writes nothing', (_label, definitions, loss) => {
    const published = fs.readFileSync(contractPath(workspace));

    const result = generate(workspace, definitions);

    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain('the wire contract may only grow');
    expect(result.stderr).toContain(loss);
    // A refused generation is not a half-written one: what was published
    // before is still exactly what is on disk.
    expect(fs.readFileSync(contractPath(workspace))).toEqual(published);
  });
});

/** Runs the real CLI over `definitions`, writing into this test's workspace. */
function generate(
  directory: string,
  definitions: string,
): { status: number | null; stderr: string } {
  const source = path.join(directory, 'definitions');
  fs.mkdirSync(source, { recursive: true });
  fs.writeFileSync(path.join(source, 'models.model'), definitions);

  const result = spawnSync(
    'dart',
    [
      'run',
      'bin/local_sync_compiler.dart',
      '--definitions',
      source,
      '--contract-out',
      contractPath(directory),
    ],
    { cwd: compilerRoot, encoding: 'utf8' },
  );
  if (result.error !== undefined) throw result.error;
  return { status: result.status, stderr: result.stderr };
}

function contractPath(directory: string): string {
  return path.join(directory, 'model-contract.json');
}

function contract(directory: string): {
  models: { name: string; fields: { name: string }[] }[];
} {
  return JSON.parse(fs.readFileSync(contractPath(directory), 'utf8'));
}

function modelNames(directory: string): string[] {
  return contract(directory).models.map((model) => model.name);
}

function fieldNames(directory: string, model: string): string[] {
  const found = contract(directory).models.find(
    (candidate) => candidate.name === model,
  );
  if (found === undefined) throw new Error(`no Model ${model}`);
  return found.fields.map((field) => field.name);
}
