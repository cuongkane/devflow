import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {execFileSync, spawnSync} from 'node:child_process';
import {failures, eligible, assertPushable, listOpenPullRequests, prepareMerge} from '../scripts/ci/repair.mjs';
const check = {__typename: 'CheckRun', name: 'Django test suite', workflowName: 'Backend Tests',
  status: 'COMPLETED', conclusion: 'FAILURE', detailsUrl: 'https://github.com/o/r/actions/runs/123/job/456'};
const pr = {state: 'OPEN', isDraft: false, isCrossRepository: false, headRefOid: 'abc', statusCheckRollup: [check]};
test('example Django failure is eligible with passing frontend', () => {
  assert.equal(eligible({...pr, statusCheckRollup: [check, {...check, name: 'Vitest unit suite', conclusion: 'SUCCESS'}]}, {}), true);
});
test('incomplete checks defer repair even when a test already failed', () => {
  for (const pending of [{...check, status: 'IN_PROGRESS'}, {__typename: 'StatusContext', state: 'PENDING'}]) {
    assert.deepEqual(failures({...pr, statusCheckRollup: [check, pending]}), []);
  }
});
test('closed, draft and fork PRs are excluded', () => {
  for (const override of [{state: 'CLOSED'}, {state: 'MERGED'}, {isDraft: true}, {isCrossRepository: true}]) {
    assert.equal(eligible({...pr, ...override}, {}), false);
  }
});
test('failed or timed out GitHub Actions jobs qualify regardless of job name', () => {
  for (const override of [{conclusion: 'SUCCESS'}, {conclusion: 'CANCELLED'},
    {detailsUrl: 'https://external.example/123'},
    {__typename: 'StatusContext'}]) {
    assert.deepEqual(failures({...pr, statusCheckRollup: [{...check, ...override}]}), []);
  }
  assert.equal(failures({...pr, statusCheckRollup: [{...check, conclusion: 'TIMED_OUT'}]}).length, 1);
  for (const name of ['Coverage gate', 'Upload coverage report', 'Lint', 'Build', 'Migration check', 'Deploy']) {
    assert.equal(eligible({...pr, statusCheckRollup: [{...check, name, workflowName: 'CI'}]}, {}), true, name);
  }
});
test('merge conflicts qualify without failed jobs, even with missing or pending checks', () => {
  for (const statusCheckRollup of [null, [], [{...check, conclusion: 'SUCCESS'}], [{...check, status: 'IN_PROGRESS'}]]) {
    for (const conflict of [{mergeable: 'CONFLICTING'}, {mergeStateStatus: 'DIRTY'}]) {
      const candidate = {...pr, ...conflict, statusCheckRollup};
      assert.equal(eligible(candidate, {}), true);
      assert.equal(eligible(candidate, {heads: ['abc']}), false);
      assert.equal(eligible(candidate, {attempts: 3}), false);
      for (const override of [{state: 'CLOSED'}, {isDraft: true}, {isCrossRepository: true}]) {
        assert.equal(eligible({...candidate, ...override}, {}), false);
      }
    }
  }
  assert.equal(eligible({...pr, mergeable: 'UNKNOWN', statusCheckRollup: []}, {}), false);
});
test('all open PR pages are inspected, including PRs after the old 200 limit', () => {
  const pages = Array.from({length: 3}, (_, page) =>
    Array.from({length: 100}, (_, i) => ({number: page * 100 + i + 1})));
  const requests = [];
  const inspected = [];
  const prs = listOpenPullRequests('o/r', args => {
    requests.push(args);
    return JSON.stringify(pages);
  }, (repo, number) => {
    assert.equal(repo, 'o/r');
    inspected.push(number);
    return {...pr, number};
  });
  assert.deepEqual(requests, [['api', '--paginate', '--slurp', 'repos/o/r/pulls?state=open&per_page=100']]);
  assert.equal(prs.length, 300);
  assert.equal(inspected.at(-1), 300);
});
test('attempted heads and exhausted budgets cannot retrigger or starve other PRs', () => {
  assert.equal(eligible(pr, {heads: ['abc'], attempts: 1}), false);
  assert.equal(eligible({...pr, headRefOid: 'def'}, {heads: ['abc'], attempts: 1}), true);
  assert.equal(eligible({...pr, headRefOid: 'def'}, {heads: ['abc'], attempts: 3}), false);
});
test('missing checks are idle', () => assert.equal(eligible({...pr, statusCheckRollup: null}, {}), false));

