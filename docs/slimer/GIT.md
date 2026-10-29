# Git status (Phase 4A)

Read-only git state provider for the per-surface status bar. Code lives in
`macos/Sources/Features/Git/`, tests in `macos/Tests/Features/Git/`. There is no UI
in this layer.

## Files

| File | Role |
| --- | --- |
| `GitRepoState.swift` | Value model (Equatable, Codable, Sendable). |
| `GitPorcelainParser.swift` | Pure parser for `git status --porcelain=v2 --branch -z`. |
| `GitOperationDetector.swift` | Merge/rebase/cherry-pick/revert/bisect detection from marker files. |
| `GitPathPolicy.swift` | Directories that are never inspected. |
| `GitProcessRunner.swift` | Locates `git`, builds the restricted env, runs with a hard timeout. |
| `GitRepoWatcher.swift` | `DispatchSource` vnode watchers on the git directory. |
| `GitStatusService.swift` | Shared main-actor service: caching, debounce, coalescing, publishing. |
| `GitActions.swift` | Popover actions as data, plus POSIX shell quoting. |

## Model

`GitRepoState` JSON shape (portable; the Windows host reimplements against it):

```json
{
  "root": "/Users/me/Dev/repo",
  "branch": "main",
  "detachedHead": null,
  "upstream": "origin/main",
  "ahead": 1, "behind": 0,
  "staged": 2, "unstaged": 1, "untracked": 3, "conflicted": 0,
  "stashCount": 1,
  "operation": "rebase",
  "updatedAt": 1761650000.0
}
```

- `root` is a plain path, `updatedAt` Unix seconds. Absent optional keys are omitted.
- `branch` is `null` when HEAD is detached; `detachedHead` then holds the 7-char SHA.
- `operation` is one of `merge`, `rebase`, `cherry-pick`, `revert`, `bisect`.
- Counts come from porcelain v2: `staged` = `1`/`2` entries with X != `.`,
  `unstaged` = Y != `.`, `untracked` = `?`, `conflicted` = `u`. Ignored (`!`) entries
  are parsed but not exposed. A rename record (`2`) consumes the following
  NUL-separated original path so it is never mistaken for a record.

## Service API

```swift
GitStatusService.shared.state(for: dir)          // cached GitRepoState? (kicks off resolution if unknown)
GitStatusService.shared.observe(directory: dir)  // AnyPublisher<GitRepoState?, Never>, one per subscriber
GitStatusService.shared.refresh(root: root)      // debounced refresh
GitStatusService.shared.refreshedState(for: dir) // async, immediate refresh, used by tests
GitStatusService.shared.branchList(root: root)   // async [String], local + remote
```

`observe` emits the cached value on subscription, then each refresh. It emits `nil`
for non-repositories, excluded paths, or when the service is disabled.

## Refresh pipeline

1. **Root resolution:** one `git -C <dir> rev-parse --show-toplevel --absolute-git-dir
   --git-common-dir`. Cached per directory for 30 s. Negative results (not a repo,
   excluded path) are cached for 30 s too. Concurrent resolutions of one directory
   share a single process.
2. **Status:** `git -C <root> status --porcelain=v2 --branch -z --untracked-files=normal
   --show-stash`. git only prints `# stash N` when N > 0, so a missing header means 0.
   If git rejects `--show-stash` (older than 2.35), the service retries without it,
   remembers that, and counts `git stash list --format=%gd` lines instead.
3. **Operation:** checks for marker files in the per-worktree git dir (contents are
   never read). Priority: `rebase-merge/`, `rebase-apply/`, `MERGE_HEAD`,
   `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_LOG`.
4. **Scheduling:** all git processes run on one serial utility queue. Each refresh
   request is debounced by 250 ms per root. At most one refresh per root is in
   flight; a request that arrives during a refresh schedules one follow-up.
5. **Failure handling:** a timeout or other transient failure keeps the last good
   state. "not a git repository" publishes `nil` and drops the cached roots.

## Triggers

- An explicit `refresh(root:)` or `refresh(directory:)` call. The UI layer should call
  it on PWD change and on `COMMAND_FINISHED`.
- The first subscription to `observe`.
- File watches (`DispatchSource` vnode, `O_EVTONLY`) on the git dir, `HEAD`, `index`,
  `refs/`, `refs/heads/`, `refs/remotes/` and (for linked worktrees) the common dir.
  Marker files such as `MERGE_HEAD` show up as git-dir directory writes. Replaced
  files (git renames over `HEAD`/`index`) are re-armed after 200 ms.
- Watchers exist only while a root has at least one observer. They are dropped 60 s
  after the last observer cancels.

## Timeouts and skips

- Every git invocation has a hard 2 s timeout. On expiry the process gets SIGTERM,
  then SIGKILL 0.5 s later.
- Skipped without spawning git: `/`, `/System/**`, `~/Library/**` (also after
  resolving symlinks), non-local volumes (`URLResourceKey.volumeIsLocalKey == false`),
  and missing or unreadable directories.

## Security posture

- **Read-only.** The app itself runs only `rev-parse`, `status`, `stash list` and
  `for-each-ref`. Mutating commands are never executed by the app.
- **git lookup:** only on `/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin`. The user's
  `$PATH` is never consulted. `/usr/bin/git` is accepted only when `xcode-select -p`
  succeeds, so the app never triggers the "install developer tools" dialog. With no
  git found, the service is disabled and publishes `nil`.
- **Environment:** built from scratch, not inherited: `PATH` (as above), `HOME`,
  `LANG=C`, `GIT_OPTIONAL_LOCKS=0` (status never takes the index lock),
  `GIT_TERMINAL_PROMPT=0`. `GIT_DIR`, `GIT_WORK_TREE` and every other variable are
  absent. stdin is `/dev/null`.
- **Arguments:** fixed argument lists. The only user-influenced value is the directory
  passed as the value of `-C`, which git treats as a path, never as an option.
- **Untrusted output:** porcelain output is only counted. Branch and upstream names are
  data. `branchList` drops names that fail `GitShellQuoting.validate`.
- **Repo config:** every invocation passes `-c core.fsmonitor=false`, so a hostile
  repository's `.git/config` cannot make `status` run an fsmonitor hook command just
  because a terminal `cd`ed into it. (Shell prompts with git integration do not do
  this.)

## Actions (data only)

`GitActions.standard` = fetch (`git fetch --all --prune`), pull (`git pull --ff-only`),
push (`git push`, or `git push -u origin <branch>` without an upstream), stash
(`git stash push`), pop (`git stash pop`). Plus `switchBranch(to:)` (`git switch <b>`)
and `createBranch(named:)` (`git switch -c <b>`). Each has `title`, `systemImage`,
`isAvailable(for:)` and `commandLine(for:) throws -> String`.

Names are shell-quoted: plain `[A-Za-z0-9_./@-]` words pass through as-is; anything
else is single-quoted with `'` written as `'\''`. Names that are empty, start with
`-`, or contain C0/C1 controls, DEL, U+2028/2029 or bidi controls are rejected (the
call throws). They are never stripped. The UI inserts the text into the terminal and
sends Enter only after an explicit confirm click.

## Measured latency

On an Apple Silicon Mac with `/usr/bin/git` (Apple git, xcrun shim) against this
repository (about 5,900 tracked files): root resolution about 64 ms; full refresh
p50 67 ms, max 73 ms over 20 runs. Most of this is the shim's startup cost. A
Homebrew git is faster but `/usr/bin` comes first on the fixed search path.
