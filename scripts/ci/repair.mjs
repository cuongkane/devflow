import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {agentError} from '../retry-failed-issues.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const fields = 'number,title,state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,statusCheckRollup';
const writable = pr => pr.state === 'OPEN' && !pr.isDraft && !pr.isCrossRepository;
export const conflicted = pr => writable(pr) &&
  (pr.mergeable === 'CONFLICTING' || pr.mergeStateStatus === 'DIRTY');
export function failures(pr) {
  const checks = pr.statusCheckRollup ?? [];
  if (!writable(pr) ||
      checks.some(c => c.status ? c.status !== 'COMPLETED' : c.state === 'PENDING')) return [];
  return checks.filter(c => c.__typename === 'CheckRun' &&
    ['FAILURE', 'TIMED_OUT'].includes(c.conclusion) &&
    /\/actions\/runs\/\d+\/job\/\d+/.test(c.detailsUrl ?? ''));
}
export function eligible(pr, state) {
  // Initial attempt plus three retries, including failures on the same head.
  return (conflicted(pr) || failures(pr).length > 0) && (state.attempts ?? 0) < 4;
}
export function quotaAvailable(check = () => run(path.join(root, 'scripts/codex-usage-available.sh'), ['10'], {stdio: 'inherit'})) {
  try { check(); return true; } catch (error) {
    if (error.status !== 75) throw error;
    console.log('PR repairs deferred: less than 10% Codex quota remains');
    return false;
  }
}
export function assertPushable(original, fresh, dirty) {
  if (dirty) throw new Error('Verification changed the source tree');
  if (fresh.state !== 'OPEN' || fresh.headRefOid !== original.headRefOid ||
      fresh.headRefName !== original.headRefName || fresh.baseRefName !== original.baseRefName ||
      fresh.isDraft || fresh.isCrossRepository) {
    throw new Error('PR changed while repairing; refusing to push');
  }
}
const run = (cmd, args, options = {}) => execFileSync(cmd, args.map(String), {
  encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options,
});
const gh = args => run('gh', args);
const read = file => fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
function write(file, data) {
  fs.writeFileSync(`${file}.tmp`, JSON.stringify(data, null, 2));
  fs.renameSync(`${file}.tmp`, file);
}
const view = (repo, n) => JSON.parse(gh(['pr', 'view', n, '--repo', repo, '--json', fields]));
export function listOpenPullRequests(repo, request = gh, inspect = view) {
  // Older worker gh versions support --paginate and --jq, but not --slurp.
  const numbers = request(['api', '--paginate',
    `repos/${repo}/pulls?state=open&per_page=100`, '--jq', '.[].number']);
  return numbers.trim().split(/\s+/).filter(Boolean).map(number => {
    if (!/^\d+$/.test(number)) throw new Error('Invalid PR number in paginated response');
    return inspect(repo, Number(number));
  });
}

// Keep HEAD unchanged for the agent; the orchestrator commits the resolved merge.
export function prepareMerge(git, base) {
  try {
    git(['merge', '--no-commit', '--no-ff', base]);
  } catch (error) {
    if (!git(['diff', '--name-only', '--diff-filter=U']).trim()) throw error;
  }
  return git(['diff', '--name-only', '--diff-filter=U']).trim().split('\n').filter(Boolean);
}

function busyIssue(repo, number) {
  const [owner, name] = repo.split('/');
  const data = JSON.parse(gh(['api', 'graphql', '-f', `owner=${owner}`, '-f', `name=${name}`,
    '-F', `number=${number}`, '-f', `query=query($owner:String!,$name:String!,$number:Int!) {
      repository(owner:$owner,name:$name) { pullRequest(number:$number) {
        closingIssuesReferences(first:100) { nodes { labels(first:100) { nodes { name } } } }
      } }
    }`]));
  return data.data.repository.pullRequest.closingIssuesReferences.nodes.some(issue =>
    issue.labels.nodes.some(l => ['agent:implementing', 'agent:responding'].includes(l.name)));
}

