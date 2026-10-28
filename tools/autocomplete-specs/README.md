# autocomplete-specs

Offline converter from [Fig completion specs](https://fig.io/docs/reference/subcommand)
(the [withfig/autocomplete](https://github.com/withfig/autocomplete) corpus, MIT) to the
compact, data-only JSON that Slimer's Zig autocomplete engine loads lazily per CLI
(`docs/slimer/PLAN.md`, Phase 6b).

The tool runs on Node (>= 20) and is never part of `zig build`. Its output is committed
under `src/autocomplete/data/specs/` and embedded into the binary.

```
tools/autocomplete-specs/
├── convert.mjs       # Fig spec modules -> <out>/specs/<name>.json + index.json
├── validate.mjs      # checks an output directory against schema.json and index.json
├── schema.json       # JSON Schema 2020-12 for one spec file and for index.json
├── package.json      # pinned: ajv 8.20.0, esbuild 0.28.2
└── test/             # node --test; fixtures are handwritten, no network needed
```

## Regenerating from withfig/autocomplete

1. Check out the corpus at the commit you want to ship and build it there (it needs its
   own toolchain; this repo never depends on it):

   ```sh
   git clone https://github.com/withfig/autocomplete.git
   cd autocomplete
   git checkout <sha>
   pnpm install && pnpm build        # emits build/<name>.js (ESM) plus nested dirs
   ```

2. Convert and validate from this directory:

   ```sh
   cd tools/autocomplete-specs
   npm install                        # ajv + esbuild, exact versions
   node convert.mjs --src <checkout>/build --out ../../src/autocomplete/data --source-commit <sha>
   node validate.mjs ../../src/autocomplete/data
   ```

   `convert.mjs` deletes stale `*.json` under `<out>/specs/` first, so removed specs
   disappear. It prints a summary and every failed file; the same information is in
   `index.json` (`skipped`, `failed`). A non-empty `failed` list is worth a look but is
   not fatal: the corpus has a long tail of modules that need a running shell.

3. Copy the corpus license verbatim (see `src/autocomplete/data/LICENSE-withfig`, which
   starts life as placeholder instructions):

   ```sh
   cp <checkout>/LICENSE ../../src/autocomplete/data/LICENSE-withfig
   ```

4. Commit `src/autocomplete/data/` together. `index.json` records `sourceCommit`, so the
   data is always traceable to the corpus commit, which must match the license copy.

The converter also accepts `.ts` sources (each file is bundled to a temporary ESM module
with esbuild), which is what the tests use and what you can point at `<checkout>/src`
when a `pnpm build` is inconvenient. The `.js` path is tried as a plain ESM import first
and falls back to esbuild bundling for CommonJS output or relative imports.

## Output format

One minified JSON document per spec at `<out>/specs/<key>.json`. The key is the source
file path relative to `--src`, lowercased, without extension; each path segment must
match `[a-z0-9._-]+`, otherwise the spec is skipped and recorded. Top-level files are
primary commands; nested files (for example `aws/s3`) are `loadSpec` targets.

The document root is a `Subcommand`:

```jsonc
{
  "name": ["git"],
  "description": "The stupid content tracker",          // trimmed, whitespace collapsed, <= 200 code points
  "options": [
    { "name": ["-C"], "args": [{ "name": "path", "template": ["folders"] }] },
    { "name": ["--git-dir"], "requiresSeparator": true, "args": [{ "name": "path", "template": ["folders"] }] },
    { "name": ["--paginate", "-p"], "isRepeatable": 3, "exclusiveOn": ["--no-pager"] }
  ],
  "subcommands": [
    { "name": ["lfs"], "description": "Git LFS", "loadSpec": "git-lfs" },
    {
      "name": ["checkout", "co"],
      "args": [{
        "name": "branch",
        "suggestions": [{ "name": ["HEAD"], "description": "Current commit", "icon": "🔖", "priority": 100 }],
        "generators": [{
          "script": ["git", "branch", "--no-color"],       // argv; legacy string scripts become ["bash", "-c", s]
          "trigger": { "on": "change" },
          "hasPostProcess": true,                           // the function itself is gone
          "hasCustom": false,
          "cache": { "ttl": 2000, "cacheByDirectory": true }
        }]
      }]
    },
    { "name": ["push"], "isDangerous": true, "args": [{ "name": "remote", "isOptional": true }] }
  ]
}
```

Shapes (all keys optional unless marked; booleans appear only when `true`):

| Type | Fields |
| --- | --- |
| `Subcommand` | `name: string[]` (required), `description`, `hidden`, `isDangerous`, `requiresSubcommand`, `priority: number`, `loadSpec: string`, `subcommands`, `options`, `args` |
| `Option` | `name: string[]` (required), `description`, `args`, `isRequired`, `isRepeatable: true \| integer`, `isPersistent`, `isDangerous`, `exclusiveOn: string[]`, `dependsOn: string[]`, `requiresSeparator: true \| string`, `hidden`, `priority` |
| `Arg` | `name`, `description`, `isOptional`, `isVariadic`, `isCommand`, `isScript`, `isDangerous`, `template: string[]`, `suggestions: Suggestion[]`, `generators: Generator[]` |
| `Suggestion` | `name: string[]` (required), `description`, `icon`, `priority`, `isDangerous`, `hidden` |
| `Generator` | `script: string[] \| null`, `splitOn`, `template: string[]`, `trigger: string \| object`, `hasPostProcess: boolean` (required), `hasCustom: boolean` (required), `cache: object` |

Normalization rules, all enforced by `schema.json`:

- `name` and `template` are always arrays; `args` and `generators` given as a single
  object become one-element arrays. A single `arg` with no fields serializes as `{}`
  (one untyped positional).
- Strings are trimmed. Descriptions and arg labels have unsafe characters (C0/C1
  controls, DEL, U+2028/2029, bidi overrides and isolates) replaced by spaces, whitespace
  collapsed, and are capped at 200 (descriptions) or 80 (arg labels) code points.
- Names, templates, `loadSpec`, `exclusiveOn`, `dependsOn`, `requiresSeparator` and
  string `trigger`s are candidate text that may reach the terminal: a value containing
  an unsafe character is rejected whole, not stripped, matching
  `docs/slimer/CONVENTIONS.md`. A subcommand, option or suggestion with no surviving name
  is dropped.
- `template` keeps only `filepaths`, `folders`, `history`, `help`.
- `icon` survives only as a short emoji (<= 8 code points of emoji-class characters) or a
  `fig://` URI; everything else (http URLs, paths) is dropped.
- `requiresEquals: true` (deprecated Fig field) becomes `requiresSeparator: true`.
- Functions never survive. `postProcess` and `custom` become the flags `hasPostProcess`
  and `hasCustom`; a function-valued `script` becomes `script: null`; function
  `loadSpec`, `generateSpec`, `getQueryTerm`, `filterTemplateSuggestions` are dropped. An
  inline `loadSpec` object has its `subcommands`/`options`/`args`/`description` merged
  into the node where the node did not define them.
- A legacy string `script` (Fig ran those with `bash -c`) is stored as
  `["bash", "-c", "<script>"]` so every script is argv.
- `trigger` and `cache` objects are copied as JSON data only (primitives, identifier
  keys, shallow nesting).

`<out>/specs/index.json`:

```json
{
  "sourceCommit": "<sha or null>",
  "generatedAt": "2026-10-28T19:56:00.413Z",
  "count": 6,
  "aliases": { "vim": "nvim" },
  "skipped": [{ "name": "aws", "reason": "on the skip list" }],
  "failed": [{ "file": "broken.js", "error": "Unexpected end of input" }]
}
```

- `aliases` maps every alternate `name` of a top-level spec to its file key, unless that
  name is itself a primary spec (the primary wins) or already claimed. Nested specs never
  produce aliases. Because keys are lowercased, a command like `Rscript` shows up as
  `"Rscript": "rscript"`.
- Always skipped: `aws`, `az`, `gcloud` (and everything under those directories), any
  spec whose minified JSON exceeds 512 KiB, filenames that do not sanitize, the reserved
  key `index`, modules without a named default export, duplicates of an already-written
  key, and `createVersionedSpec`-style exports (they resolve to
  `{ versionedSpecPath, version }` by running the tool, which cannot happen offline).
- `failed` lists modules that threw while loading or while their exported function ran.

### Accepted export shapes

The default export may be a `Fig.Spec` object, a `Fig.Subcommand`, a function returning
either (called with an inert `executeShellCommand` stub that returns empty output and a
dummy context; 5 s timeout), or a wrapper object keyed `default`, `completionSpec`,
`versionedSpec` or `spec`, nested up to eight levels (this covers CommonJS interop and
the `{ completionSpec, versions }` form). Version diff maps are ignored: the base spec is
emitted.

## Security rationale

- **Generator scripts are data.** The converter reads the spec modules and writes JSON.
  It never runs a generator `script`, `postProcess` or `custom` function; the only code it
  executes is the spec module itself (top-level object construction) and, for function
  exports, that function with stubbed inputs, which is why you convert from a pinned,
  reviewed commit of the corpus and not from arbitrary input.
- **The engine's `scripted` tier is opt-in forever.** `script` argv in the JSON is inert
  until the user sets `autocomplete-generators = scripted`; the default `native` tier
  reimplements the common generators without executing anything (PLAN.md 6b). Even then
  scripts run through the sandboxed helper with timeouts and output caps.
- **Candidate text is pre-sanitized at conversion time** and the schema proves it: names
  cannot contain control characters or bidi overrides, descriptions are bounded, and the
  validator rejects any file that regresses. The engine still re-checks at insertion
  time; the converter just guarantees the shipped data starts clean.
- **No code in the data path.** The JSON format has no way to express a function, a
  module path outside `specs/`, or a URL other than `fig://` icon identifiers.

## Attribution

withfig/autocomplete is MIT licensed. Redistributing the converted data requires
shipping its copyright and permission notice. `src/autocomplete/data/LICENSE-withfig`
holds placeholder instructions until the first real conversion; replace its contents
with the corpus `LICENSE` file copied verbatim from the same commit as
`index.json.sourceCommit`, and keep it next to `specs/` in every build that embeds them.
Do not retype or paraphrase the license text.

## Development

```sh
npm install
npm test                                   # node --test test/ (fixtures under test/fixtures/)
node convert.mjs --src test/fixtures --out /tmp/ac-out --source-commit test
node validate.mjs /tmp/ac-out
```

Fixtures cover: a git-like TypeScript spec with nested subcommands, every `loadSpec`
form, option args and templates, string/object suggestions, and string/argv/function
generators (`git.ts`); a function export (`node.js`); a `{ completionSpec, versions }`
wrapper (`yarn.js`); a `createVersionedSpec`-style function (`deno.js`, skipped); aliases
and a colliding primary (`nvim.js`, `vi.js`); a nested spec (`docker/compose.js`); the
skip list (`aws.js`); the size cap (`huge.js`, built in a loop); an unsanitizable name
(`g++.js`); the reserved key (`index.js`); and a module with a syntax error
(`broken.js`).

Dependencies are pinned to exact versions on purpose; bump them deliberately and re-run
the tests.
