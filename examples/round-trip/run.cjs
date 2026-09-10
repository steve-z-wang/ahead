const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { join } = require('node:path');
const { servedHost } = require('../../conformance/dist/src/support/wire-harness.js');

const conformance = join(__dirname, '../../conformance');

function runClient(port, scenario) {
  return new Promise((resolve, reject) => {
    const child = spawn('dart', [
      'run', 'end-to-end-sync/dart/journeys_client.dart',
      String(port), scenario, 'conformance-token',
    ], { cwd: conformance });
    let stdout = '';
    let stderr = '';
    const timeout = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`Example timed out: ${scenario}`));
    }, 90_000);
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', error => { clearTimeout(timeout); reject(error); });
    child.on('close', code => {
      clearTimeout(timeout);
      if (code !== 0) {
        reject(new Error(`Client exited ${code}\n${stdout}\n${stderr}`));
        return;
      }
      for (const line of stdout.trim().split('\n').reverse()) {
        const brace = line.indexOf('{');
        if (brace < 0) continue;
        try { resolve(JSON.parse(line.slice(brace))); return; }
        catch { /* Dart build-hook progress can precede the result. */ }
      }
      reject(new Error(`Client returned no JSON result\n${stdout}\n${stderr}`));
    });
  });
}

async function main() {
  const examples = [
    ['scoped-runtime', 'A generated client synchronizes two scopes', result => {
      assert.equal(result.spaceName, 'Runtime Renamed');
      assert.equal(result.pendingOperations, 0);
      assert.equal(result.batches, 0);
    }],
    ['named-mutation', '42 optimistic operations settle as one named mutation', result => {
      assert.equal(result.operations, 42);
      assert.equal(result.records, 1);
      assert.equal(result.heldRecords, 1);
      assert.equal(result.settledRecords, 0);
      assert.equal(result.settledOperations, 0);
    }],
    ['rejection-rebuild', 'A rejected edit rolls back while another edit succeeds', result => {
      assert.equal(result.caption, 'first');
      assert.equal(result.neighbourCaption, 'kept');
      assert.equal(result.pendingMutations, 0);
      assert.equal(result.uplinkBatches, 0);
    }],
  ];
  for (const [scenario, label, verify] of examples) {
    const host = servedHost();
    try {
      const port = await host.listen(0, '127.0.0.1');
      const result = await runClient(port, scenario);
      verify(result);
      console.log(`\nPASS: ${label}`);
      console.log(JSON.stringify(result, null, 2));
    } finally {
      await host.close();
    }
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
