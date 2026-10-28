// Made large on purpose: the minified JSON is well over the 512 KiB cap, so
// the converter must skip it and say why. Built in a loop to keep the fixture
// source small.
const subcommands = [];
for (let i = 0; i < 20000; i += 1) {
  subcommands.push({
    name: `subcommand-${i}`,
    description: `Generated subcommand number ${i} used to exceed the size cap`,
  });
}

export default {
  name: "huge",
  description: "A spec that is too large to ship",
  subcommands,
};