function verifyAndPush(pr, repo, workspace, worktree, attempt, git) {
  const number = pr.number;
  const base = read(path.join(attempt, 'state.json')).base;
  const remote = `https://github.com/${repo}.git`;
  run(path.join(root, 'scripts/implement/run-verification.sh'), [attempt], {stdio: 'inherit'});
  // A frontend failure needs frontend checks even if the branch only changes backend code.
  if (failures(pr).some(c => /frontend|vitest|jest|vite|angular/i.test(`${c.name} ${c.workflowName}`)) &&
      !git(['diff', '--name-only', `${base}...HEAD`]).split('\n').some(p => p.startsWith('sweatcharge_fe/'))) {
    run(path.join(root, 'scripts/implement/install-frontend-deps.sh'), [attempt], {stdio: 'inherit'});
    for (const command of ['lint', 'test:unit', 'build']) {
      run('yarn', [command], {cwd: path.join(worktree, 'sweatcharge_fe'), stdio: 'inherit'});
    }
  }
  const fresh = view(repo, number);
  assertPushable(pr, fresh, git(['status', '--porcelain']).trim());
  git(['fetch', remote, `refs/heads/${pr.baseRefName}`]);
  if (git(['rev-parse', 'FETCH_HEAD']).trim() !== base) {
    throw new Error('Target branch moved during verification; refusing to push');
  }
  git(['push', remote, `HEAD:refs/heads/${pr.headRefName}`]);
  write(path.join(attempt, 'outcome.json'), {status: 'pushed', head: git(['rev-parse', 'HEAD']).trim(),
    note: 'Local verification passed; awaiting GitHub Actions'});
  console.log(`PR #${number}: fix pushed; awaiting GitHub Actions`);
  run('git', ['-C', workspace, 'worktree', 'remove', '--force', worktree]);

}

function repair(repo, workspace, dir, number) {
  const pr = view(repo, number);
  const stateFile = path.join(dir, 'attempts.json');
  const state = read(stateFile);
  const resume = process.env.CI_VERIFY_EXISTING === 'true';
  if (!resume && !eligible(pr, state)) return;
  if (resume && !conflicted(pr) && !failures(pr).length) throw new Error('PR no longer needs repair');
  if (busyIssue(repo, number)) {
    console.log(`PR #${number}: linked issue is being edited; deferring`);
    return;
  }
  if (!resume && !quotaAvailable()) return;
  // Consume before invoking external work: crashes must not spend again forever.
  if (!resume) {
    state.heads = [...(state.heads ?? []), pr.headRefOid];
    state.attempts = (state.attempts ?? 0) + 1;
    state.lastAttempt = state.attempts;
    write(stateFile, state);
  }
  const suffix = state.lastAttempt ? `-attempt-${state.lastAttempt}` : '';
  const attempt = path.join(dir, `${pr.headRefOid}${suffix}`);
  fs.mkdirSync(attempt, {recursive: true});
  const worktree = path.join(`${workspace}-worktrees`, `ci-pr-${number}-${pr.headRefOid.slice(0, 12)}${suffix}`);
  const git = args => run('git', ['-C', worktree, ...args]);
  let created = false;
  try {
    if (resume) {
      const saved = read(path.join(attempt, 'state.json'));
      if (saved.worktree !== worktree || !saved.base ||
          read(path.join(attempt, 'result.json')).status !== 'fixed' ||
          read(path.join(attempt, 'outcome.json')).status !== 'failed') {
        throw new Error('No completed repair with failed verification to resume');
      }
      if (git(['status', '--porcelain']).trim() || git(['rev-parse', 'HEAD']).trim() === pr.headRefOid) {
        throw new Error('Resume requires a clean, committed repair');
      }
      git(['merge-base', '--is-ancestor', pr.headRefOid, 'HEAD']);
      created = true;
      verifyAndPush(pr, repo, workspace, worktree, attempt, git);
      created = false;
      return;
    }
    // Fetch from the configured repository explicitly, never an unverified origin.
    const remote = `https://github.com/${repo}.git`;
    run('git', ['-C', workspace, 'fetch', remote, `refs/pull/${number}/head`]);
    const fetched = run('git', ['-C', workspace, 'rev-parse', 'FETCH_HEAD']).trim();
    if (fetched !== pr.headRefOid) throw new Error('PR moved during fetch; wait for next poll');
    run('git', ['-C', workspace, 'worktree', 'add', '--detach', worktree, fetched]);
    created = true;
    run('git', ['-C', workspace, 'fetch', remote, `refs/heads/${pr.baseRefName}`]);
    const base = run('git', ['-C', workspace, 'rev-parse', 'FETCH_HEAD']).trim();
    write(path.join(attempt, 'state.json'), {worktree, base});
    const conflicts = conflicted(pr) ? prepareMerge(git, base) : [];
    const logs = [];
    for (const check of failures(pr)) {
      const [, , jobId] = check.detailsUrl.match(/\/actions\/runs\/(\d+)\/job\/(\d+)/);
      // Read the raw job log: older gh parsers can silently omit newer runner steps.
      const log = gh(['api', `repos/${repo}/actions/jobs/${jobId}/logs`]);
      if (!log.trim()) throw new Error(`No failure log for ${check.name}`);
      const file = path.join(attempt, `${jobId}.log`);
      fs.writeFileSync(file, log);
      fs.writeFileSync(`${file}.tail`, log.split('\n').slice(-400).join('\n'));
      logs.push({name: check.name, full: file, tail: `${file}.tail`});
    }
    const context = {repo, pr: number, head: pr.headRefOid, base, baseRefName: pr.baseRefName,
      mergeStarted: conflicted(pr), conflicts, worktree, logs,
      result: path.join(attempt, 'result.json')};
    const prompt = fs.readFileSync(path.join(root, 'prompts/resolve-failed-tests.md'), 'utf8');
    fs.writeFileSync(path.join(attempt, 'prompt.md'), `${prompt}\n\nContext:\n${JSON.stringify(context, null, 2)}\n` +
      run(path.join(root, 'scripts/standards.sh'), ['engineering-practices', 'testing-standards']));
    run(path.join(root, 'run-agent.sh'), [path.join(attempt, 'prompt.md'), '8',
      path.join(attempt, 'agent-stream.jsonl'), 'standard'], {cwd: worktree, stdio: 'inherit'});
    const result = read(context.result);
    if (result.status !== 'fixed') throw new Error(result.error || 'Agent did not produce a fix');
    if (git(['rev-parse', 'HEAD']).trim() !== fetched) throw new Error('Agent changed HEAD');
    if (!git(['status', '--porcelain']).trim()) throw new Error('Agent produced no changes');
    git(['add', '-A']);
    if (git(['diff', '--name-only', '--diff-filter=U']).trim()) throw new Error('Unresolved merge conflicts');
    git(['diff', '--cached', '--check']);
    // Commit locally first so existing verification sees the complete final diff.
    git(['commit', '-m', `fix: repair pipeline and merge conflicts on PR #${number}`]);
    verifyAndPush(pr, repo, workspace, worktree, attempt, git);
    created = false;
  } catch (error) {
    const stream = path.join(attempt, 'agent-stream.jsonl');
    const reason = agentError(fs.existsSync(stream) ? fs.readFileSync(stream, 'utf8') : '') || error.message;
    write(path.join(attempt, 'outcome.json'), {status: 'failed', error: reason, worktree});
    console.error(`PR #${number}: ${reason}; artifacts: ${attempt}`);
    process.exitCode = 1;
  } finally {
    // Reclaim bulky dependencies but preserve failed edits and commits for inspection.
    if (created) run(path.join(root, 'scripts/implement/reclaim-workspace.sh'), [workspace, attempt], {stdio: 'inherit'});
  }
}

