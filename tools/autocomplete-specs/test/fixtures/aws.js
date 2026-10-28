// Valid spec, but `aws` is on the skip list: never emitted, recorded in index.json.
export default {
  name: "aws",
  description: "Unified tool to manage your AWS services",
  subcommands: [{ name: "s3", loadSpec: "aws/s3" }],
};
