import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {RetryManager, inferFailure, retryPlan, agentError} from '../scripts/retry-failed-issues.mjs';

const issue = (number = 527) => ({number, state: 'OPEN', labels: [{name: 'agent:failed'}], comments: []});
function fixture(t, {quota = () => {}} = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'issue-retries-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const issues = new Map([[527, issue()]]);
  const calls = [];
  const gh = args => {
    calls.push(args);
    if (args[0] === 'api') return [...issues.keys()].join('\n') + '\n';
    const current = issues.get(Number(args[2]));
    if (args[1] === 'view') return JSON.stringify(current);
    if (args[1] === 'comment') {
      current.comments.push({body: fs.readFileSync(args.at(-1), 'utf8')});
    } else if (args[1] === 'edit') {
      const remove = args[args.indexOf('--remove-label') + 1];
      const add = args[args.indexOf('--add-label') + 1];
      current.labels = current.labels.filter(label => label.name !== remove).concat({name: add});
    } else assert.fail(`Unexpected call: ${args}`);
    return '';
  };
  const manager = new RetryManager({gh, quota, stateRoot: path.join(dir, 'retries'), artifactRoot: path.join(dir, 'artifacts')});
  return {dir, issues, calls, manager};
}

test('legacy clarification failure is identified without implementation metadata', () => {
  const remote = issue();
  remote.comments = [{body: 'Clarification run `old` did not complete.\nNo result.json.'}];
  const state = inferFailure(remote, {size: 'minor'});
  assert.equal(state.pipeline, 'clarify');
  assert.deepEqual(retryPlan(remote, state), {queue: 'agent:todo', retries: 1});
});
test('legacy implementation failures keep their known size; newest failure wins', () => {
  const remote = {...issue(), comments: [
    {body: 'Clarification run `first` did not complete.'},
    {body: 'Implementation run `second` did not complete.'},
  ]};
  assert.equal(inferFailure(remote, {size: 'minor', phase: 'tests'}).pipeline, 'minor');
  assert.equal(inferFailure(remote).pipeline, 'major');
  assert.equal(inferFailure({...remote, comments: []}), null);
});
test('closed, blocked, unknown and already claimed issues are not retried', () => {
  const failed = {pipeline: 'clarify', retries: 0, status: 'failed'};
  for (const remote of [{...issue(), state: 'CLOSED'}, {...issue(), labels: [{name: 'agent:revising'}]},
    {...issue(), labels: [{name: 'agent:failed'}, {name: 'agent:implementing'}]}]) {
    assert.equal(retryPlan(remote, failed), null);
  }
  assert.equal(retryPlan(issue(), null), null);
  assert.equal(retryPlan(issue(), {...failed, status: 'running'}), null);
});

