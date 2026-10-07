import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const MAX_RETRIES = 3;
const queues = {clarify: 'agent:todo', major: 'agent:major-task:ready-to-implement',
  minor: 'agent:minor-task:ready-to-implement'};
const working = pipeline => pipeline === 'clarify' ? 'agent:clarifying' : 'agent:implementing';
const execute = (command, args, options = {}) => execFileSync(command, args, {
  encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options,
});
const read = file => fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
const readArtifact = file => { try { return read(file); } catch { return null; } };
const write = (file, value) => {
  fs.mkdirSync(path.dirname(file), {recursive: true});
  const temp = `${file}.tmp.${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify(value, null, 2));
  fs.renameSync(temp, file);
};
const valid = state => state && Object.hasOwn(queues, state.pipeline) &&
  Number.isInteger(state.retries) && state.retries >= 0 && state.retries <= MAX_RETRIES;
const marker = state => `<!-- agent:retry-state ${JSON.stringify(state)} -->`;

export function agentError(stream) {
  // Use structured error events, never an arbitrary successful agent message.
  for (const line of stream.trim().split('\n').reverse()) {
    let event;
    try { event = JSON.parse(line); } catch { continue; }
    if (['error', 'turn.failed'].includes(event.type)) {
      const message = event.error?.message || event.message;
      if (typeof message === 'string' && message.trim()) return message;
    }
  }
  return '';
}

export function inferFailure(issue, implementation = {}) {
  for (const comment of [...(issue.comments ?? [])].reverse()) {
    const match = comment.body.match(/<!-- agent:retry-state (.+) -->/);
    if (match) {
      const state = JSON.parse(match[1]);
      if (!valid(state)) throw new Error('Invalid saved retry state');
      return state;
    }
    if (/Clarification run `[^`]+` (?:did not complete|failed before reporting)/.test(comment.body)) {
      return {pipeline: 'clarify', retries: 0, status: 'failed', reason: comment.body};
    }
    if (/Implementation run `[^`]+` (?:did not complete|failed before reporting)/.test(comment.body)) {
      return {pipeline: implementation.size === 'minor' ? 'minor' : 'major',
        retries: 0, status: 'failed', phase: implementation.phase, reason: comment.body};
    }
  }
  return null;
}

export function retryPlan(issue, state) {
  const labels = (issue.labels ?? []).map(label => label.name);
  if (issue.state !== 'OPEN' || !labels.includes('agent:failed') ||
      labels.some(label => label.startsWith('agent:') && label !== 'agent:failed') || !valid(state)) return null;
  if (state.status === 'retry-pending') return {queue: queues[state.pipeline], retries: state.retries};
  if (state.status !== 'failed' || state.retries >= MAX_RETRIES) return null;
  return {queue: queues[state.pipeline], retries: state.retries + 1};
}

export class RetryManager {
  constructor({gh = args => execute('gh', args),
    quota = () => execute(path.join(root, 'scripts/codex-usage-available.sh'), ['10'], {stdio: 'inherit'}),
    stateRoot = '/tmp/dagu-agent/retries', artifactRoot = '/tmp/dagu-agent'} = {}) {
    Object.assign(this, {gh, quota, stateRoot, artifactRoot});
  }
  file(repo, issue) {
    if (!/^[\w.-]+\/[\w.-]+$/.test(repo) || !/^\d+$/.test(String(issue))) throw new Error('Invalid repository or issue');
    return path.join(this.stateRoot, repo, `${issue}.json`);
  }
  view(repo, issue) {
    return JSON.parse(this.gh(['issue', 'view', String(issue), '--repo', repo, '--json', 'number,state,labels,comments']));
  }
  load(repo, issue, remote) {
    const local = read(this.file(repo, issue));
    if (local) {
      if (!valid(local)) throw new Error('Invalid local retry state');
      return local;
    }
    const inferred = inferFailure(remote ?? this.view(repo, issue),
      readArtifact(path.join(this.artifactRoot, String(issue), 'implement/state.json')) ?? {});
    if (!inferred) return null;
    const phase = inferred.pipeline === 'clarify' ? 'clarify' : inferred.phase;
    const dir = path.join(this.artifactRoot, String(issue), inferred.pipeline === 'clarify' ? 'clarify' : `implement/${phase ?? ''}`);
    const stream = path.join(dir, 'agent-stream.jsonl');
    const evidence = agentError(fs.existsSync(stream) ? fs.readFileSync(stream, 'utf8') : '');
    return {...inferred, phase, reason: evidence || inferred.reason};
  }
  save(repo, issue, state) { write(this.file(repo, issue), state); }
  comment(repo, issue, body) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dagu-retry-comment-'));
    try {
      const file = path.join(dir, 'body.md');
      fs.writeFileSync(file, body);
      this.gh(['issue', 'comment', String(issue), '--repo', repo, '--body-file', file]);
    } finally { fs.rmSync(dir, {recursive: true, force: true}); }
  }
  start(repo, issue, pipeline, runId) {
    if (!Object.hasOwn(queues, pipeline)) throw new Error('Invalid pipeline');
    const previous = this.load(repo, issue);
    // Retry with fresh phase results, retaining every prior run and its logs.
    const stage = pipeline === 'clarify' ? 'clarify' : 'implement';
    const runDir = path.join(this.artifactRoot, String(issue), stage);
    if (fs.existsSync(runDir)) {
      const history = path.join(this.artifactRoot, String(issue), 'history');
      fs.mkdirSync(history, {recursive: true});
      fs.renameSync(runDir, path.join(history, `${stage}-${Date.now()}-${process.pid}`));
    }
    this.save(repo, issue, {pipeline, runId, status: 'running',
      retries: previous?.status === 'completed' ? 0 : previous?.retries ?? 0});
  }
  complete(repo, issue, pipeline, runId) {
    const state = this.load(repo, issue);
    if (state?.runId !== runId) return;
    this.save(repo, issue, {...state, status: pipeline === 'clarify' ? 'handoff' : 'completed',
      retries: pipeline === 'clarify' ? state.retries : 0});
  }
  fail(repo, issue, pipeline, runId, log = '', suppliedReason = '') {
    if (!Object.hasOwn(queues, pipeline)) throw new Error('Invalid pipeline');
    const remote = this.view(repo, issue);
    const labels = remote.labels.map(label => label.name);
    if (remote.state !== 'OPEN' || !labels.includes(working(pipeline)) && !labels.includes('agent:failed')) return;
    const previous = this.load(repo, issue, remote);
    // An old handler must never overwrite a newer run or a queued retry.
    if (previous?.runId && previous.runId !== runId ||
        previous?.runId === runId && ['retry-pending', 'queued', 'completed'].includes(previous.status)) return;
    if (previous?.runId === runId && previous.reported) {
      if (labels.includes(working(pipeline))) {
        this.gh(['issue', 'edit', String(issue), '--repo', repo, '--remove-label', working(pipeline), '--add-label', 'agent:failed']);
      }
      return;
    }
    const runDir = path.join(this.artifactRoot, String(issue), pipeline === 'clarify' ? 'clarify' : 'implement');
    const implementation = readArtifact(path.join(runDir, 'state.json')) ?? {};
    const phase = pipeline === 'clarify' ? 'clarify' : implementation.phase ?? 'claim/setup';
    const phaseDir = pipeline === 'clarify' ? runDir : path.join(runDir, phase);
    const result = readArtifact(path.join(phaseDir, 'result.json')) ?? {};
    const stream = path.join(phaseDir, 'agent-stream.jsonl');
    const evidence = agentError(fs.existsSync(stream) ? fs.readFileSync(stream, 'utf8') : '');
    const reason = suppliedReason || evidence || result.error ||
      'No successful result was recorded. The process may have exited, timed out or exhausted its budget; inspect the run log.';
    const state = {pipeline, runId, phase, reason, log, status: 'failed', retries: previous?.retries ?? 0};
    // Keep the poller from requeueing between the label edit and the final save.
    this.save(repo, issue, {...state, status: 'reporting'});
    const retryMessage = state.retries < MAX_RETRIES ?
      `Automatic retry ${state.retries + 1}/${MAX_RETRIES} will return this issue to \`${queues[pipeline]}\` when quota is available.` :
      `All ${MAX_RETRIES} automatic retries have been used. This issue stays on \`agent:failed\` for investigation.`;
    let body = `${pipeline === 'clarify' ? 'Clarification' : 'Implementation'} run \`${runId}\` failed.\n\n` +
      `Workflow: **${pipeline === 'clarify' ? 'clarification' : `${pipeline} implementation`}**\nPhase: **${phase}**\n\n${reason}\n\n` +
      `${retryMessage}\n\nWorking files: \`${runDir}\`\nLog: \`${log || 'see Dagu run'}\`\n\n${marker(state)}\n`;
    const usage = path.join(runDir, 'usage.md');
    if (fs.existsSync(usage)) body += `\n<details>\n<summary>Run accounting</summary>\n\n${fs.readFileSync(usage, 'utf8')}\n</details>\n`;
    this.comment(repo, issue, body);
    // Recheck the label after reporting; leave a human's intervening relabel alone.
    const fresh = this.view(repo, issue);
    // Save before publishing the failed label. The retry poller can immediately
    // requeue it after that edit, so no old run may save state afterward.
    this.save(repo, issue, {...state, reported: true});
    if (fresh.state === 'OPEN' && fresh.labels.some(label => label.name === working(pipeline))) {
      this.gh(['issue', 'edit', String(issue), '--repo', repo, '--remove-label', working(pipeline), '--add-label', 'agent:failed']);
    }
    console.log(`Issue #${issue}: ${pipeline}/${phase} failed; retries ${state.retries}/${MAX_RETRIES}: ${reason}`);
  }
  scan(repo) {
    const numbers = this.gh(['api', '--paginate', `repos/${repo}/issues?state=open&labels=agent%3Afailed&per_page=100`,
      '--jq', '.[] | select(.pull_request == null) | .number']).trim().split(/\s+/).filter(Boolean);
    let checkedQuota = false;
    let failed = false;
    for (const number of numbers) {
      try {
        const issue = this.view(repo, number);
        const state = this.load(repo, number, issue);
        const plan = retryPlan(issue, state);
        if (!plan) {
          console.log(`Issue #${number}: ${state?.retries >= MAX_RETRIES ? 'retry limit reached' : 'no eligible failed workflow'}; leaving it unchanged`);
          continue;
        }
        if (!checkedQuota) {
          try { this.quota(); } catch (error) {
            if (error.status === 75) { console.log('Retries deferred: less than 10% Codex quota remains'); return; }
            throw error;
          }
          checkedQuota = true;
        }
        // Persist before external writes; interrupted relabels resume this same retry.
        const pending = {...state, retries: plan.retries, status: 'retry-pending'};
        this.save(repo, number, pending);
        this.comment(repo, number, `Retry **${plan.retries}/${MAX_RETRIES}** for **${state.pipeline === 'clarify' ? 'clarification' : `${state.pipeline} implementation`}**` +
          ` (failed phase: \`${state.phase ?? 'unknown'}\`).\n\nPrevious failure: ${state.reason ?? 'see the previous failure report'}\n\n` +
          `Returning to \`${plan.queue}\`; the corresponding workflow will pick it up. Existing worktrees are retained.\n\n${marker(pending)}\n`);
        const fresh = this.view(repo, number);
        if (!retryPlan(fresh, pending)) continue;
        this.gh(['issue', 'edit', number, '--repo', repo, '--remove-label', 'agent:failed', '--add-label', plan.queue]);
        // No save after the label edit: a new claim can already be running.
        // Its start record must win over this poller's pending record.
        console.log(`Issue #${number}: retry ${plan.retries}/${MAX_RETRIES} -> ${plan.queue}`);
      } catch (error) {
        console.error(`Issue #${number}: ${error.message}`);
        failed = true;
      }
    }
    if (failed) throw new Error('Some failed issues could not be requeued');
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command, repo, issue, pipeline, runId, log, reason] = process.argv.slice(2);
  const manager = new RetryManager();
  if (command === 'scan') manager.scan(repo);
  else if (command === 'start') manager.start(repo, issue, pipeline, runId);
  else if (command === 'complete') manager.complete(repo, issue, pipeline, runId);
  else if (command === 'fail') manager.fail(repo, issue, pipeline, runId, log, reason);
  else throw new Error('Expected scan, start, complete or fail');
}
