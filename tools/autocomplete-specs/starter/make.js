// Slimer starter spec (hand-written, not from withfig/autocomplete).
// The targets generator mirrors the Fig corpus; Slimer scans the Makefile
// natively and never runs it.
const targets = {
  script: ["bash", "-c", "make -qp | awk -F':' '/^[a-zA-Z0-9][^$#\\/\\t=]*:([^=]|$)/ {split($1,A,/ /);for(i in A)print A[i]}' | sort -u"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((name) => ({ name })),
};

const completionSpec = {
  name: "make",
  description: "Maintain program dependencies",
  options: [
    { name: ["-C", "--directory"], description: "Change to a directory first", args: { name: "dir", template: "folders" } },
    { name: ["-f", "--file"], description: "Read this file as the makefile", args: { name: "file", template: "filepaths" } },
    { name: ["-j", "--jobs"], description: "Number of jobs to run simultaneously", args: { name: "jobs", isOptional: true } },
    { name: ["-k", "--keep-going"], description: "Keep going when some targets fail" },
    { name: ["-n", "--dry-run"], description: "Print the commands without running them" },
    { name: ["-B", "--always-make"], description: "Unconditionally make all targets" },
    { name: ["-s", "--silent"], description: "Don't echo recipes" },
  ],
  args: { name: "target", isOptional: true, isVariadic: true, generators: targets },
};

export default completionSpec;
