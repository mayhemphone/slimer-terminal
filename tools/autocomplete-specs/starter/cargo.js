// Slimer starter spec (hand-written, not from withfig/autocomplete).
const common = [
  { name: ["-p", "--package"], description: "Package to operate on", args: { name: "spec" } },
  { name: "--release", description: "Build with the release profile" },
  { name: ["-F", "--features"], description: "Features to activate", args: { name: "features" } },
  { name: "--all-features", description: "Activate all features" },
  { name: "--workspace", description: "Operate on every workspace member" },
  { name: "--target", description: "Build for the target triple", args: { name: "triple" } },
];

const completionSpec = {
  name: "cargo",
  description: "Rust's package manager",
  options: [
    { name: ["-V", "--version"], description: "Print version info" },
    { name: ["-h", "--help"], description: "Show help" },
    { name: ["-v", "--verbose"], description: "Verbose output", isPersistent: true },
    { name: ["-q", "--quiet"], description: "No output", isPersistent: true },
  ],
  subcommands: [
    { name: ["build", "b"], description: "Compile the current package", options: common },
    { name: ["check", "c"], description: "Check the package for errors", options: common },
    { name: ["run", "r"], description: "Run a binary or example", options: [...common, { name: "--bin", description: "Binary to run", args: { name: "name" } }, { name: "--example", description: "Example to run", args: { name: "name" } }], args: { name: "args", isOptional: true, isVariadic: true } },
    { name: ["test", "t"], description: "Run the tests", options: [...common, { name: "--no-run", description: "Compile but don't run" }, { name: "--doc", description: "Test only the docs" }], args: { name: "testname", isOptional: true } },
    { name: "bench", description: "Run the benchmarks", options: common },
    { name: "clippy", description: "Run the Clippy linter", options: [...common, { name: "--fix", description: "Apply suggestions" }] },
    { name: "fmt", description: "Format the code", options: [{ name: "--check", description: "Check formatting without writing" }, { name: "--all", description: "Format all packages" }] },
    { name: "doc", description: "Build documentation", options: [...common, { name: "--open", description: "Open the docs in a browser" }, { name: "--no-deps", description: "Don't document dependencies" }] },
    { name: "new", description: "Create a new package", options: [{ name: "--lib", description: "Library template" }, { name: "--bin", description: "Binary template" }], args: { name: "path", template: "folders" } },
    { name: "init", description: "Create a package in an existing directory", options: [{ name: "--lib", description: "Library template" }], args: { name: "path", isOptional: true, template: "folders" } },
    { name: "add", description: "Add dependencies", options: [{ name: "--dev", description: "Add as a dev dependency" }, { name: ["-F", "--features"], description: "Features to activate", args: { name: "features" } }], args: { name: "dependency", isVariadic: true } },
    { name: ["remove", "rm"], description: "Remove dependencies", args: { name: "dependency", isVariadic: true } },
    { name: "update", description: "Update the lockfile", args: { name: "spec", isOptional: true } },
    { name: "clean", description: "Remove the target directory" },
    { name: "install", description: "Install a Rust binary", args: { name: "crate" } },
    { name: "publish", description: "Upload a package to the registry", isDangerous: true, options: [{ name: "--dry-run", description: "Perform all checks without uploading" }] },
    { name: "tree", description: "Display the dependency tree" },
  ],
};

export default completionSpec;
