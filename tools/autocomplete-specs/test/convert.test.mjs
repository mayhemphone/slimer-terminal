import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';

import { SIZE_LIMIT, cleanIcon, cleanText, convert, toNames } from '../convert.mjs';
import { validateDir } from '../validate.mjs';

const fixtures = fileURLToPath(new URL('./fixtures/', import.meta.url));

let out;
let result;
const readSpec = async (key) => JSON.parse(await fs.readFile(path.join(out, 'specs', `${key}.json`), 'utf8'));
const exists = (p) => fs.access(p).then(() => true, () => false);
const find = (list, name) => list.find((item) => item.name.includes(name));

before(async () => {
  out = await fs.mkdtemp(path.join(os.tmpdir(), 'slimer-autocomplete-test-'));
  // A stale file from a previous run must be removed by the converter.
  await fs.mkdir(path.join(out, 'specs', 'stale'), { recursive: true });
  await fs.writeFile(path.join(out, 'specs', 'stale', 'old.json'), '{"name":["old"]}');
  await fs.writeFile(path.join(out, 'specs', 'old.json'), '{"name":["old"]}');
  result = await convert({ src: fixtures, out, sourceCommit: 'deadbeef', quiet: true });
});

after(async () => {
  if (out) await fs.rm(out, { recursive: true, force: true });
});

describe('index.json', () => {
  it('records the source commit, a count and sorted bookkeeping', async () => {
    const index = JSON.parse(await fs.readFile(path.join(out, 'specs', 'index.json'), 'utf8'));
    assert.deepEqual(index, result.index);
    assert.equal(index.sourceCommit, 'deadbeef');
    assert.match(index.generatedAt, /^\d{4}-\d{2}-\d{2}T/u);
    assert.equal(index.count, 6);
    assert.deepEqual(
      [...result.specs.keys()].sort(),
      ['docker/compose', 'git', 'node', 'nvim', 'vi', 'yarn'],
    );
    assert.deepEqual(
      index.skipped.map((s) => s.name),
      ['aws', 'deno', 'g++', 'huge', 'index'],
    );
  });

  it('maps aliases to primaries without shadowing another primary', () => {
    assert.deepEqual(result.index.aliases, { vim: 'nvim' });
    // `docker-compose` is an alternate name of a nested spec: not an alias.
    assert.equal('docker-compose' in result.index.aliases, false);
  });

  it('removes stale output from earlier runs', async () => {
    assert.equal(await exists(path.join(out, 'specs', 'old.json')), false);
    assert.equal(await exists(path.join(out, 'specs', 'stale')), false);
  });
});

describe('skipping and failures', () => {
  it('skips the skip list, invalid names and the reserved index name without writing files', async () => {
    const reasons = Object.fromEntries(result.index.skipped.map((s) => [s.name, s.reason]));
    assert.match(reasons.aws, /skip list/u);
    assert.match(reasons['g++'], /invalid name/u);
    assert.match(reasons.index, /reserved/u);
    for (const name of ['aws', 'g++', 'huge', 'deno']) {
      assert.equal(await exists(path.join(out, 'specs', `${name}.json`)), false, `${name}.json must not exist`);
    }
  });

  it('skips specs whose minified JSON exceeds the size cap', () => {
    const huge = result.index.skipped.find((s) => s.name === 'huge');
    assert.match(huge.reason, new RegExp(`exceeds ${SIZE_LIMIT} bytes \\((\\d+) bytes\\)`, 'u'));
    const bytes = Number(/\((\d+) bytes\)/u.exec(huge.reason)[1]);
    assert.ok(bytes > SIZE_LIMIT);
  });

  it('records createVersionedSpec-style exports as skipped, not failed', () => {
    const deno = result.index.skipped.find((s) => s.name === 'deno');
    assert.match(deno.reason, /versioned spec/u);
    assert.equal(result.index.failed.some((f) => f.file === 'deno.js'), false);
  });

  it('records modules that fail to load and keeps going', () => {
    assert.equal(result.index.failed.length, 1);
    assert.equal(result.index.failed[0].file, 'broken.js');
    assert.ok(result.index.failed[0].error.length > 0);
  });
});

describe('export shapes', () => {
  it('calls a function export with a dummy shell-command stub and context', async () => {
    const node = await readSpec('node');
    assert.deepEqual(node.name, ['node']);
    assert.equal(node.description, 'Node.js (unknown) in /');
    assert.equal(node.options.length, 3);
  });

  it('unwraps a versionedSpec-style { completionSpec, versions } object', async () => {
    const yarn = await readSpec('yarn');
    assert.deepEqual(yarn.name, ['yarn']);
    assert.equal(yarn.subcommands.length, 2);
    assert.equal('versions' in yarn, false);
    const run = find(yarn.subcommands, 'run');
    assert.deepEqual(run.args[0].generators[0], {
      script: ['cat', 'package.json'],
      hasPostProcess: true,
      hasCustom: false,
      cache: { cacheByDirectory: true },
    });
  });

  it('emits nested specs under their directory key', async () => {
    const compose = await readSpec('docker/compose');
    assert.deepEqual(compose.name, ['compose', 'docker-compose']);
    assert.equal(find(compose.subcommands, 'down').isDangerous, true);
  });
});

