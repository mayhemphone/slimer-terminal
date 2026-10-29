// Slimer starter spec (hand-written, not from withfig/autocomplete).
// The scripts generator mirrors the Fig corpus; Slimer reads package.json
// natively and never runs it.
const scripts = {
  script: ["bash", "-c", "until [[ -f package.json ]] || [[ $PWD = '/' ]]; do cd ..; done; cat package.json"],
  postProcess: (out) => Object.keys(JSON.parse(out).scripts ?? {}).map((name) => ({ name })),
};

const completionSpec = {
  name: "npm",
  description: "Node package manager",
  options: [
    { name: ["-v", "--version"], description: "Show the npm version" },
    { name: ["-h", "--help"], description: "Show help" },
  ],
  subcommands: [
    {
      name: ["run", "run-script"],
      description: "Run a package.json script",
      options: [
        { name: "--if-present", description: "Don't fail if the script is missing" },
        { name: ["-w", "--workspace"], description: "Run in a workspace", args: { name: "workspace" } },
        { name: "--silent", description: "Suppress npm output" },
      ],
      args: [{ name: "script", generators: scripts }, { name: "args", isOptional: true, isVariadic: true }],
    },
    {
      name: ["install", "i", "add"],
      description: "Install a package",
      options: [
        { name: ["-D", "--save-dev"], description: "Save to devDependencies" },
        { name: ["-E", "--save-exact"], description: "Save an exact version" },
        { name: ["-g", "--global"], description: "Install globally" },
        { name: "--no-save", description: "Don't save to package.json" },
        { name: "--legacy-peer-deps", description: "Ignore peer dependency conflicts" },
      ],
      args: { name: "package", isOptional: true, isVariadic: true },
    },
    { name: "ci", description: "Clean install from the lockfile", options: [{ name: "--omit", description: "Omit a dependency type", args: { name: "type", suggestions: ["dev", "optional", "peer"] } }] },
    { name: ["uninstall", "remove", "rm", "un"], description: "Remove a package", args: { name: "package", isVariadic: true } },
    { name: ["test", "t"], description: "Run the test script", args: { name: "args", isOptional: true, isVariadic: true } },
    { name: "start", description: "Run the start script" },
    { name: "build", description: "Build a package" },
    { name: ["update", "up"], description: "Update packages", args: { name: "package", isOptional: true, isVariadic: true } },
    { name: "outdated", description: "Check for outdated packages" },
    { name: ["list", "ls"], description: "List installed packages", options: [{ name: "--depth", description: "Max display depth", args: { name: "depth" } }] },
    { name: "init", description: "Create a package.json file", options: [{ name: ["-y", "--yes"], description: "Accept the defaults" }] },
    { name: "publish", description: "Publish a package", isDangerous: true, options: [{ name: "--dry-run", description: "Report what would be published" }, { name: "--tag", description: "Publish under a tag", args: { name: "tag" } }] },
    { name: "audit", description: "Run a security audit", subcommands: [{ name: "fix", description: "Apply fixes" }] },
    { name: "exec", description: "Run a command from a package", args: { name: "command", isCommand: true } },
    { name: "version", description: "Bump the package version", args: { name: "version", suggestions: ["patch", "minor", "major", "prerelease"] } },
    { name: "link", description: "Symlink a package folder" },
    { name: "pack", description: "Create a tarball from a package" },
  ],
};

export default completionSpec;
