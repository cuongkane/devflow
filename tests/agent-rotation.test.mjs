import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

function fixture(preferred, claudeUsed, codexUsed, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'agent-rotation-'));
  fs.mkdirSync(path.join(dir, 'scripts'));
  fs.mkdirSync(path.join(dir, 'bin'));
  for (const file of ['select-agent.sh', 'check-claude-usage.sh', 'check-codex-usage.sh', 'codex-usage-available.sh']) {
    fs.copyFileSync(`scripts/${file}`, path.join(dir, 'scripts', file));
  }
  fs.copyFileSync('run-agent.sh', path.join(dir, 'run-agent.sh'));
  fs.copyFileSync('render-agent-stream.jq', path.join(dir, 'render-agent-stream.jq'));
  fs.writeFileSync(path.join(dir, 'agent.yaml'), `agent: ${preferred}\nmodel_claude_standard: sonnet\nmodel_codex_standard: default\n`);
  fs.writeFileSync(path.join(dir, 'prompt.md'), 'test');
  const bin = (name, script) => fs.writeFileSync(path.join(dir, 'bin', name), `#!/usr/bin/env bash\n${script}\n`, {mode: 0o755});
  bin('curl', options.claudeError ? 'exit 22' : `cat >/dev/null\nprintf '%s\\n' '${JSON.stringify({five_hour: {utilization: claudeUsed}})}'`);
  const snapshot = {id: 2, result: {rateLimits: {primary: {usedPercent: codexUsed, windowDurationMins: options.duration ?? 300}, secondary: {usedPercent: 99, windowDurationMins: 10080}}}};
  bin('codex', `if [ "$1" = app-server ]; then
  read -r init
  read -r initialized
  read -r request
  printf '%s\\n' '${JSON.stringify(snapshot)}'
  cat >/dev/null
else
  echo codex >> "$CALL_LOG"
  printf '%s\\n' '${JSON.stringify(options.codexEvent ?? {type: 'turn.completed', usage: {}})}'
fi`);
  bin('claude', `if [ "$1" = --version ]; then echo '2.1.0'; else
  echo claude >> "$CALL_LOG"
  printf '%s\\n' '${JSON.stringify(options.claudeEvent ?? {type: 'result', is_error: false, result: 'done'})}'
fi`);
  const env = {...process.env, PATH: `${dir}/bin:${process.env.PATH}`, CLAUDE_CODE_OAUTH_TOKEN: 'fixture-token', CALL_LOG: `${dir}/calls`};
  const run = (script, args = []) => spawnSync('bash', [path.join(dir, script), ...args], {env, encoding: 'utf8', timeout: 5000});
  return {dir, run, clean: () => fs.rmSync(dir, {recursive: true, force: true})};
}

for (const [preferred, claudeUsed, codexUsed, expected] of [
  ['claude', 20, 99, 'claude'], ['claude', 90.5, 20, 'codex'],
  ['codex', 20, 91, 'claude'], ['codex', 99, 90, 'codex'],
  ['claude', 90, 99, 'claude'],
]) {
  test(`${preferred}: Claude used=${claudeUsed}%, Codex used=${codexUsed}% selects ${expected}`, () => {
    const f = fixture(preferred, claudeUsed, codexUsed);
    try {
      const result = f.run('scripts/select-agent.sh');
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout.trim(), expected);
      assert.equal(fs.readFileSync(`${f.dir}/agent.yaml`, 'utf8').split('\n')[0], `agent: ${preferred}`);
      const agent = f.run('run-agent.sh', [`${f.dir}/prompt.md`, '1', `${f.dir}/stream.jsonl`]);
      assert.equal(agent.status, 0, agent.stderr);
      assert.equal(fs.readFileSync(`${f.dir}/calls`, 'utf8').trim(), expected);
    } finally { f.clean(); }
  });
}
test('both below 10% fail queue gate and runner without invoking either CLI', () => {
  const f = fixture('claude', 91, 90.1);
  try {
    const gate = f.run('scripts/codex-usage-available.sh');
    assert.equal(gate.status, 1);
    assert.match(gate.stderr, /STOP: Claude and Codex both have less than 10%/);
    const agent = f.run('run-agent.sh', [`${f.dir}/prompt.md`, '1', `${f.dir}/stream.jsonl`]);
    assert.equal(agent.status, 75);
    assert.match(JSON.parse(fs.readFileSync(`${f.dir}/stream.jsonl`, 'utf8')).message, /both have less/);
    assert.equal(fs.existsSync(`${f.dir}/calls`), false);
  } finally { f.clean(); }
});
test('unknown Claude quota uses verified Codex; unknown plus exhausted stops', () => {
  for (const codexUsed of [20, 99]) {
    const f = fixture('claude', 20, codexUsed, {claudeError: true});
    try {
      const result = f.run('scripts/select-agent.sh');
      assert.equal(result.status, codexUsed === 20 ? 0 : 1, result.stderr);
      if (codexUsed === 20) assert.equal(result.stdout.trim(), 'codex');
      else assert.match(result.stderr, /could not verify/);
    } finally { f.clean(); }
  }
});
test('missing five-hour window is unknown and does not silently use weekly quota', () => {
  const f = fixture('codex', 99, 20, {duration: 60});
  try {
    const result = f.run('scripts/select-agent.sh');
    assert.equal(result.status, 1);
    assert.match(result.stderr, /no valid five-hour/);
  } finally { f.clean(); }
});
test('opencode bypasses rotation and invalid thresholds fail', () => {
  const f = fixture('opencode', 99, 99);
  try {
    assert.equal(f.run('scripts/select-agent.sh').stdout.trim(), 'opencode');
    for (const value of ['-1', '101', 'bad']) assert.equal(f.run('scripts/select-agent.sh', [value]).status, 2);
  } finally { f.clean(); }
});

