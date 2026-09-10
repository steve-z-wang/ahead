import { spawn } from 'node:child_process';
import { join } from 'node:path';

import { LocalSyncHost } from 'local-sync-backend';
import { generatedContract } from '../../generated/backend/backend_contract';
import { InMemoryLocalSyncPersistence } from './in-memory-persistence';
import type { InMemoryTx } from './in-memory-transactions';
import { conformanceModels } from './model-bindings';
import {
  conformancePrincipalScope,
  conformanceScopeAuthorizer,
  conformanceScopesForModel,
  conformanceSpaceId,
  conformanceUserId,
} from './scopes';
import {
  conformanceMutationContract,
  conformanceMutationResolvers,
  conformanceRejectionTranslator,
} from './mutation-resolvers';

/**
 * What it takes to put a real Dart client and a real TypeScript host on the
 * same socket: the host, the credentials it will and will not take, and the
 * child process that runs one named scenario.
 *
 * Deliberately no scenarios and no assertions — those belong to the contract
 * that owns them, so the protocol suite and the end-to-end suite never meet in
 * one file again.
 */

export const conformanceToken = 'conformance-token';
export const staleToken = 'stale-token';
export const viewer = conformanceUserId;

/**
 * The two fixture rows every family hangs off, as `wire_scenario.dart` spells
 * them. Written here as well because a contract that seeds the host directly
 * has no Dart process to ask.
 */
export {
  conformanceBookAId,
  conformanceBookBId,
  conformanceDeniedBookId,
  conformanceSpaceId,
  conformanceUserId,
} from './scopes';

const conformanceRoot = join(__dirname, '..', '..');

/** Every credential the host will take, and the one it refuses exactly once. */
function authentication() {
  const spent = new Set<string>();
  return {
    authenticate: async ({ token }: { token: string | undefined }) => {
      if (token === conformanceToken) return { userId: viewer };
      // The stale credential is refused the first time it is presented, which
      // is what the client's refresh-once convention exists to heal.
      if (token === staleToken && !spent.has(token)) {
        spent.add(token);
        return null;
      }
      if (token === staleToken) return { userId: viewer };
      return null;
    },
  };
}

/**
 * A host over in-memory storage, with the generated contract and bindings.
 *
 * `minBuild` is the live channel's floor (CAP-157). It is a parameter rather
 * than a constant because a contract that wants to cross the floor has to
 * stand a client on each side of it.
 */
export function servedHost(
  options: {
    readonly minBuild?: number;
    /**
     * Rows the host should serve rather than make. A contract that damages a
     * ledger needs a handle on the one being damaged.
     */
    readonly persistence?: InMemoryLocalSyncPersistence;
  } = {},
): LocalSyncHost<InMemoryTx> {
  const persistence = options.persistence ?? new InMemoryLocalSyncPersistence();
  let host: LocalSyncHost<InMemoryTx>;
  const { bindings, store } = conformanceModels(
    () => host.scopeLedger,
    conformanceScopesForModel,
  );
  host = new LocalSyncHost<InMemoryTx>({
    contract: generatedContract,
    models: bindings,
    mutationContract: conformanceMutationContract,
    mutations: conformanceMutationResolvers(store),
    translateRejection: conformanceRejectionTranslator,
    persistence,
    scopeAuthorizer: conformanceScopeAuthorizer,
    principalScope: conformancePrincipalScope,
    authentication: authentication(),
    minBuild: options.minBuild,
  });
  return host;
}

/**
 * Runs one scenario in a real Dart process and returns what it printed.
 *
 * `entrypoint` is the contract's own executable, relative to the conformance
 * root — the one place a contract's scenarios are named.
 */
export function drive(
  entrypoint: string,
  port: number,
  scenario: string,
  tokens: string = conformanceToken,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const child = spawn(
      'dart',
      ['run', entrypoint, String(port), scenario, tokens],
      { cwd: conformanceRoot },
    );
    let out = '';
    let err = '';
    child.stdout.on('data', (chunk: Buffer) => (out += chunk.toString()));
    child.stderr.on('data', (chunk: Buffer) => (err += chunk.toString()));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0) {
        reject(new Error(`dart ${scenario} exited ${code}\n${out}\n${err}`));
        return;
      }
      // The scenario's one JSON object is the last thing printed, but on a
      // cold pub cache `dart run` interleaves toolchain progress ("Running
      // build hooks...") into stdout without a newline, gluing onto it —
      // so scan lines from the end and parse from each line's first brace.
      const lines = out.trim().split('\n').filter(Boolean);
      for (let index = lines.length - 1; index >= 0; index -= 1) {
        const brace = lines[index].indexOf('{');
        if (brace === -1) continue;
        try {
          resolve(
            JSON.parse(lines[index].slice(brace)) as Record<string, unknown>,
          );
          return;
        } catch {
          // Not the result; keep scanning.
        }
      }
      reject(new Error(`dart ${scenario} printed no result\n${out}\n${err}`));
    });
  });
}
