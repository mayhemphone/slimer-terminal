// Slimer starter spec (hand-written, not from withfig/autocomplete).
const completionSpec = {
  name: "cd",
  description: "Change the working directory",
  args: {
    name: "directory",
    isOptional: true,
    template: "folders",
    suggestions: [
      { name: "-", description: "Previous directory", priority: 40 },
      { name: "~", description: "Home directory", priority: 40 },
    ],
  },
};

export default completionSpec;
