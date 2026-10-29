// Primary spec whose name is also listed as an alias by nvim.js; the primary wins.
export default {
  name: "vi",
  description: "Vi IMproved, a programmer's text editor",
  args: { name: "file", isVariadic: true, template: "filepaths" },
};
