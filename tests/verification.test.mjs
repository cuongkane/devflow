import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

for (const failed of [false, true]) {
  test(`verification uses coverage and cleans up (${failed ? 'failure' : 'success'})`, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'verify-test-'));
    try {
      const bin = path.join(dir, 'bin');
      fs.mkdirSync(bin);
      fs.writeFileSync(path.join(dir, 'state.json'), JSON.stringify({worktree: dir, base: 'base'}));
      fs.writeFileSync(path.join(bin, 'git'), '#!/bin/sh\nexit 0\n', {mode: 0o755});
      fs.writeFileSync(path.join(bin, 'make'), `#!/bin/sh
printf '%s\\n' "$1" >> "$CALL_LOG"
if [ "$1" = test-ci-coverage ]; then
  echo 'backend coverage evidence'
  exit ${failed ? 1 : 0}
fi
`, {mode: 0o755});
      const result = spawnSync('sh', ['scripts/implement/run-verification.sh', dir], {
        encoding: 'utf8', env: {...process.env, PATH: `${bin}:${process.env.PATH}`, CALL_LOG: path.join(dir, 'calls')},
      });
      assert.equal(result.status, failed ? 1 : 0, result.stderr);
      const calls = fs.readFileSync(path.join(dir, 'calls'), 'utf8').trim().split('\n');
      assert.deepEqual(calls.slice(0, 3), ['test-ci-migrations', 'test-ci-coverage', 'test-ci-down']);
      assert.equal(calls.at(-1), 'test-ci-down');
      assert.equal(fs.readFileSync(path.join(dir, 'verify.status'), 'utf8').trim(), failed ? 'fail' : 'pass');
      if (failed) {
        assert.match(result.stderr, /backend coverage\s+FAIL/);
        assert.match(result.stderr, /backend coverage evidence/);
      }
    } finally { fs.rmSync(dir, {recursive: true, force: true}); }
  });
}
