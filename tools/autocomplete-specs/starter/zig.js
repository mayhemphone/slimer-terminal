// Slimer starter spec (hand-written, not from withfig/autocomplete).
const optimize = { name: "-O", description: "Optimization mode", args: { name: "mode", suggestions: ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"] } };
const buildOptimize = { name: "--release", description: "Release mode", requiresSeparator: true, args: { name: "mode", isOptional: true, suggestions: ["fast", "safe", "small"] } };

const completionSpec = {
  name: "zig",
  description: "The Zig toolchain",
  subcommands: [
    {
      name: "build",
      description: "Build the project from build.zig",
      options: [
        buildOptimize,
        { name: "--summary", description: "Control the printing of the build summary", args: { name: "mode", suggestions: ["all", "new", "failures", "none"] } },
        { name: ["-j", "--jobs"], description: "Number of concurrent jobs" },
        { name: "--watch", description: "Rebuild on file changes" },
        { name: "--verbose", description: "Print commands before running them" },
        { name: ["-h", "--help"], description: "List steps and options" },
        { name: "-Doptimize", description: "Prioritize performance, safety, or size", requiresSeparator: true, args: { name: "mode", suggestions: ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"] } },
        { name: "-Dtarget", description: "CPU architecture, OS, and ABI to build for", requiresSeparator: true, args: { name: "triple" } },
      ],
      args: { name: "step", isOptional: true, isVariadic: true, suggestions: [{ name: "test", description: "Run tests" }, { name: "run", description: "Run the app" }, { name: "install", description: "Install artifacts (default)" }] },
    },
    { name: "test", description: "Run the tests in a source file", options: [optimize, { name: "--test-filter", description: "Only run tests matching text", args: { name: "text" } }], args: { name: "file", template: "filepaths" } },
    { name: "run", description: "Build and run a source file", options: [optimize], args: [{ name: "file", template: "filepaths" }, { name: "args", isOptional: true, isVariadic: true }] },
    { name: "fmt", description: "Reformat Zig source into canonical form", options: [{ name: "--check", description: "List non-conforming files and exit with an error" }, { name: "--stdin", description: "Format code from stdin" }, { name: "--ast-check", description: "Run zig ast-check on every file" }], args: { name: "file", isVariadic: true, template: ["filepaths", "folders"] } },
    { name: "build-exe", description: "Create an executable from source", options: [optimize], args: { name: "file", template: "filepaths" } },
    { name: "build-lib", description: "Create a library from source", options: [optimize], args: { name: "file", template: "filepaths" } },
    { name: "init", description: "Initialize a Zig package in the current directory" },
    { name: "fetch", description: "Copy a package into the global cache", options: [{ name: "--save", description: "Add the package to build.zig.zon" }], args: { name: "url" } },
    { name: "env", description: "Print lib path, std path, cache directory, and version" },
    { name: "version", description: "Print the version number" },
    { name: "translate-c", description: "Convert C code to Zig code", args: { name: "file", template: "filepaths" } },
    { name: "cc", description: "Use Zig as a drop-in C compiler", args: { name: "args", isVariadic: true, template: "filepaths" } },
  ],
};

export default completionSpec;
