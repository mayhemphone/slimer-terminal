// Nested spec (the target of `loadSpec: "docker/compose"`): emitted at
// specs/docker/compose.json, counted, but never a source of aliases.
export default {
  name: ["compose", "docker-compose"],
  description: "Define and run multi-container applications",
  subcommands: [
    { name: "up", description: "Create and start containers", options: [{ name: ["-d", "--detach"] }] },
    { name: "down", description: "Stop and remove containers, networks", isDangerous: true },
  ],
  options: [{ name: ["-f", "--file"], isRepeatable: true, args: { name: "file", template: "filepaths" } }],
};
