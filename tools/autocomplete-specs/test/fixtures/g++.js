// Valid spec whose filename cannot be sanitized to [a-z0-9._-]: skipped.
export default {
  name: "g++",
  description: "GNU C++ compiler",
  args: { name: "file", isVariadic: true, template: "filepaths" },
};