function main() {
  const repo = process.env.PROJECT_REPO;
  const workspace = process.env.PROJECT_WORKSPACE;
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo ?? '') || !workspace) throw new Error('PROJECT_REPO and PROJECT_WORKSPACE are required');
  const selected = process.env.CI_PR_NUMBER || '';
  if (process.env.CI_VERIFY_EXISTING === 'true' && !selected) throw new Error('VERIFY_EXISTING requires PR_NUMBER');
  if (selected && !/^\d+$/.test(selected)) throw new Error('PR_NUMBER must be numeric');
  const home = `/tmp/dagu-agent/ci/${repo}`;
  fs.mkdirSync(home, {recursive: true});
  if (process.argv[2] === '--repair') {
    repair(repo, workspace, path.join(home, selected), selected);
    return;
  }
  const prs = selected ? [view(repo, selected)] : listOpenPullRequests(repo);
  let attempted = 0;
  let checkedQuota = false;
  for (const pr of prs.sort((a, b) => a.number - b.number)) {
    const dir = path.join(home, String(pr.number));
    fs.mkdirSync(dir, {recursive: true});
    const state = read(path.join(dir, 'attempts.json'));
    const checks = pr.statusCheckRollup ?? [];
    if (!conflicted(pr) && checks.length && checks.every(c => c.conclusion === 'SUCCESS' || c.state === 'SUCCESS')) {
      write(path.join(dir, 'attempts.json'), {heads: [], attempts: 0});
      state.heads = [];
      state.attempts = 0;
    }
    if (process.env.CI_VERIFY_EXISTING !== 'true' && !eligible(pr, state)) continue;
    if (busyIssue(repo, pr.number)) continue;
    if (process.env.CI_VERIFY_EXISTING !== 'true' && !checkedQuota) {
      if (!quotaAvailable()) return;
      checkedQuota = true;
    }
    const lock = `/tmp/dagu-agent/pr-locks/${repo}/${pr.number}.lock`;
    fs.mkdirSync(path.dirname(lock), {recursive: true});
    try {
      run('flock', ['-n', '-E', '75', lock, 'node', fileURLToPath(import.meta.url), '--repair'], {
        env: {...process.env, CI_PR_NUMBER: String(pr.number)}, stdio: 'inherit',
      });
      attempted++;
    } catch (error) {
      if (error.status === 75) continue;
      attempted++;
      console.error(`Could not run repair for PR #${pr.number}: ${error.message}`);
      process.exitCode = 1;
    }
  }
  console.log(attempted ? `Inspected ${attempted} PR repairs` : 'No eligible pipeline failures or merge conflicts');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