describe('normalization (git fixture, bundled from TypeScript)', () => {
  let git;
  before(async () => {
    git = await readSpec('git');
  });

  it('normalizes names to trimmed arrays and drops unsafe or empty names', () => {
    assert.deepEqual(git.name, ['git']);
    assert.ok(find(git.subcommands, 'tag'), 'whitespace around a name is trimmed');
    assert.equal(git.subcommands.some((s) => s.name.some((n) => /[\u0007‮]/u.test(n))), false);
    assert.equal(git.options.some((o) => o.name.includes('')), false);
    const stash = find(git.subcommands, 'stash');
    assert.deepEqual(stash.subcommands.map((s) => s.name), [['pop'], ['list']]);
  });

  it('trims, collapses and caps descriptions at 200 code points', () => {
    assert.equal(git.description, 'The stupid content tracker');
    const version = find(git.options, '--version');
    assert.equal(Array.from(version.description).length, 200);
  });

  it('keeps only true booleans and numeric priorities', () => {
    const stash = find(git.subcommands, 'stash');
    assert.equal('requiresSubcommand' in stash, false, 'false is omitted');
    assert.equal(find(git.subcommands, 'bisect').requiresSubcommand, true);
    assert.equal(find(stash.subcommands, 'list').hidden, undefined);
    const secret = find(git.options, '--secret');
    assert.equal(secret.hidden, true);
    assert.equal(secret.priority, 10);
    assert.equal(find(git.subcommands, 'push').isDangerous, true);
  });

  it('keeps string loadSpec, merges inline loadSpec objects, drops function loadSpec and generateSpec', () => {
    assert.equal(find(git.subcommands, 'lfs').loadSpec, 'git-lfs');
    const flow = find(git.subcommands, 'flow');
    assert.equal('loadSpec' in flow, false);
    const worktree = find(git.subcommands, 'worktree');
    assert.equal(worktree.description, 'Manage multiple working trees');
    assert.deepEqual(worktree.subcommands.map((s) => s.name), [['add'], ['list']]);
    assert.deepEqual(find(worktree.subcommands, 'add').args[0].template, ['folders']);
    // stash already had subcommands, so the inline spec does not override them.
    assert.equal(find(find(git.subcommands, 'stash').subcommands, 'push'), undefined);
    assert.equal('generateSpec' in git, false);
  });

  it('normalizes option args, templates, separators and repeat counts', () => {
    const c = find(git.options, '-C');
    assert.deepEqual(c.args, [{ name: 'path', template: ['folders'] }]);
    const gitDir = find(git.options, '--git-dir');
    assert.equal(gitDir.requiresSeparator, true, 'requiresEquals maps to requiresSeparator');
    assert.deepEqual(gitDir.args[0].template, ['folders'], 'unknown templates are dropped');
    assert.equal(find(git.options, '--exec-path').requiresSeparator, '=');
    assert.equal(find(git.options, '-c').isRepeatable, true);
    assert.equal(find(git.options, '--paginate').isRepeatable, 3);
    assert.deepEqual(find(git.options, '--paginate').exclusiveOn, ['--no-pager']);
    assert.equal(find(git.options, '--help').isPersistent, true);
    const checkout = find(git.subcommands, 'checkout');
    assert.deepEqual(find(checkout.options, '--track').dependsOn, ['-b']);
    const push = find(git.subcommands, 'push');
    assert.deepEqual(find(push.options, '--receive-pack').args, [{ name: 'git-receive-pack' }]);
  });

  it('normalizes suggestions given as strings and objects, filtering icons', () => {
    const checkout = find(git.subcommands, 'checkout');
    assert.deepEqual(checkout.name, ['checkout', 'co']);
    assert.deepEqual(checkout.args[0].suggestions, [
      { name: ['-'] },
      { name: ['HEAD'], description: 'Current commit', icon: '🔖', priority: 100 },
      { name: ['FETCH_HEAD'] },
      { name: ['ORIG_HEAD', 'orig'], isDangerous: true, hidden: true },
    ]);
    assert.deepEqual(find(git.subcommands, 'bisect').args[0].suggestions.map((s) => s.name[0]), ['start', 'good', 'bad']);
  });

  it('serializes generators as data: argv scripts, legacy string scripts, dropped function scripts', () => {
    const checkout = find(git.subcommands, 'checkout');
    assert.deepEqual(checkout.args[0].generators, [
      {
        script: ['git', 'branch', '--no-color', '--sort=-committerdate'],
        trigger: { on: 'change' },
        hasPostProcess: true,
        hasCustom: false,
        cache: { ttl: 2000, cacheByDirectory: true },
      },
    ]);
    const push = find(git.subcommands, 'push');
    assert.deepEqual(push.args[0].generators, [
      { script: ['bash', '-c', "git remote -v | awk '{print $1}' | sort -u"], splitOn: '\n', hasPostProcess: false, hasCustom: false },
    ]);
    const add = find(git.subcommands, 'add');
    assert.deepEqual(add.args[0].generators, [
      { script: null, trigger: { on: 'match', string: '/' }, hasPostProcess: true, hasCustom: false },
    ]);
    const tag = find(git.subcommands, 'tag');
    assert.deepEqual(tag.args[0].generators, [
      { trigger: '/', hasPostProcess: false, hasCustom: true, cache: { strategy: 'stale-while-revalidate', ttl: 500 } },
    ]);
  });

  it('keeps arg flags and normalizes single args to arrays', () => {
    const add = find(git.subcommands, 'add');
    assert.equal(add.args[0].isVariadic, true);
    assert.deepEqual(add.args[0].template, ['filepaths']);
    const submodule = find(git.subcommands, 'submodule');
    assert.deepEqual(find(submodule.subcommands, 'foreach').args, [{ name: 'command', isCommand: true, isDangerous: true }]);
    assert.deepEqual(find(submodule.subcommands, 'run-script').args, [{ name: 'script', isScript: true }]);
    assert.deepEqual(find(submodule.subcommands, 'nothing').args, [{}]);
    const push = find(git.subcommands, 'push');
    assert.equal(push.args.length, 2);
    assert.equal(push.args[1].isOptional, true);
  });

  it('contains no functions anywhere', () => {
    const walk = (v) => {
      assert.notEqual(typeof v, 'function');
      if (v && typeof v === 'object') Object.values(v).forEach(walk);
    };
    walk(git);
    assert.ok(result.stats.droppedFunctions >= 5);
  });
});

