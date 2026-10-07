import test from 'node:test';
import assert from 'node:assert/strict';
import {failures, eligible, assertPushable} from '../scripts/ci/repair.mjs';
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
test('only failed or timed out GitHub Actions test jobs qualify', () => {
  for (const override of [{conclusion: 'SUCCESS'}, {conclusion: 'CANCELLED'},
    {name: 'deploy', workflowName: 'Deployment'}, {detailsUrl: 'https://external.example/123'},
    {__typename: 'StatusContext'}]) {
    assert.deepEqual(failures({...pr, statusCheckRollup: [{...check, ...override}]}), []);
  }
  assert.equal(failures({...pr, statusCheckRollup: [{...check, conclusion: 'TIMED_OUT'}]}).length, 1);
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
    {headRefName: 'other'}, {isDraft: true}, {isCrossRepository: true}]) {
    assert.throws(() => assertPushable(original, {...original, ...change}, ''), /refusing to push/);
  }
  assert.throws(() => assertPushable(original, original, ' M tracked.js'), /source tree/);
});
