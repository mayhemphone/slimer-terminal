#!/usr/bin/env node
// Converts Fig completion specs (withfig/autocomplete) into Slimer's data-only
// JSON format. See README.md for the format, the security rationale, and the
// regeneration procedure.
//
// This file is both the CLI (`node convert.mjs --src ... --out ...`) and a
// library (`import { convert } from './convert.mjs'`) used by the tests.

import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// ---------------------------------------------------------------------------
// Constants shared with validate.mjs
// ---------------------------------------------------------------------------

/** Minified specs larger than this are not emitted. */
export const SIZE_LIMIT = 512 * 1024;
/** Primary commands (and their nested directories) that are never emitted. */
export const SKIP_NAMES = new Set(['aws', 'az', 'gcloud']);
/** File keys that collide with the converter's own output. */
export const RESERVED_NAMES = new Set(['index']);
/** Descriptions are cut to this many code points. */
export const DESCRIPTION_MAX = 200;
/** Arg names are display labels ("file", "branch name"); keep them short. */
export const ARG_NAME_MAX = 80;
/** Allowed characters for one output filename segment (without `.json`). */
export const NAME_RE = /^[a-z0-9._-]+$/;
/** Fig templates the engine understands; anything else is dropped. */
export const KNOWN_TEMPLATES = new Set(['filepaths', 'folders', 'history', 'help']);

const SPEC_EXTENSIONS = new Set(['.js', '.mjs', '.ts']);
const FUNCTION_CALL_TIMEOUT_MS = 5000;
const MAX_DEPTH = 48;

