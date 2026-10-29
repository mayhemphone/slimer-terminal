// Slimer starter spec (hand-written, not from withfig/autocomplete).
// Generator scripts mirror the Fig corpus so the engine's native
// generators recognize them; they are never executed.

const branches = {
  script: ["git", "--no-optional-locks", "branch", "-a", "--no-color", "--sort=-committerdate"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((name) => ({ name: name.replace(/^\*?\s+/, "") })),
};
const localBranches = {
  script: ["git", "--no-optional-locks", "branch", "--no-color", "--sort=-committerdate"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((name) => ({ name: name.replace(/^\*?\s+/, "") })),
};
const remotes = {
  script: ["git", "--no-optional-locks", "remote", "-v"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((line) => ({ name: line.split(/\s/)[0] })),
};
const tags = {
  script: ["git", "--no-optional-locks", "tag", "--list", "--sort=-committerdate"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((name) => ({ name })),
};

const branchArg = (extra = {}) => ({ name: "branch", generators: branches, ...extra });
const commitArg = (extra = {}) => ({ name: "commit", generators: [branches, tags], ...extra });
const pathspec = { name: "pathspec", isVariadic: true, isOptional: true, template: "filepaths" };

const completionSpec = {
  name: "git",
  description: "The stupid content tracker",
  options: [
    { name: "-C", description: "Run as if git was started in <path>", args: { name: "path", template: "folders" } },
    { name: "-c", description: "Pass a configuration parameter", isRepeatable: true, args: { name: "name=value" } },
    { name: "--version", description: "Print the git version" },
    { name: ["--help", "-h"], description: "Show help" },
    { name: "--no-pager", description: "Do not pipe output into a pager" },
  ],
  subcommands: [
    {
      name: "status",
      description: "Show the working tree status",
      options: [
        { name: ["-s", "--short"], description: "Give the output in the short format" },
        { name: ["-b", "--branch"], description: "Show branch information" },
        { name: "--porcelain", description: "Machine-readable output" },
        { name: ["-u", "--untracked-files"], description: "Show untracked files", requiresSeparator: true, args: { name: "mode", isOptional: true, suggestions: ["no", "normal", "all"] } },
        { name: "--ignored", description: "Show ignored files as well" },
      ],
      args: pathspec,
    },
    {
      name: "add",
      description: "Add file contents to the index",
      options: [
        { name: ["-A", "--all"], description: "Add changes from all tracked and untracked files" },
        { name: ["-p", "--patch"], description: "Interactively choose hunks" },
        { name: ["-u", "--update"], description: "Update tracked files only" },
        { name: ["-n", "--dry-run"], description: "Don't actually add the files" },
        { name: ["-f", "--force"], description: "Allow adding otherwise ignored files" },
        { name: ["-i", "--interactive"], description: "Add modified contents interactively" },
      ],
      args: { name: "pathspec", isVariadic: true, template: "filepaths" },
    },
    {
      name: "commit",
      description: "Record changes to the repository",
      options: [
        { name: ["-m", "--message"], description: "Use the given message", isRepeatable: true, args: { name: "message" } },
        { name: ["-a", "--all"], description: "Stage all modified and deleted files" },
        { name: "--amend", description: "Replace the tip of the current branch" },
        { name: "--no-edit", description: "Use the selected message without launching an editor" },
        { name: ["-v", "--verbose"], description: "Show the diff in the message template" },
        { name: ["-s", "--signoff"], description: "Add a Signed-off-by trailer" },
        { name: ["-S", "--gpg-sign"], description: "GPG-sign the commit" },
        { name: "--no-verify", description: "Bypass the pre-commit and commit-msg hooks" },
        { name: "--fixup", description: "Create a fixup commit", requiresSeparator: true, args: commitArg() },
        { name: ["-F", "--file"], description: "Take the message from a file", args: { name: "file", template: "filepaths" } },
        { name: "--allow-empty", description: "Allow a commit with no changes" },
      ],
      args: pathspec,
    },
    {
      name: "push",
      description: "Update remote refs along with associated objects",
      options: [
        { name: ["-u", "--set-upstream"], description: "Set upstream for the current branch" },
        { name: ["-f", "--force"], description: "Force updates", isDangerous: true },
        { name: "--force-with-lease", description: "Force only if the remote ref is what we expect" },
        { name: "--tags", description: "Push all tags" },
        { name: ["-d", "--delete"], description: "Delete the listed refs from the remote", isDangerous: true },
        { name: ["-n", "--dry-run"], description: "Do everything except actually send the updates" },
        { name: "--no-verify", description: "Bypass the pre-push hook" },
      ],
      args: [
        { name: "remote", isOptional: true, generators: remotes },
        { name: "refspec", isOptional: true, isVariadic: true, generators: localBranches },
      ],
    },
    {
      name: "pull",
      description: "Fetch from and integrate with another repository or branch",
      options: [
        { name: ["-r", "--rebase"], description: "Rebase the current branch on top of upstream" },
        { name: "--ff-only", description: "Only fast-forward" },
        { name: "--no-rebase", description: "Merge instead of rebasing" },
        { name: "--autostash", description: "Stash and reapply local changes" },
        { name: "--tags", description: "Fetch all tags" },
      ],
      args: [
        { name: "remote", isOptional: true, generators: remotes },
        { name: "branch", isOptional: true, generators: branches },
      ],
    },
    {
      name: "fetch",
      description: "Download objects and refs from another repository",
      options: [
        { name: "--all", description: "Fetch all remotes" },
        { name: ["-p", "--prune"], description: "Remove remote-tracking refs that no longer exist" },
        { name: ["-t", "--tags"], description: "Fetch all tags" },
        { name: "--depth", description: "Limit fetching to the given depth", args: { name: "depth" } },
      ],
      args: [
        { name: "remote", isOptional: true, generators: remotes },
        { name: "refspec", isOptional: true, isVariadic: true },
      ],
    },
    {
      name: "switch",
      description: "Switch branches",
      options: [
        { name: ["-c", "--create"], description: "Create a new branch and switch to it", args: { name: "new-branch" } },
        { name: ["-C", "--force-create"], description: "Create or reset a branch and switch to it", args: { name: "new-branch" } },
        { name: ["-d", "--detach"], description: "Switch to a commit for inspection" },
        { name: "--discard-changes", description: "Throw away local modifications", isDangerous: true },
      ],
      args: branchArg({ isOptional: true }),
    },
    {
      name: ["checkout", "co"],
      description: "Switch branches or restore working tree files",
      options: [
        { name: "-b", description: "Create a new branch and check it out", args: { name: "new-branch" } },
        { name: "-B", description: "Create or reset a branch and check it out", args: { name: "new-branch" } },
        { name: ["-f", "--force"], description: "Throw away local modifications", isDangerous: true },
        { name: "--track", description: "Set up upstream tracking" },
        { name: "--", description: "Treat the remaining arguments as paths" },
      ],
      args: [branchArg({ isOptional: true }), pathspec],
    },
    {
      name: "branch",
      description: "List, create, or delete branches",
      options: [
        { name: ["-a", "--all"], description: "List both remote-tracking and local branches" },
        { name: ["-r", "--remotes"], description: "List remote-tracking branches" },
        { name: ["-d", "--delete"], description: "Delete a fully merged branch", args: { name: "branch", isVariadic: true, generators: localBranches } },
        { name: "-D", description: "Delete a branch irrespective of its merged status", isDangerous: true, args: { name: "branch", isVariadic: true, generators: localBranches } },
        { name: ["-m", "--move"], description: "Rename a branch", args: [{ name: "old", generators: localBranches }, { name: "new", isOptional: true }] },
        { name: ["-v", "--verbose"], description: "Show sha1 and subject for each head" },
        { name: ["-u", "--set-upstream-to"], description: "Set upstream", args: { name: "upstream", generators: branches } },
        { name: "--show-current", description: "Print the name of the current branch" },
      ],
      args: { name: "branch", isOptional: true },
    },
    {
      name: "merge",
      description: "Join two or more development histories together",
      options: [
        { name: "--no-ff", description: "Always create a merge commit" },
        { name: "--ff-only", description: "Refuse to merge unless fast-forward" },
        { name: "--squash", description: "Squash the merged changes" },
        { name: "--abort", description: "Abort the current conflict resolution" },
        { name: "--continue", description: "Conclude the merge after resolving conflicts" },
        { name: ["-m", "--message"], description: "Set the merge commit message", args: { name: "message" } },
      ],
      args: commitArg({ isOptional: true, isVariadic: true }),
    },
    {
      name: "rebase",
      description: "Reapply commits on top of another base tip",
      options: [
        { name: ["-i", "--interactive"], description: "Make a list of the commits to be rebased" },
        { name: "--continue", description: "Restart the rebasing process" },
        { name: "--abort", description: "Abort the rebase operation" },
        { name: "--skip", description: "Skip the current patch" },
        { name: "--onto", description: "Starting point for the new commits", args: commitArg() },
        { name: "--autosquash", description: "Move fixup commits into place" },
        { name: "--autostash", description: "Stash and reapply local changes" },
      ],
      args: [commitArg({ name: "upstream", isOptional: true }), branchArg({ isOptional: true })],
    },
    {
      name: "log",
      description: "Show commit logs",
      options: [
        { name: "--oneline", description: "One line per commit" },
        { name: "--graph", description: "Draw a text-based graph of the history" },
        { name: "--all", description: "Show all refs" },
        { name: ["-p", "--patch"], description: "Show the diff for each commit" },
        { name: "--stat", description: "Show diffstat" },
        { name: ["-n", "--max-count"], description: "Limit the number of commits", args: { name: "number" } },
        { name: "--author", description: "Limit to commits by author", requiresSeparator: true, args: { name: "pattern" } },
        { name: "--since", description: "Show commits more recent than a date", requiresSeparator: true, args: { name: "date" } },
        { name: "--follow", description: "Continue listing history beyond renames" },
      ],
      args: [commitArg({ isOptional: true }), pathspec],
    },
    {
      name: "diff",
      description: "Show changes between commits, the index and the working tree",
      options: [
        { name: ["--staged", "--cached"], description: "Show staged changes" },
        { name: "--stat", description: "Show diffstat" },
        { name: "--name-only", description: "Show only names of changed files" },
        { name: "--name-status", description: "Show names and status of changed files" },
        { name: "--word-diff", description: "Show a word diff" },
        { name: "--", description: "Treat the remaining arguments as paths" },
      ],
      args: [commitArg({ isOptional: true }), pathspec],
    },
    {
      name: "stash",
      description: "Stash the changes in a dirty working directory away",
      subcommands: [
        { name: "push", description: "Save local modifications to a new stash entry", options: [{ name: ["-m", "--message"], description: "Stash message", args: { name: "message" } }, { name: ["-u", "--include-untracked"], description: "Include untracked files" }] },
        { name: "pop", description: "Apply a stash and remove it from the stash list", args: { name: "stash", isOptional: true } },
        { name: "apply", description: "Apply a stash without removing it", args: { name: "stash", isOptional: true } },
        { name: "list", description: "List the stash entries" },
        { name: "show", description: "Show the changes recorded in a stash", args: { name: "stash", isOptional: true } },
        { name: "drop", description: "Remove a single stash entry", isDangerous: true, args: { name: "stash", isOptional: true } },
        { name: "clear", description: "Remove all the stash entries", isDangerous: true },
      ],
    },
    {
      name: "restore",
      description: "Restore working tree files",
      options: [
        { name: ["-S", "--staged"], description: "Restore the index" },
        { name: ["-W", "--worktree"], description: "Restore the working tree" },
        { name: ["-s", "--source"], description: "Restore from the given tree", args: commitArg() },
        { name: ["-p", "--patch"], description: "Interactively select hunks" },
      ],
      args: { name: "pathspec", isVariadic: true, template: "filepaths" },
    },
    {
      name: "reset",
      description: "Reset current HEAD to the specified state",
      options: [
        { name: "--soft", description: "Keep the index and working tree" },
        { name: "--mixed", description: "Reset the index but not the working tree" },
        { name: "--hard", description: "Reset the index and working tree, discarding changes", isDangerous: true },
        { name: "--keep", description: "Reset but keep local changes" },
        { name: ["-p", "--patch"], description: "Interactively select hunks" },
      ],
      args: [commitArg({ isOptional: true }), pathspec],
    },
    {
      name: "clone",
      description: "Clone a repository into a new directory",
      options: [
        { name: "--depth", description: "Create a shallow clone", args: { name: "depth" } },
        { name: ["-b", "--branch"], description: "Check out this branch", args: { name: "branch" } },
        { name: "--recurse-submodules", description: "Initialize submodules" },
        { name: "--bare", description: "Make a bare repository" },
        { name: "--single-branch", description: "Clone only one branch" },
      ],
      args: [{ name: "repository" }, { name: "directory", isOptional: true, template: "folders" }],
    },
    {
      name: "remote",
      description: "Manage set of tracked repositories",
      options: [{ name: ["-v", "--verbose"], description: "Show remote URLs" }],
      subcommands: [
        { name: "add", description: "Add a remote", args: [{ name: "name" }, { name: "url" }] },
        { name: ["remove", "rm"], description: "Remove a remote", isDangerous: true, args: { name: "name", generators: remotes } },
        { name: "rename", description: "Rename a remote", args: [{ name: "old", generators: remotes }, { name: "new" }] },
        { name: "set-url", description: "Change a remote URL", args: [{ name: "name", generators: remotes }, { name: "url" }] },
        { name: "get-url", description: "Show a remote URL", args: { name: "name", generators: remotes } },
        { name: "show", description: "Show information about a remote", args: { name: "name", generators: remotes } },
        { name: "prune", description: "Delete stale remote-tracking branches", args: { name: "name", generators: remotes } },
      ],
    },
    {
      name: "tag",
      description: "Create, list, delete or verify a tag object",
      options: [
        { name: ["-a", "--annotate"], description: "Make an annotated tag" },
        { name: ["-m", "--message"], description: "Tag message", args: { name: "message" } },
        { name: ["-d", "--delete"], description: "Delete tags", isDangerous: true, args: { name: "tag", isVariadic: true, generators: tags } },
        { name: ["-l", "--list"], description: "List tags" },
        { name: ["-s", "--sign"], description: "Make a GPG-signed tag" },
      ],
      args: [{ name: "tagname", isOptional: true }, commitArg({ isOptional: true })],
    },
    {
      name: "cherry-pick",
      description: "Apply the changes introduced by some existing commits",
      options: [
        { name: "--continue", description: "Continue the operation in progress" },
        { name: "--abort", description: "Cancel the operation" },
        { name: "--skip", description: "Skip the current commit" },
        { name: ["-n", "--no-commit"], description: "Apply changes without committing" },
        { name: "-x", description: "Record the original commit in the message" },
      ],
      args: commitArg({ isVariadic: true }),
    },
    {
      name: "init",
      description: "Create an empty Git repository",
      options: [{ name: ["-b", "--initial-branch"], description: "Name of the initial branch", args: { name: "branch-name" } }],
      args: { name: "directory", isOptional: true, template: "folders" },
    },
    {
      name: "show",
      description: "Show various types of objects",
      options: [{ name: "--stat", description: "Show diffstat" }, { name: "--name-only", description: "Show only names of changed files" }],
      args: commitArg({ isOptional: true, isVariadic: true }),
    },
    {
      name: "worktree",
      description: "Manage multiple working trees",
      subcommands: [
        { name: "add", description: "Create a new working tree", options: [{ name: "-b", description: "Create a new branch", args: { name: "new-branch" } }], args: [{ name: "path", template: "folders" }, branchArg({ isOptional: true })] },
        { name: "list", description: "List working trees" },
        { name: "remove", description: "Remove a working tree", isDangerous: true, args: { name: "worktree", template: "folders" } },
        { name: "prune", description: "Prune working tree information" },
      ],
    },
    {
      name: "clean",
      description: "Remove untracked files from the working tree",
      isDangerous: true,
      options: [
        { name: ["-n", "--dry-run"], description: "Only show what would be removed" },
        { name: ["-f", "--force"], description: "Actually remove files", isDangerous: true },
        { name: "-d", description: "Recurse into untracked directories" },
        { name: "-x", description: "Also remove ignored files", isDangerous: true },
      ],
    },
  ],
};

export default completionSpec;
