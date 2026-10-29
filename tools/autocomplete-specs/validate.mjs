#!/usr/bin/env node
// Validates a converter output directory: every `<out>/specs/**/*.json` against
// schema.json (JSON Schema 2020-12 via Ajv) and `<out>/specs/index.json` for
// internal consistency. Exit code 1 on any failure.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import { NAME_RE, RESERVED_NAMES, SIZE_LIMIT, SKIP_NAMES } from './convert.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

async function loadValidators() {
  let AjvModule;
  try {
    AjvModule = await import('ajv/dist/2020.js');
  } catch (err) {
    throw new Error(`ajv is required (run \`npm install\` in tools/autocomplete-specs): ${err.message}`);
  }
  const Ajv2020 = AjvModule.default?.default ?? AjvModule.default ?? AjvModule;
  const schema = JSON.parse(await fs.readFile(path.join(here, 'schema.json'), 'utf8'));
  const ajv = new Ajv2020({ strict: true, allErrors: true, allowUnionTypes: true, unicodeRegExp: true });
  ajv.addSchema(schema);
  return {
    spec: ajv.compile({ $ref: `${schema.$id}#/$defs/Subcommand` }),
    index: ajv.compile({ $ref: `${schema.$id}#/$defs/Index` }),
  };
}

function formatAjvErrors(errors) {
  return (errors ?? [])
    .slice(0, 5)
    .map((e) => `${e.instancePath || '/'} ${e.message ?? ''}${e.params?.additionalProperty ? ` (${e.params.additionalProperty})` : ''}`)
    .join('; ');
}

async function listJsonFiles(dir, rel = '') {
  const out = [];
  const entries = await fs.readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const abs = path.join(dir, entry.name);
    const relName = rel ? `${rel}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...(await listJsonFiles(abs, relName)));
    else if (entry.isFile() && entry.name.endsWith('.json')) out.push({ abs, rel: relName });
  }
  return out.sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
}

/**
 * @returns {Promise<{ ok: boolean, errors: string[], checked: number }>}
 */
export async function validateDir(outDir) {
  const errors = [];
  const specsDir = path.join(path.resolve(outDir), 'specs');
  const validators = await loadValidators();

  let files;
  try {
    files = await listJsonFiles(specsDir);
  } catch (err) {
    return { ok: false, errors: [`cannot read ${specsDir}: ${err.message}`], checked: 0 };
  }

  const keys = new Set();
  let index;
  let checked = 0;

  for (const { abs, rel } of files) {
    let text;
    let doc;
    try {
      text = await fs.readFile(abs, 'utf8');
      doc = JSON.parse(text);
    } catch (err) {
      errors.push(`${rel}: unreadable or invalid JSON: ${err.message}`);
      continue;
    }

    if (rel === 'index.json') {
      index = doc;
      if (!validators.index(doc)) errors.push(`index.json: ${formatAjvErrors(validators.index.errors)}`);
      checked += 1;
      continue;
    }

    const key = rel.slice(0, -'.json'.length);
    const segments = key.split('/');
    if (segments.some((s) => !NAME_RE.test(s))) errors.push(`${rel}: filename is not [a-z0-9._-]`);
    if (SKIP_NAMES.has(segments[0])) errors.push(`${rel}: on the skip list but present`);
    if (RESERVED_NAMES.has(key)) errors.push(`${rel}: reserved name`);
    const bytes = Buffer.byteLength(text);
    if (bytes > SIZE_LIMIT) errors.push(`${rel}: ${bytes} bytes exceeds ${SIZE_LIMIT}`);
    if (!validators.spec(doc)) errors.push(`${rel}: ${formatAjvErrors(validators.spec.errors)}`);
    keys.add(key);
    checked += 1;
  }

  if (!index) {
    errors.push('index.json: missing');
  } else if (typeof index === 'object' && index !== null) {
    if (index.count !== keys.size) errors.push(`index.json: count ${index.count} but ${keys.size} spec file(s) found`);
    for (const [alias, primary] of Object.entries(index.aliases ?? {})) {
      if (!keys.has(primary) || primary.includes('/')) errors.push(`index.json: alias ${alias} -> ${primary} has no top-level spec file`);
      if (keys.has(alias)) errors.push(`index.json: alias ${alias} shadows a primary spec`);
    }
    for (const entry of index.skipped ?? []) {
      if (typeof entry?.name === 'string' && keys.has(entry.name.toLowerCase())) {
        errors.push(`index.json: ${entry.name} is listed as skipped but a spec file exists`);
      }
    }
  }

  return { ok: errors.length === 0, errors, checked };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const outDir = process.argv[2];
  if (!outDir) {
    console.error('usage: node validate.mjs <outdir>   (validates <outdir>/specs/**/*.json)');
    process.exit(2);
  }
  validateDir(outDir)
    .then(({ ok, errors, checked }) => {
      for (const e of errors) console.error(`error: ${e}`);
      console.error(`${ok ? 'ok' : 'FAILED'}: ${checked} file(s) checked, ${errors.length} error(s)`);
      process.exit(ok ? 0 : 1);
    })
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