test('exactly three retries are queued, and the fourth failure stays failed', t => {
  const {issues, manager} = fixture(t);
  manager.save('o/r', 527, {pipeline: 'clarify', retries: 0, status: 'failed'});
  for (let retry = 1; retry <= 3; retry++) {
    manager.scan('o/r');
    assert.deepEqual(issues.get(527).labels, [{name: 'agent:todo'}]);
    assert.equal(manager.load('o/r', 527).retries, retry);
    issues.get(527).labels = [{name: 'agent:clarifying'}];
    manager.start('o/r', 527, 'clarify', `run-${retry}`);
    manager.fail('o/r', 527, 'clarify', `run-${retry}`, '', 'test failure');
  }
  const comments = issues.get(527).comments.length;
  manager.scan('o/r');
  assert.equal(issues.get(527).comments.length, comments);
  assert.deepEqual(issues.get(527).labels, [{name: 'agent:failed'}]);
  assert.match(issues.get(527).comments.at(-1).body, /All 3 automatic retries have been used/);
});
test('quota deferral and lookup errors never requeue or consume a retry', t => {
  for (const status of [75, 1]) {
    const {manager, calls, issues} = fixture(t, {quota: () => { throw Object.assign(new Error('quota failed'), {status}); }});
    manager.save('o/r', 527, {pipeline: 'clarify', retries: 1, status: 'failed'});
    if (status === 75) manager.scan('o/r');
    else assert.throws(() => manager.scan('o/r'), /could not be requeued/);
    assert.equal(manager.load('o/r', 527).retries, 1);
    assert.deepEqual(issues.get(527).labels, [{name: 'agent:failed'}]);
    assert.equal(calls.some(args => ['comment', 'edit'].includes(args[1])), false);
  }
});
test('a failed relabel resumes the same retry after restart', t => {
  const {manager, issues} = fixture(t);
  manager.save('o/r', 527, {pipeline: 'minor', retries: 2, status: 'failed'});
  const gh = manager.gh;
  manager.gh = args => {
    if (args[1] === 'edit') throw new Error('temporary API failure');
    return gh(args);
  };
  assert.throws(() => manager.scan('o/r'), /could not be requeued/);
  assert.equal(manager.load('o/r', 527).status, 'retry-pending');
  assert.equal(manager.load('o/r', 527).retries, 3);
  manager.gh = gh;
  manager.scan('o/r');
  assert.equal(manager.load('o/r', 527).retries, 3);
  assert.deepEqual(issues.get(527).labels, [{name: 'agent:minor-task:ready-to-implement'}]);
});
test('a new claim started during the retry label edit keeps its state and budget', t => {
  const {manager, issues} = fixture(t);
  manager.save('o/r', 527, {pipeline: 'clarify', retries: 0, status: 'failed'});
  const gh = manager.gh;
  manager.gh = args => {
    const result = gh(args);
    if (args[1] === 'edit') {
      issues.get(527).labels = [{name: 'agent:clarifying'}];
      manager.start('o/r', 527, 'clarify', 'new-run');
    }
    return result;
  };
  manager.scan('o/r');
  assert.equal(manager.load('o/r', 527).status, 'running');
  assert.equal(manager.load('o/r', 527).runId, 'new-run');
  assert.equal(manager.load('o/r', 527).retries, 1);
});
test('requeue during failure publication cannot be overwritten by the failed run', t => {
  const {manager, issues} = fixture(t);
  issues.get(527).labels = [{name: 'agent:clarifying'}];
  manager.start('o/r', 527, 'clarify', 'run');
  const gh = manager.gh;
  manager.gh = args => {
    const result = gh(args);
    if (args[1] === 'edit' && args.at(-1) === 'agent:failed') manager.scan('o/r');
    return result;
  };
  manager.fail('o/r', 527, 'clarify', 'run', '', 'failed');
  assert.equal(manager.load('o/r', 527).retries, 1);
  assert.equal(manager.load('o/r', 527).status, 'retry-pending');
});
test('remote markers retain the retry budget if local state is lost', t => {
  const {manager} = fixture(t);
  manager.save('o/r', 527, {pipeline: 'clarify', retries: 2, status: 'failed'});
  manager.scan('o/r');
  fs.rmSync(manager.file('o/r', 527));
  const restored = manager.load('o/r', 527);
  assert.equal(restored.retries, 3);
  assert.equal(restored.pipeline, 'clarify');
});
test('clarification handoff preserves the total budget and implementation success resets it', t => {
  const {manager, issues} = fixture(t);
  manager.save('o/r', 527, {pipeline: 'clarify', retries: 2, status: 'queued'});
  manager.start('o/r', 527, 'clarify', 'clarify-run');
  manager.complete('o/r', 527, 'clarify', 'clarify-run');
  manager.start('o/r', 527, 'minor', 'implement-run');
  assert.equal(manager.load('o/r', 527).retries, 2);
  manager.complete('o/r', 527, 'minor', 'implement-run');
  manager.start('o/r', 527, 'clarify', 'new-run');
  assert.equal(manager.load('o/r', 527).retries, 0);
});
test('failure reporting exposes the actual quota error and is idempotent', t => {
  const {manager, issues} = fixture(t);
  issues.get(527).labels = [{name: 'agent:clarifying'}];
  manager.start('o/r', 527, 'clarify', 'run');
  const dir = path.join(manager.artifactRoot, '527/clarify');
  fs.mkdirSync(dir, {recursive: true});
  fs.writeFileSync(path.join(dir, 'result.json'), '{broken');
  fs.writeFileSync(path.join(dir, 'agent-stream.jsonl'), JSON.stringify({type: 'turn.failed', error: {message: "You've hit your usage limit."}}));
  manager.fail('o/r', 527, 'clarify', 'run', '/log');
  const body = issues.get(527).comments.at(-1).body;
  assert.match(body, /Workflow: \*\*clarification\*\*/);
  assert.match(body, /You've hit your usage limit/);
  assert.match(body, /Automatic retry 1\/3/);
  const count = issues.get(527).comments.length;
  manager.fail('o/r', 527, 'clarify', 'run', '/log');
  assert.equal(issues.get(527).comments.length, count);
  manager.start('o/r', 527, 'clarify', 'new-run');
  manager.fail('o/r', 527, 'clarify', 'run');
  assert.equal(manager.load('o/r', 527).runId, 'new-run');
});
test('retry archives old phase results and logs without touching the worktree', t => {
  const {manager, dir} = fixture(t);
  const artifacts = path.join(manager.artifactRoot, '527/implement/tests');
  fs.mkdirSync(artifacts, {recursive: true});
  fs.writeFileSync(path.join(artifacts, 'result.json'), '{"status":"blocked"}');
  const worktree = path.join(dir, 'worktree');
  fs.mkdirSync(worktree);
  fs.writeFileSync(path.join(worktree, 'edits'), 'keep');
  manager.start('o/r', 527, 'major', 'run');
  assert.equal(fs.existsSync(artifacts), false);
  const history = path.join(manager.artifactRoot, '527/history');
  assert.equal(fs.readFileSync(path.join(history, fs.readdirSync(history)[0], 'tests/result.json'), 'utf8'), '{"status":"blocked"}');
  assert.equal(fs.readFileSync(path.join(worktree, 'edits'), 'utf8'), 'keep');
});
test('structured errors are read without mistaking normal agent text for errors', () => {
  assert.equal(agentError('bad json\n{"type":"message","message":"not an error"}\n'), '');
  assert.equal(agentError('{"type":"error","message":"rate limited"}'), 'rate limited');
});

test('clarification claim respects the 10% gate before changing labels', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'clarify-claim-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  fs.copyFileSync('scripts/claim-clarify-issue.sh', path.join(dir, 'claim.sh'));
  fs.writeFileSync(path.join(dir, 'codex-usage-available.sh'), '#!/bin/sh\n[ "$1" = 10 ] || exit 99\nexit "$QUOTA_STATUS"\n', {mode: 0o755});
  fs.writeFileSync(path.join(dir, 'relabel.sh'), '#!/bin/sh\necho "$*" >> "$CALL_LOG"\n', {mode: 0o755});
  for (const status of [75, 1, 0]) {
    const result = spawnSync('sh', [path.join(dir, 'claim.sh'), 'o/r', '527'], {
      encoding: 'utf8', env: {...process.env, QUOTA_STATUS: String(status), CALL_LOG: path.join(dir, 'calls')},
    });
    assert.equal(result.status, status === 1 ? 1 : 0);
    if (status !== 0) assert.equal(fs.existsSync(path.join(dir, 'calls')), false);
    else assert.match(fs.readFileSync(path.join(dir, 'calls'), 'utf8'), /o\/r 527 agent:todo agent:clarifying/);
    assert.equal(result.stdout.trim(), status === 75 ? 'no' : status === 0 ? 'yes' : '');
  }
});

