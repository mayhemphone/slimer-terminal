// versionedSpec-style export: an object carrying a base `completionSpec` plus
// a version diff map. The converter takes the base spec and ignores `versions`
// (version diffs need runtime version detection, which is out of scope).
const completionSpec = {
  name: "yarn",
  description: "Manage packages and run scripts",
  subcommands: [
    {
      name: "add",
      description: "Installs a package and any packages that it depends on",
      args: { name: "package", isVariadic: true },
      options: [
        { name: ["-D", "--dev"], description: "Install as a devDependency" },
        { name: ["-E", "--exact"], description: "Install exact version" },
      ],
    },
    {
      name: "run",
      description: "Runs a defined package script",
      args: {
        name: "script",
        generators: {
          script: ["cat", "package.json"],
          postProcess: (out) => Object.keys(JSON.parse(out).scripts || {}).map((name) => ({ name })),
          cache: { cacheByDirectory: true },
        },
      },
    },
  ],
  options: [{ name: ["-v", "--version"], description: "Output the version number" }],
};

const versions = {
  "1.0.0": {},
  "2.0.0": { subcommands: [{ name: "dlx", description: "Run a package in a temporary environment" }] },
};

export default { completionSpec, versions };