for (const preferred of ['claude', 'codex']) {
  test(`quota exhausted during ${preferred} phase rotates once`, () => {
    const error = {type: 'error', message: 'You have hit your usage limit'};
    const f = fixture(preferred, 20, 20, {[`${preferred}Event`]: error});
    try {
      const result = f.run('run-agent.sh', [`${f.dir}/prompt.md`, '1', `${f.dir}/stream.jsonl`]);
      assert.equal(result.status, 0, result.stderr);
      const other = preferred === 'claude' ? 'codex' : 'claude';
      assert.equal(fs.readFileSync(`${f.dir}/calls`, 'utf8'), `${preferred}\n${other}\n`);
      assert.equal(fs.existsSync(`${f.dir}/stream.${preferred}.jsonl`), true);
    } finally { f.clean(); }
  });
}
test('both exhaust during phase: stop after two calls and retain explicit error', () => {
  const error = {type: 'error', message: 'usage limit reached'};
  const f = fixture('claude', 20, 20, {claudeEvent: error, codexEvent: error});
  try {
    const result = f.run('run-agent.sh', [`${f.dir}/prompt.md`, '1', `${f.dir}/stream.jsonl`]);
    assert.equal(result.status, 75, result.stderr);
    assert.equal(fs.readFileSync(`${f.dir}/calls`, 'utf8'), 'claude\ncodex\n');
    assert.match(result.stderr, /both exhausted during this phase/);
  } finally { f.clean(); }
});
test('normal successful text and unrelated errors never rerun a phase', () => {
  for (const claudeEvent of [{type: 'result', is_error: false, result: 'usage limit explained'},
    {type: 'error', message: 'authentication failed'}]) {
    const f = fixture('claude', 20, 20, {claudeEvent});
    try {
      f.run('run-agent.sh', [`${f.dir}/prompt.md`, '1', `${f.dir}/stream.jsonl`]);
      assert.equal(fs.readFileSync(`${f.dir}/calls`, 'utf8'), 'claude\n');
    } finally { f.clean(); }
  }
});
test('quota stop overrides an old successful phase result and prevents its result check', () => {
  const f = fixture('claude', 99, 99);
  try {
    const impl = path.join(f.dir, 'scripts/implement');
    fs.mkdirSync(impl);
    fs.copyFileSync('scripts/implement/run-phase.sh', path.join(impl, 'run-phase.sh'));
    fs.writeFileSync(path.join(impl, 'build-prompt.sh'), '#!/bin/sh\nexit 0\n', {mode: 0o755});
    fs.writeFileSync(path.join(impl, 'check-phase-result.sh'), '#!/bin/sh\necho checked > "$CALL_LOG"\n', {mode: 0o755});
    const phase = path.join(f.dir, 'run/code');
    fs.mkdirSync(phase, {recursive: true});
    fs.writeFileSync(path.join(phase, 'prompt.md'), 'test');
    fs.writeFileSync(path.join(phase, 'result.json'), '{"status":"done"}');
    const result = f.run('scripts/implement/run-phase.sh', ['code', `${f.dir}/run`, 'o/r', f.dir, 'skill', 'standard', '1']);
    assert.equal(result.status, 75, result.stderr);
    const verdict = JSON.parse(fs.readFileSync(`${phase}/result.json`, 'utf8'));
    assert.equal(verdict.status, 'failed');
    assert.match(verdict.error, /both have less/);
    assert.equal(fs.existsSync(`${f.dir}/calls`), false);
  } finally { f.clean(); }
});