test('the real quota helper defers fractional windows below 10% and accepts 10%', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'quota-boundary-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  fs.mkdirSync(path.join(dir, 'scripts'));
  fs.copyFileSync('scripts/codex-usage-available.sh', path.join(dir, 'scripts/usage.sh'));
  fs.writeFileSync(path.join(dir, 'agent.yaml'), 'agent: codex\n');
  fs.writeFileSync(path.join(dir, 'codex'), `#!/usr/bin/env node
require('node:readline').createInterface({input: process.stdin}).on('line', line => {
  if (JSON.parse(line).id === 2) console.log(JSON.stringify({id: 2, result: {rateLimits: {
    primary: {usedPercent: 80}, secondary: {usedPercent: Number(process.env.USED_PERCENT)}
  }}}));
});
`, {mode: 0o755});
  for (const used of [90.5, 90, 89.5]) {
    const result = spawnSync('bash', [path.join(dir, 'scripts/usage.sh'), '10'], {
      encoding: 'utf8', env: {...process.env, PATH: `${dir}:${process.env.PATH}`, USED_PERCENT: String(used)},
    });
    assert.equal(result.status, used > 90 ? 75 : 0, result.stderr);
    assert.doesNotMatch(result.stderr, /integer expression expected/);
  }
});

test('delivery retry reuses an existing PR instead of creating a duplicate', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'retry-delivery-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  const bin = path.join(dir, 'bin');
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(dir, 'state.json'), JSON.stringify({worktree: dir, branch: 'feature/527',
    base: 'origin/master', issue: '527', title: 'Test issue'}));
  fs.writeFileSync(path.join(dir, 'pr-body.md'), 'Closes #527\n');
  fs.writeFileSync(path.join(bin, 'git'), `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === 'remote') console.log('https://github.com/o/r.git');
if (args[0] === 'log') console.log('abc existing commit');
`, {mode: 0o755});
  fs.writeFileSync(path.join(bin, 'gh'), `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[1] === 'create') process.exit(42);
if (args[1] === 'list') console.log(JSON.stringify([{url: 'https://github.com/o/r/pull/551', baseRefName: 'master'}]));
`, {mode: 0o755});
  const result = spawnSync('sh', ['scripts/implement/open-pull-request.sh', 'o/r', dir], {
    encoding: 'utf8', env: {...process.env, PATH: `${bin}:${process.env.PATH}`},
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'state.json'), 'utf8')).pr_url, 'https://github.com/o/r/pull/551');
});
