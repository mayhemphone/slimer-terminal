// Function export: the module's default export is an async function that
// receives Fig's `executeShellCommand` and context and returns the spec. The
// converter calls it with inert stubs.
export default async function (executeShellCommand, context) {
  const { stdout } = await executeShellCommand({ command: "node", args: ["--version"] });
  const version = stdout.trim() || "unknown";
  const cwd = context && context.currentWorkingDirectory ? context.currentWorkingDirectory : "?";
  return {
    name: "node",
    description: `Node.js (${version}) in ${cwd}`,
    args: { name: "script", template: "filepaths", isOptional: true },
    options: [
      { name: ["-e", "--eval"], args: { name: "script" } },
      { name: ["-r", "--require"], args: { name: "module", template: "filepaths" } },
      { name: ["-v", "--version"] },
    ],
  };
}
