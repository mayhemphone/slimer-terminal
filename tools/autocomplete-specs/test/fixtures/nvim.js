// Aliases: `vim` becomes an alias of `nvim` in index.json; `vi` does not,
// because vi.js is a primary spec of its own.
const completionSpec = {
  name: ["nvim", "vim", "vi"],
  description: "Neovim",
  args: { name: "file", isVariadic: true, template: "filepaths" },
  options: [
    { name: "-u", description: "Use <vimrc> instead of the default", args: { name: "vimrc", template: "filepaths" } },
    { name: "--headless", description: "Don't start a user interface" },
  ],
};

export default completionSpec;