// Characters that must never reach the terminal as candidate text (see
// docs/slimer/CONVENTIONS.md): C0/C1 controls, DEL, line/paragraph separators,
// bidi overrides and isolates.
const UNSAFE_CHARS = '\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029\\u202a-\\u202e\\u2066-\\u2069';
const UNSAFE_RE = new RegExp(`[${UNSAFE_CHARS}]`, 'u');
const UNSAFE_RE_G = new RegExp(`[${UNSAFE_CHARS}]`, 'gu');
const NUL_RE = /\u0000/u;
const EMOJI_RE =
  /^(?:\p{Extended_Pictographic}|\p{Emoji_Modifier}|\p{Regional_Indicator}|‍|️|[0-9#*]️?⃣)+$/u;
const EMOJI_MAX_CODEPOINTS = 8;
const ICON_URL_MAX = 120;
const SAFE_KEY_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

// ---------------------------------------------------------------------------
// Small normalization helpers
// ---------------------------------------------------------------------------

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const toList = (v) => (v === undefined || v === null ? [] : Array.isArray(v) ? v : [v]);
const bool = (v) => (v === true ? true : undefined);
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);

/** Remove `undefined` values so the JSON stays compact. */
function compact(obj) {
  for (const key of Object.keys(obj)) {
    if (obj[key] === undefined) delete obj[key];
  }
  return obj;
}

/**
 * Free text (descriptions, arg labels): unsafe characters become spaces,
 * whitespace runs collapse, the result is trimmed and capped at `max` code
 * points. Returns `undefined` for anything that is not a non-empty string.
 */
export function cleanText(value, max) {
  if (typeof value !== 'string') return undefined;
  const s = value.replace(UNSAFE_RE_G, ' ').replace(/\s+/gu, ' ').trim();
  if (!s) return undefined;
  const cps = Array.from(s);
  return cps.length > max ? cps.slice(0, max).join('').trimEnd() : s;
}

/**
 * Candidate text (names, templates, keys): trimmed, and rejected outright
 * (not stripped) when it contains an unsafe character.
 */
export function cleanName(value) {
  if (typeof value !== 'string') return undefined;
  const s = value.trim();
  if (!s || UNSAFE_RE.test(s)) return undefined;
  return s;
}

/** Normalize `name: string | string[]` into a de-duplicated string array. */
export function toNames(value) {
  const out = [];
  for (const v of toList(value)) {
    const n = cleanName(v);
    if (n !== undefined && !out.includes(n)) out.push(n);
  }
  return out;
}

/** `string | string[]` of names, or `undefined` when nothing survives. */
function nameList(value) {
  const names = toNames(value);
  return names.length > 0 ? names : undefined;
}

/** Normalize `template: Fig.Template | Fig.Template[]` to known values only. */
function toTemplates(value) {
  const out = [];
  for (const v of toList(value)) {
    const t = cleanName(v);
    if (t !== undefined && KNOWN_TEMPLATES.has(t) && !out.includes(t)) out.push(t);
  }
  return out.length > 0 ? out : undefined;
}

/** Keep an icon only when it is a short emoji or a `fig://` URI. */
export function cleanIcon(value) {
  if (typeof value !== 'string') return undefined;
  const s = value.trim();
  if (!s || UNSAFE_RE.test(s)) return undefined;
  if (s.startsWith('fig://')) return s.length <= ICON_URL_MAX ? s : undefined;
  if (Array.from(s).length <= EMOJI_MAX_CODEPOINTS && EMOJI_RE.test(s)) return s;
  return undefined;
}

/**
 * Deep copy that keeps only JSON primitives, plain arrays and plain objects
 * with identifier-like keys. Functions and exotic values are dropped.
 */
function dataOnly(value, ctx, depth = 0) {
  if (typeof value === 'string') return cleanText(value, DESCRIPTION_MAX);
  if (typeof value === 'number') return num(value);
  if (typeof value === 'boolean') return value;
  if (typeof value === 'function') {
    ctx.stats.droppedFunctions += 1;
    return undefined;
  }
  if (depth >= 4) return undefined;
  if (Array.isArray(value)) {
    const out = value.map((v) => dataOnly(v, ctx, depth + 1)).filter((v) => v !== undefined);
    return out.length > 0 ? out : undefined;
  }
  if (isObject(value)) {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (!SAFE_KEY_RE.test(k)) continue;
      const d = dataOnly(v, ctx, depth + 1);
      if (d !== undefined) out[k] = d;
    }
    return Object.keys(out).length > 0 ? out : undefined;
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Serializers: Fig object graph -> data-only JSON
// ---------------------------------------------------------------------------

/**
 * Serialize a list of Fig nodes with `fn`, guarding against reference cycles
 * (shared references are fine; a node on the current path is not re-entered)
 * and unbounded depth.
 */
function serializeList(value, fn, ctx) {
  const items = toList(value);
  if (items.length === 0) return undefined;
  if (ctx.depth >= MAX_DEPTH) {
    ctx.stats.droppedDepth += 1;
    return undefined;
  }
  const out = [];
  ctx.depth += 1;
  try {
    for (const item of items) {
      if (isObject(item)) {
        if (ctx.seen.has(item)) {
          ctx.stats.droppedCycles += 1;
          continue;
        }
        ctx.seen.add(item);
        try {
          const s = fn(item, ctx);
          if (s !== undefined) out.push(s);
        } finally {
          ctx.seen.delete(item);
        }
      } else {
        const s = fn(item, ctx);
        if (s !== undefined) out.push(s);
      }
    }
  } finally {
    ctx.depth -= 1;
  }
  return out.length > 0 ? out : undefined;
}

function noteFunction(value, ctx) {
  if (typeof value === 'function') ctx.stats.droppedFunctions += 1;
}

export function serializeSuggestion(sug, ctx) {
  if (typeof sug === 'string') {
    const name = nameList(sug);
    return name ? { name } : undefined;
  }
  if (!isObject(sug)) return undefined;
  const name = nameList(sug.name);
  if (!name) return undefined;
  return compact({
    name,
    description: cleanText(sug.description, DESCRIPTION_MAX),
    icon: cleanIcon(sug.icon),
    priority: num(sug.priority),
    isDangerous: bool(sug.isDangerous),
    hidden: bool(sug.hidden),
  });
}

export function serializeGenerator(gen, ctx) {
  if (!isObject(gen)) return undefined;
  const out = {};

  if (typeof gen.script === 'string') {
    // Legacy Fig form: a shell command line, which Fig ran through `bash -c`.
    // Represent it as that argv so the engine treats every script uniformly.
    const s = gen.script.trim();
    if (s && !NUL_RE.test(s)) out.script = ['bash', '-c', s];
  } else if (Array.isArray(gen.script)) {
    const argv = gen.script.filter((a) => typeof a === 'string' && !NUL_RE.test(a));
    if (argv.length > 0) out.script = argv;
  } else if (typeof gen.script === 'function') {
    ctx.stats.droppedFunctions += 1;
    out.script = null;
  }

  if (typeof gen.splitOn === 'string' && gen.splitOn.length > 0 && !NUL_RE.test(gen.splitOn)) {
    out.splitOn = gen.splitOn;
  }
  out.template = toTemplates(gen.template);

  if (typeof gen.trigger === 'string') out.trigger = cleanName(gen.trigger);
  else if (isObject(gen.trigger)) out.trigger = dataOnly(gen.trigger, ctx);
  else noteFunction(gen.trigger, ctx);

  out.hasPostProcess = typeof gen.postProcess === 'function';
  out.hasCustom = typeof gen.custom === 'function';
  if (isObject(gen.cache)) out.cache = dataOnly(gen.cache, ctx);

  noteFunction(gen.getQueryTerm, ctx);
  noteFunction(gen.filterTemplateSuggestions, ctx);
  return compact(out);
}

export function serializeArg(arg, ctx) {
  if (!isObject(arg)) return undefined;
  const out = {
    name: cleanText(arg.name, ARG_NAME_MAX),
    description: cleanText(arg.description, DESCRIPTION_MAX),
    isOptional: bool(arg.isOptional),
    isVariadic: bool(arg.isVariadic),
    isCommand: bool(arg.isCommand),
    isScript: bool(arg.isScript),
    isDangerous: bool(arg.isDangerous),
    template: toTemplates(arg.template),
    suggestions: serializeList(arg.suggestions, serializeSuggestion, ctx),
    generators: serializeList(arg.generators, serializeGenerator, ctx),
  };
  noteFunction(arg.loadSpec, ctx);
  return compact(out);
}

export function serializeOption(opt, ctx) {
  if (!isObject(opt)) return undefined;
  const name = nameList(opt.name);
  if (!name) {
    ctx.stats.droppedUnnamed += 1;
    return undefined;
  }

  let isRepeatable;
  if (opt.isRepeatable === true) isRepeatable = true;
  else if (Number.isInteger(opt.isRepeatable) && opt.isRepeatable > 0) isRepeatable = opt.isRepeatable;

  let requiresSeparator;
  if (opt.requiresSeparator === true) requiresSeparator = true;
  else if (typeof opt.requiresSeparator === 'string') requiresSeparator = cleanName(opt.requiresSeparator);
  if (requiresSeparator === undefined && opt.requiresEquals === true) requiresSeparator = true;

  return compact({
    name,
    description: cleanText(opt.description, DESCRIPTION_MAX),
    args: serializeList(opt.args, serializeArg, ctx),
    isRequired: bool(opt.isRequired),
    isRepeatable,
    isPersistent: bool(opt.isPersistent),
    isDangerous: bool(opt.isDangerous),
    exclusiveOn: nameList(opt.exclusiveOn),
    dependsOn: nameList(opt.dependsOn),
    requiresSeparator,
    hidden: bool(opt.hidden),
    priority: num(opt.priority),
  });
}

export function serializeSubcommand(sub, ctx) {
  if (!isObject(sub)) return undefined;
  const name = nameList(sub.name);
  if (!name) {
    ctx.stats.droppedUnnamed += 1;
    return undefined;
  }

  const out = {
    name,
    description: cleanText(sub.description, DESCRIPTION_MAX),
    hidden: bool(sub.hidden),
    isDangerous: bool(sub.isDangerous),
    requiresSubcommand: bool(sub.requiresSubcommand),
    priority: num(sub.priority),
    loadSpec: undefined,
    subcommands: serializeList(sub.subcommands, serializeSubcommand, ctx),
    options: serializeList(sub.options, serializeOption, ctx),
    args: serializeList(sub.args, serializeArg, ctx),
  };

  if (typeof sub.loadSpec === 'string') {
    out.loadSpec = cleanName(sub.loadSpec);
  } else if (isObject(sub.loadSpec)) {
    // An inline spec replaces this node's children when Fig loads it. Merge
    // whatever this node does not already define.
    const inline = serializeList([sub.loadSpec], serializeSubcommand, ctx)?.[0];
    if (inline) {
      out.subcommands ??= inline.subcommands;
      out.options ??= inline.options;
      out.args ??= inline.args;
      out.description ??= inline.description;
    }
  } else {
    noteFunction(sub.loadSpec, ctx);
  }
  noteFunction(sub.generateSpec, ctx);
  return compact(out);
}

export function newContext() {
  return {
    depth: 0,
    seen: new Set(),
    stats: { droppedFunctions: 0, droppedUnnamed: 0, droppedCycles: 0, droppedDepth: 0 },
  };
}

/** Serialize a resolved Fig.Spec object. Returns `undefined` when unnamed. */
export function serializeSpec(spec, ctx = newContext()) {
  return serializeList([spec], serializeSubcommand, ctx)?.[0];
}

// ---------------------------------------------------------------------------
// Module loading and export resolution
// ---------------------------------------------------------------------------

class VersionedSpecError extends Error {}

let esbuildPromise;
function getEsbuild() {
  esbuildPromise ??= import('esbuild').catch((err) => {
    throw new Error(`esbuild is required to load this file (run \`npm install\` in tools/autocomplete-specs): ${err.message}`);
  });
  return esbuildPromise;
}

async function bundleAndImport(file, run) {
  const esbuild = await getEsbuild();
  run.seq += 1;
  const outfile = path.join(run.tmpDir, `${run.seq}-${path.basename(file).replace(/[^A-Za-z0-9._-]/gu, '_')}.mjs`);
  await esbuild.build({
    entryPoints: [file],
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node20',
    outfile,
    logLevel: 'silent',
    sourcemap: false,
    legalComments: 'none',
  });
  return import(pathToFileURL(outfile).href);
}

async function loadModule(file, run) {
  if (path.extname(file) === '.ts') return bundleAndImport(file, run);
  try {
    return await import(pathToFileURL(file).href);
  } catch (err) {
    // CommonJS output or relative imports that need bundling: retry via esbuild.
    try {
      return await bundleAndImport(file, run);
    } catch (err2) {
      throw new Error(`${errorMessage(err)} (esbuild fallback: ${errorMessage(err2)})`);
    }
  }
}

function errorMessage(err) {
  // esbuild aggregates: surface its first message with a location.
  const first = Array.isArray(err?.errors) ? err.errors[0] : undefined;
  if (first?.text) {
    const loc = first.location ? ` (${path.basename(first.location.file)}:${first.location.line})` : '';
    return `${first.text}${loc}`.slice(0, 500);
  }
  return (err instanceof Error ? err.message : String(err)).split('\n')[0].slice(0, 500);
}

const dummyExecuteShellCommand = async () => ({ stdout: '', stderr: '', status: 1 });
const dummyContext = Object.freeze({
  currentWorkingDirectory: '/',
  currentProcess: '',
  sshPrefix: '',
  environmentVariables: {},
  isDangerous: false,
});

function withTimeout(promise, ms, what) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} did not settle within ${ms} ms`)), ms);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

const looksLikeSpec = (v) => isObject(v) && (typeof v.name === 'string' || Array.isArray(v.name));

/**
 * Find the Fig.Spec inside a module namespace or export value. Accepts a spec
 * object, a function returning one (called with a dummy shell-command stub and
 * context), and wrappers keyed `default` / `completionSpec` / `versionedSpec` /
 * `spec`. Throws VersionedSpecError for `createVersionedSpec`-style exports.
 */
async function resolveSpec(value, depth = 0) {
  if (depth > 8) return undefined;
  if (typeof value === 'function') {
    let result;
    try {
      result = await withTimeout(
        Promise.resolve().then(() => value(dummyExecuteShellCommand, dummyContext)),
        FUNCTION_CALL_TIMEOUT_MS,
        'spec function',
      );
    } catch (err) {
      if (Function.prototype.toString.call(value).includes('versionedSpecPath')) {
        throw new VersionedSpecError('versioned spec: needs runtime version detection');
      }
      throw err;
    }
    return resolveSpec(result, depth + 1);
  }
  if (value === null || typeof value !== 'object') return undefined;
  if (looksLikeSpec(value)) return value;
  if ('versionedSpecPath' in value) {
    throw new VersionedSpecError('versioned spec: needs runtime version detection');
  }
  for (const key of ['default', 'completionSpec', 'versionedSpec', 'spec']) {
    if (key in value) {
      const found = await resolveSpec(value[key], depth + 1);
      if (found !== undefined) return found;
    }
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// File discovery and output
// ---------------------------------------------------------------------------

async function discover(srcDir) {
  const found = [];
  async function walk(dir, rel) {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name.startsWith('.') || entry.name === 'node_modules') continue;
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(abs, rel ? `${rel}/${entry.name}` : entry.name);
        continue;
      }
      if (!entry.isFile()) continue;
      const ext = path.extname(entry.name);
      if (!SPEC_EXTENSIONS.has(ext) || entry.name.endsWith('.d.ts')) continue;
      const stem = entry.name.slice(0, -ext.length);
      if (/\.(test|spec)$/u.test(stem)) continue;
      const rawKey = rel ? `${rel}/${stem}` : stem;
      found.push({ file: abs, rawKey, key: rawKey.toLowerCase() });
    }
  }
  await walk(srcDir, '');
  found.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : a.file.localeCompare(b.file)));
  return found;
}

/** Why a key cannot be emitted, or `undefined` when it can. */
export function rejectKey(key) {
  const segments = key.split('/');
  if (segments.some((s) => !NAME_RE.test(s))) return 'invalid name: only [a-z0-9._-] allowed';
  if (SKIP_NAMES.has(segments[0])) return 'on the skip list';
  if (RESERVED_NAMES.has(key)) return 'reserved name';
  return undefined;
}

async function removeStaleJson(dir) {
  let entries;
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch (err) {
    if (err.code === 'ENOENT') return;
    throw err;
  }
  for (const entry of entries) {
    const abs = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await removeStaleJson(abs);
      const rest = await fs.readdir(abs);
      if (rest.length === 0) await fs.rmdir(abs);
    } else if (entry.isFile() && entry.name.endsWith('.json')) {
      await fs.unlink(abs);
    }
  }
}

/**
 * Convert every spec under `src` into `<out>/specs/`.
 * @returns {{ index: object, specs: Map<string, object>, stats: object }}
 */
export async function convert({ src, out, sourceCommit = null, quiet = false, log = console.error }) {
  if (!src || !out) throw new Error('convert requires both src and out');
  const srcDir = path.resolve(src);
  const specsDir = path.join(path.resolve(out), 'specs');
  const say = quiet ? () => {} : log;

  const files = await discover(srcDir);
  const run = { tmpDir: await fs.mkdtemp(path.join(os.tmpdir(), 'slimer-autocomplete-')), seq: 0 };
  const specs = new Map();
  const skipped = [];
  const failed = [];
  const stats = { droppedFunctions: 0, droppedUnnamed: 0, droppedCycles: 0, droppedDepth: 0 };

  try {
    await removeStaleJson(specsDir);
    await fs.mkdir(specsDir, { recursive: true });

    for (const { file, rawKey, key } of files) {
      const relFile = path.relative(srcDir, file);
      const reason = rejectKey(key);
      if (reason) {
        skipped.push({ name: rawKey, reason });
        continue;
      }
      if (specs.has(key)) {
        skipped.push({ name: rawKey, reason: `duplicate of ${key}` });
        continue;
      }

      let spec;
      try {
        const mod = await loadModule(file, run);
        spec = await resolveSpec(mod);
      } catch (err) {
        if (err instanceof VersionedSpecError) skipped.push({ name: rawKey, reason: err.message });
        else failed.push({ file: relFile, error: errorMessage(err) });
        continue;
      }
      if (spec === undefined) {
        skipped.push({ name: rawKey, reason: 'not a spec: no default export with a name' });
        continue;
      }

      const ctx = newContext();
      const data = serializeSpec(spec, ctx);
      for (const k of Object.keys(stats)) stats[k] += ctx.stats[k];
      if (!data) {
        skipped.push({ name: rawKey, reason: 'not a spec: empty or unsafe name' });
        continue;
      }

      const json = JSON.stringify(data);
      const bytes = Buffer.byteLength(json);
      if (bytes > SIZE_LIMIT) {
        skipped.push({ name: rawKey, reason: `exceeds ${SIZE_LIMIT} bytes (${bytes} bytes)` });
        continue;
      }

      const target = path.join(specsDir, `${key}.json`);
      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.writeFile(target, json);
      specs.set(key, data);
    }
  } finally {
    await fs.rm(run.tmpDir, { recursive: true, force: true });
  }

  // Aliases: alternate names of top-level specs that are not primaries themselves.
  const aliases = {};
  for (const [key, data] of specs) {
    if (key.includes('/')) continue;
    for (const n of data.name) {
      if (n === key || specs.has(n) || n in aliases) continue;
      aliases[n] = key;
    }
  }

  const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  const byFile = (a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : 0);
  const index = {
    sourceCommit: typeof sourceCommit === 'string' && sourceCommit.length > 0 ? sourceCommit : null,
    generatedAt: new Date().toISOString(),
    count: specs.size,
    aliases: Object.fromEntries(Object.entries(aliases).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))),
    skipped: skipped.sort(byName),
    failed: failed.sort(byFile),
  };
  await fs.writeFile(path.join(specsDir, 'index.json'), JSON.stringify(index));

  say(
    `converted ${index.count} spec(s), ${Object.keys(aliases).length} alias(es), ` +
      `${skipped.length} skipped, ${failed.length} failed -> ${specsDir}`,
  );
  say(
    `dropped: ${stats.droppedFunctions} function(s), ${stats.droppedUnnamed} unnamed node(s), ` +
      `${stats.droppedCycles} cyclic reference(s), ${stats.droppedDepth} over-deep list(s)`,
  );
  for (const f of index.failed) say(`  failed  ${f.file}: ${f.error}`);
  return { index, specs, stats };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const opts = { quiet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const take = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`${a} needs a value`);
      return argv[i];
    };
    if (a === '--src') opts.src = take();
    else if (a === '--out') opts.out = take();
    else if (a === '--source-commit') opts.sourceCommit = take();
    else if (a === '--quiet') opts.quiet = true;
    else if (a === '-h' || a === '--help') opts.help = true;
    else throw new Error(`unknown argument: ${a}`);
  }
  return opts;
}

const USAGE = `usage: node convert.mjs --src <dir> --out <dir> [--source-commit <sha>] [--quiet]

  --src             directory of Fig spec modules (.js ESM or .ts), e.g. <withfig-checkout>/build
  --out             output root; specs land in <out>/specs/<name>.json plus <out>/specs/index.json
  --source-commit   commit sha of the corpus, recorded in index.json
`;

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let opts;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    console.error(USAGE);
    process.exit(2);
  }
  if (opts.help || !opts.src || !opts.out) {
    console.error(USAGE);
    process.exit(opts.help ? 0 : 2);
  }
  convert(opts).catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
