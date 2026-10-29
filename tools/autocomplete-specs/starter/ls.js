// Slimer starter spec (hand-written, not from withfig/autocomplete).
const completionSpec = {
  name: "ls",
  description: "List directory contents",
  options: [
    { name: "-a", description: "Include entries whose names begin with a dot" },
    { name: "-A", description: "Like -a, but omit . and .." },
    { name: "-l", description: "Long format" },
    { name: "-h", description: "Human-readable sizes with -l" },
    { name: "-t", description: "Sort by modification time" },
    { name: "-r", description: "Reverse the sort order" },
    { name: "-S", description: "Sort by size" },
    { name: "-R", description: "List subdirectories recursively" },
    { name: "-1", description: "One entry per line" },
    { name: "-d", description: "List directories themselves, not their contents" },
    { name: "-F", description: "Append an indicator to entries" },
    { name: "-G", description: "Colorized output" },
    { name: "--color", description: "Colorize the output", requiresSeparator: true, args: { name: "when", isOptional: true, suggestions: ["always", "auto", "never"] } },
  ],
  args: { name: "file", isOptional: true, isVariadic: true, template: ["filepaths", "folders"] },
};

export default completionSpec;