test('push refuses closed, moved, renamed and draft PRs and dirty verification', () => {
  const original = {...pr, headRefName: 'feature/503'};
  assert.doesNotThrow(() => assertPushable(original, original, ''));
  for (const change of [{state: 'CLOSED'}, {headRefOid: 'new'},
    {headRefName: 'other'}, {baseRefName: 'other'}, {isDraft: true}, {isCrossRepository: true}]) {
    assert.throws(() => assertPushable(original, {...original, ...change}, ''), /refusing to push/);
  }
  assert.throws(() => assertPushable(original, original, ' M tracked.js'), /source tree/);
});

test('conflict preparation preserves HEAD and allows a resolved two-parent merge', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ci-merge-'));
  const git = args => execFileSync('git', ['-C', dir, ...args], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
  try {
    git(['init']);
    git(['config', 'user.email', 'tests@example.com']);
    git(['config', 'user.name', 'Tests']);
    fs.writeFileSync(path.join(dir, 'shared'), 'original\n');
    git(['add', '.']);
    git(['commit', '-m', 'initial']);
    const initial = git(['rev-parse', 'HEAD']).trim();
    fs.writeFileSync(path.join(dir, 'shared'), 'target change\n');
    git(['commit', '-am', 'target']);
    const base = git(['rev-parse', 'HEAD']).trim();
    git(['checkout', '--detach', initial]);
    fs.writeFileSync(path.join(dir, 'shared'), 'PR change\n');
    git(['commit', '-am', 'PR']);
    const head = git(['rev-parse', 'HEAD']).trim();
    assert.deepEqual(prepareMerge(git, base), ['shared']);
    assert.equal(git(['rev-parse', 'HEAD']).trim(), head);
    assert.equal(git(['rev-parse', 'MERGE_HEAD']).trim(), base);
    fs.writeFileSync(path.join(dir, 'shared'), 'target change\nPR change\n');
    git(['add', '-A']);
    git(['diff', '--cached', '--check']);
    git(['commit', '-m', 'resolve conflict']);
    assert.equal(git(['rev-parse', 'HEAD^1']).trim(), head);
    assert.equal(git(['rev-parse', 'HEAD^2']).trim(), base);
  } finally { fs.rmSync(dir, {recursive: true, force: true}); }
});

test('merge preparation propagates errors that are not conflicts', () => {
  const error = new Error('merge cannot start');
  assert.throws(() => prepareMerge(args => {
    if (args[0] === 'merge') throw error;
    return '';
  }, 'base'), error);
});

test('a failed repair does not stop the remaining PRs in the poll', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ci-poll-'));
  const repo = `ci-tests/repo-${path.basename(dir)}`;
  const stateDir = `/tmp/dagu-agent/ci/${repo}`;
  const lockDir = `/tmp/dagu-agent/pr-locks/${repo}`;
  try {
    fs.writeFileSync(path.join(dir, 'gh'), `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'pr') {
  console.log(JSON.stringify({...${JSON.stringify({...pr, headRefName: 'feature', baseRefName: 'main'})}, number: Number(args[2])}));
} else if (args.includes('graphql')) {
  console.log(JSON.stringify({data: {repository: {pullRequest: {closingIssuesReferences: {nodes: []}}}}}));
} else { console.log(JSON.stringify([[{number: 1}, {number: 2}, {number: 3}]])); }
`, {mode: 0o755});
    fs.writeFileSync(path.join(dir, 'flock'), `#!/usr/bin/env node
const fs = require('node:fs');
fs.appendFileSync(process.env.CALL_LOG, process.env.CI_PR_NUMBER + '\\n');
process.exit(process.env.CI_PR_NUMBER === '1' ? 1 : 0);
`, {mode: 0o755});
    const result = spawnSync(process.execPath, ['scripts/ci/repair.mjs'], {
      encoding: 'utf8', env: {...process.env, PATH: `${dir}:${process.env.PATH}`,
        PROJECT_REPO: repo, PROJECT_WORKSPACE: dir, CI_PR_NUMBER: '', CI_VERIFY_EXISTING: 'false',
        CALL_LOG: path.join(dir, 'calls')},
    });
    assert.equal(result.status, 1, result.stderr);
    assert.equal(fs.readFileSync(path.join(dir, 'calls'), 'utf8'), '1\n2\n3\n');
    assert.match(result.stdout, /Inspected 3 PR repairs/);
  } finally {
    for (const target of [dir, stateDir, lockDir]) fs.rmSync(target, {recursive: true, force: true});
  }
});
