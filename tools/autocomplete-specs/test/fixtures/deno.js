// createVersionedSpec-style export: a function that shells out for the
// installed version and returns `{ versionedSpecPath, version }` instead of a
// spec. The converter cannot resolve this offline and records it as skipped.
const versionFiles = ["1.0.0", "1.20.0"];

export default async (executeShellCommand) => {
  const { stdout } = await executeShellCommand({ command: "deno", args: ["--version"] });
  const version = (stdout.split("\n")[0] || "").replace("deno ", "") || versionFiles[0];
  return { versionedSpecPath: `deno/${versionFiles[0]}`, version };
};