describe('helpers', () => {
  it('cleanText replaces unsafe characters, collapses whitespace and caps length', () => {
    assert.equal(cleanText('  a\u0007b\n\n c  ', 200), 'a b c');
    assert.equal(cleanText('x'.repeat(10), 4), 'xxxx');
    assert.equal(cleanText('', 10), undefined);
    assert.equal(cleanText(42, 10), undefined);
  });

  it('toNames rejects unsafe names instead of stripping them', () => {
    assert.deepEqual(toNames([' a ', 'a', 'b‮', '', 7, 'c']), ['a', 'c']);
    assert.deepEqual(toNames('solo'), ['solo']);
  });

  it('cleanIcon keeps short emoji and fig:// URIs only', () => {
    assert.equal(cleanIcon('🔖'), '🔖');
    assert.equal(cleanIcon('👩‍💻'), '👩‍💻');
    assert.equal(cleanIcon('fig://icon?type=git'), 'fig://icon?type=git');
    assert.equal(cleanIcon('https://example.invalid/x.png'), undefined);
    assert.equal(cleanIcon('abc'), undefined);
    assert.equal(cleanIcon('🔖🔖🔖🔖🔖🔖🔖🔖🔖'), undefined);
  });
});

describe('validator', () => {
  it('accepts the converter output', async () => {
    const report = await validateDir(out);
    assert.deepEqual(report.errors, []);
    assert.equal(report.ok, true);
    assert.equal(report.checked, 7);
  });

  it('rejects a spec with unknown properties, a bad filename and an inconsistent index', async () => {
    const bad = await fs.mkdtemp(path.join(os.tmpdir(), 'slimer-autocomplete-bad-'));
    try {
      await fs.cp(path.join(out, 'specs'), path.join(bad, 'specs'), { recursive: true });
      await fs.writeFile(path.join(bad, 'specs', 'vi.json'), JSON.stringify({ name: ['vi'], postProcess: 'nope' }));
      await fs.writeFile(path.join(bad, 'specs', 'Bad Name.json'), JSON.stringify({ name: ['bad'] }));
      await fs.writeFile(path.join(bad, 'specs', 'ctl.json'), JSON.stringify({ name: ['a\u0007b'] }));
      const report = await validateDir(bad);
      assert.equal(report.ok, false);
      assert.ok(report.errors.some((e) => e.startsWith('vi.json:') && e.includes('postProcess')), report.errors.join('\n'));
      assert.ok(report.errors.some((e) => e.startsWith('Bad Name.json: filename')), report.errors.join('\n'));
      assert.ok(report.errors.some((e) => e.startsWith('ctl.json:') && e.includes('pattern')), report.errors.join('\n'));
      assert.ok(report.errors.some((e) => e.includes('count 6 but 8')), report.errors.join('\n'));
    } finally {
      await fs.rm(bad, { recursive: true, force: true });
    }
  });
});
