// Slimer starter spec (hand-written, not from withfig/autocomplete).
const scripts = {
  script: ["bash", "-c", "until [[ -f package.json ]] || [[ $PWD = '/' ]]; do cd ..; done; cat package.json"],
  postProcess: (out) => Object.keys(JSON.parse(out).scripts ?? {}).map((name) => ({ name })),
};

const completionSpec = {
  name: "yarn",
  description: "Yarn package manager",
  options: [
    { name: ["-v", "--version"], description: "Show the yarn version" },
    { name: ["-h", "--help"], description: "Show help" },
  ],
  args: { name: "script", isOptional: true, generators: scripts },
  subcommands: [
    { name: "run", description: "Run a package.json script", args: [{ name: "script", generators: scripts }, { name: "args", isOptional: true, isVariadic: true }] },
    { name: "install", description: "Install all dependencies", options: [{ name: "--frozen-lockfile", description: "Don't update the lockfile" }, { name: "--immutable", description: "Abort if the lockfile would change" }] },
    {
      name: "add",
      description: "Install a package",
      options: [
        { name: ["-D", "--dev"], description: "Save to devDependencies" },
        { name: ["-E", "--exact"], description: "Save an exact version" },
        { name: ["-P", "--peer"], description: "Save to peerDependencies" },
      ],
      args: { name: "package", isVariadic: true },
    },
    { name: "remove", description: "Remove a package", args: { name: "package", isVariadic: true } },
    { name: ["upgrade", "up"], description: "Upgrade packages", args: { name: "package", isOptional: true, isVariadic: true } },
    { name: "test", description: "Run the test script" },
    { name: "start", description: "Run the start script" },
    { name: "dlx", description: "Run a package without installing it", args: { name: "package" } },
    { name: "exec", description: "Run a shell command in the project", args: { name: "command", isCommand: true } },
    { name: "workspace", description: "Run a command in a workspace", args: [{ name: "workspace" }, { name: "command", isCommand: true }] },
    { name: "why", description: "Show why a package is installed", args: { name: "package" } },
    { name: "outdated", description: "Check for outdated packages" },
    { name: "publish", description: "Publish a package", isDangerous: true },
  ],
};

export default completionSpec;
