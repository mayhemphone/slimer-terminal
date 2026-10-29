// Realistic git-like spec: nested subcommands, loadSpec (string, object and
// function), options with args and templates, suggestions as strings and
// objects, and every generator flavour.

const branchGenerator: Fig.Generator = {
  script: ["git", "branch", "--no-color", "--sort=-committerdate"],
  postProcess: (out) =>
    out
      .split("\n")
      .filter(Boolean)
      .map((line) => ({ name: line.replace(/^\*?\s+/, ""), icon: "fig://icon?type=git", description: "Branch" })),
  cache: { ttl: 2000, cacheByDirectory: true },
  trigger: { on: "change" },
};

const remoteGenerator: Fig.Generator = {
  // Legacy string script: Fig ran these through `bash -c`.
  script: "  git remote -v | awk '{print $1}' | sort -u  ",
  splitOn: "\n",
};

const fileGenerator: Fig.Generator = {
  script: (tokens) => ["git", "status", "--porcelain", tokens[tokens.length - 1]],
  postProcess: (out) => out.split("\n").map((name) => ({ name })),
  trigger: { on: "match", string: "/" },
  getQueryTerm: (token) => token.slice(token.lastIndexOf("/") + 1),
};

const customGenerator: Fig.Generator = {
  custom: async (tokens, executeShellCommand) => {
    const { stdout } = await executeShellCommand({ command: "git", args: ["tag"] });
    return stdout.split("\n").map((name) => ({ name }));
  },
  trigger: "/",
  cache: { strategy: "stale-while-revalidate", ttl: 500, bogus: () => 1 },
};

const completionSpec: Fig.Spec = {
  name: "git",
  description: "  The stupid\tcontent tracker  ",
  icon: "fig://icon?type=git",
  generateSpec: async () => ({ name: "git" }),
  options: [
    { name: ["-C"], description: "Run as if git was started in <path>", args: { name: "path", template: "folders" } },
    { name: ["--git-dir"], requiresEquals: true, args: { name: "path", template: ["folders", "bogus-template"] } },
    { name: ["-c"], isRepeatable: true, args: { name: "name=value" } },
    { name: "--version", description: "v".repeat(300) },
    { name: ["--help", "-h"], isPersistent: true, description: "Help" },
    { name: "--secret", hidden: true, priority: 10 },
    { name: "--exec-path", requiresSeparator: "=", args: { name: "path", isOptional: true, template: "folders" } },
    { name: ["--paginate", "-p"], isRepeatable: 3, exclusiveOn: ["--no-pager"] },
    { name: "--no-pager", exclusiveOn: ["--paginate"] },
    { name: "", description: "unnamed option is dropped" },
  ],
  subcommands: [
    {
      name: "add",
      description: "Add file contents to the index",
      args: { name: "pathspec", isVariadic: true, template: "filepaths", generators: fileGenerator },
      options: [
        { name: ["-A", "--all"], description: "Add all" },
        { name: ["-p", "--patch"], exclusiveOn: ["-A"] },
      ],
    },
    {
      name: ["checkout", "co"],
      description: "Switch branches or restore working tree files",
      args: {
        name: "branch",
        generators: [branchGenerator],
        suggestions: [
          "-",
          { name: "HEAD", description: "Current commit", icon: "🔖", priority: 100 },
          { name: "FETCH_HEAD", icon: "https://example.invalid/icon.png" },
          { name: ["ORIG_HEAD", "orig"], hidden: true, isDangerous: true },
          "",
          { description: "no name, dropped" },
        ],
      },
      options: [
        { name: ["-b"], args: { name: "new-branch", description: "Name of the new branch" } },
        { name: "--track", dependsOn: ["-b"] },
      ],
    },
    {
      name: "push",
      isDangerous: true,
      args: [
        { name: "remote", isOptional: true, generators: remoteGenerator },
        { name: "refspec", isOptional: true, isVariadic: true },
      ],
      options: [
        { name: ["-f", "--force"], isDangerous: true, description: "Force update" },
        { name: "--force-with-lease", requiresSeparator: "=", args: { name: "refname", isOptional: true } },
        { name: "--receive-pack", args: { name: "git-receive-pack", isRequired: true } },
      ],
    },
    { name: "lfs", description: "Git LFS", loadSpec: "git-lfs" },
    { name: "flow", description: "git-flow", loadSpec: () => ({ name: "flow" }) },
    {
      name: "worktree",
      loadSpec: {
        name: "worktree",
        description: "Manage multiple working trees",
        subcommands: [{ name: "add", args: { name: "path", template: "folders" } }, { name: "list" }],
      },
    },
    {
      name: "stash",
      requiresSubcommand: false,
      subcommands: [{ name: "pop" }, { name: "list", hidden: false }, { name: "" }],
      loadSpec: { name: "stash-inline", subcommands: [{ name: "push" }] },
    },
    { name: "  tag  ", args: { name: "tagname", isOptional: true, isCommand: false, generators: customGenerator } },
    { name: "bisect", requiresSubcommand: true, args: { name: "subcommand", suggestions: ["start", "good", "bad", ""] } },
    {
      name: "submodule",
      subcommands: [
        { name: "foreach", args: { name: "command", isCommand: true, isDangerous: true } },
        { name: "run-script", args: { name: "script", isScript: true } },
        { name: "nothing", args: {} },
      ],
    },
    { name: "unsafe\u0007name", description: "dropped: control character in name" },
    { name: "‮evil", description: "dropped: bidi override in name" },
  ],
};

export default completionSpec;
