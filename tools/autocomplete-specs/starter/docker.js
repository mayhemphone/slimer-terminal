// Slimer starter spec (hand-written, not from withfig/autocomplete).
// Container/image generators are left for the scripted tier.
const containers = {
  script: ["docker", "ps", "--format", "{{ json . }}"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((line) => ({ name: JSON.parse(line).Names })),
};
const images = {
  script: ["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((name) => ({ name })),
};

const composeFile = { name: ["-f", "--file"], description: "Compose configuration file", isPersistent: true, args: { name: "file", template: "filepaths" } };

const completionSpec = {
  name: "docker",
  description: "A self-sufficient runtime for containers",
  options: [
    { name: "--context", description: "Context to use", args: { name: "context" } },
    { name: ["-v", "--version"], description: "Print version information" },
    { name: "--help", description: "Show help" },
  ],
  subcommands: [
    {
      name: "ps",
      description: "List containers",
      options: [
        { name: ["-a", "--all"], description: "Show all containers" },
        { name: ["-q", "--quiet"], description: "Only display container IDs" },
        { name: "--format", description: "Format output with a Go template", args: { name: "format" } },
        { name: ["-f", "--filter"], description: "Filter output", args: { name: "filter" } },
      ],
    },
    {
      name: "run",
      description: "Create and run a new container from an image",
      options: [
        { name: ["-d", "--detach"], description: "Run in the background" },
        { name: ["-i", "--interactive"], description: "Keep STDIN open" },
        { name: ["-t", "--tty"], description: "Allocate a pseudo-TTY" },
        { name: "--rm", description: "Remove the container when it exits" },
        { name: "--name", description: "Assign a name", args: { name: "name" } },
        { name: ["-p", "--publish"], description: "Publish ports", isRepeatable: true, args: { name: "host:container" } },
        { name: ["-v", "--volume"], description: "Bind mount a volume", isRepeatable: true, args: { name: "volume" } },
        { name: ["-e", "--env"], description: "Set environment variables", isRepeatable: true, args: { name: "KEY=value" } },
        { name: "--env-file", description: "Read environment variables from a file", args: { name: "file", template: "filepaths" } },
        { name: ["-w", "--workdir"], description: "Working directory inside the container", args: { name: "dir" } },
        { name: "--network", description: "Connect to a network", args: { name: "network" } },
        { name: "--entrypoint", description: "Override the image entrypoint", args: { name: "command" } },
        { name: "--platform", description: "Set the platform", args: { name: "platform", suggestions: ["linux/amd64", "linux/arm64"] } },
        { name: "--privileged", description: "Give extended privileges", isDangerous: true },
      ],
      args: [{ name: "image", generators: images }, { name: "command", isOptional: true, isCommand: true }],
    },
    {
      name: "exec",
      description: "Run a command in a running container",
      options: [
        { name: ["-i", "--interactive"], description: "Keep STDIN open" },
        { name: ["-t", "--tty"], description: "Allocate a pseudo-TTY" },
        { name: ["-e", "--env"], description: "Set environment variables", isRepeatable: true, args: { name: "KEY=value" } },
        { name: ["-u", "--user"], description: "Username or UID", args: { name: "user" } },
        { name: ["-w", "--workdir"], description: "Working directory", args: { name: "dir" } },
      ],
      args: [{ name: "container", generators: containers }, { name: "command", isCommand: true }],
    },
    {
      name: "build",
      description: "Build an image from a Dockerfile",
      options: [
        { name: ["-t", "--tag"], description: "Name and optionally a tag", isRepeatable: true, args: { name: "name:tag" } },
        { name: ["-f", "--file"], description: "Name of the Dockerfile", args: { name: "file", template: "filepaths" } },
        { name: "--build-arg", description: "Set a build-time variable", isRepeatable: true, args: { name: "KEY=value" } },
        { name: "--no-cache", description: "Do not use cache" },
        { name: "--target", description: "Target build stage", args: { name: "stage" } },
        { name: "--platform", description: "Target platform", args: { name: "platform" } },
        { name: "--pull", description: "Always pull newer base images" },
      ],
      args: { name: "path", template: "folders", suggestions: [{ name: ".", description: "Current directory", priority: 80 }] },
    },
    {
      name: "images",
      description: "List images",
      options: [{ name: ["-a", "--all"], description: "Show all images" }, { name: ["-q", "--quiet"], description: "Only show image IDs" }],
    },
    { name: "pull", description: "Download an image from a registry", args: { name: "image" } },
    { name: "push", description: "Upload an image to a registry", args: { name: "image", generators: images } },
    { name: "logs", description: "Fetch the logs of a container", options: [{ name: ["-f", "--follow"], description: "Follow log output" }, { name: ["-n", "--tail"], description: "Number of lines", args: { name: "lines" } }], args: { name: "container", generators: containers } },
    { name: "stop", description: "Stop running containers", args: { name: "container", isVariadic: true, generators: containers } },
    { name: "start", description: "Start stopped containers", args: { name: "container", isVariadic: true, generators: containers } },
    { name: "restart", description: "Restart containers", args: { name: "container", isVariadic: true, generators: containers } },
    { name: "rm", description: "Remove containers", isDangerous: true, options: [{ name: ["-f", "--force"], description: "Force removal of running containers", isDangerous: true }], args: { name: "container", isVariadic: true, generators: containers } },
    { name: "rmi", description: "Remove images", isDangerous: true, args: { name: "image", isVariadic: true, generators: images } },
    {
      name: "compose",
      description: "Define and run multi-container applications",
      options: [composeFile, { name: ["-p", "--project-name"], description: "Project name", isPersistent: true, args: { name: "name" } }],
      subcommands: [
        { name: "up", description: "Create and start containers", options: [{ name: ["-d", "--detach"], description: "Run in the background" }, { name: "--build", description: "Build images before starting" }, { name: "--force-recreate", description: "Recreate containers" }, { name: "--remove-orphans", description: "Remove orphaned containers" }], args: { name: "service", isOptional: true, isVariadic: true } },
        { name: "down", description: "Stop and remove containers and networks", options: [{ name: ["-v", "--volumes"], description: "Remove named volumes", isDangerous: true }, { name: "--remove-orphans", description: "Remove orphaned containers" }, { name: "--rmi", description: "Remove images", args: { name: "type", suggestions: ["all", "local"] } }] },
        { name: "logs", description: "View output from containers", options: [{ name: ["-f", "--follow"], description: "Follow log output" }, { name: ["-n", "--tail"], description: "Number of lines", args: { name: "lines" } }], args: { name: "service", isOptional: true, isVariadic: true } },
        { name: "ps", description: "List containers" },
        { name: "build", description: "Build or rebuild services", args: { name: "service", isOptional: true, isVariadic: true } },
        { name: "exec", description: "Run a command in a running service", args: [{ name: "service" }, { name: "command", isCommand: true }] },
        { name: "restart", description: "Restart services", args: { name: "service", isOptional: true, isVariadic: true } },
        { name: "pull", description: "Pull service images" },
      ],
    },
    { name: "system", description: "Manage Docker", subcommands: [{ name: "prune", description: "Remove unused data", isDangerous: true, options: [{ name: ["-a", "--all"], description: "Remove all unused images" }, { name: "--volumes", description: "Prune volumes" }] }, { name: "df", description: "Show disk usage" }] },
    { name: "login", description: "Log in to a registry", args: { name: "server", isOptional: true } },
    { name: "inspect", description: "Return low-level information on objects", args: { name: "object", isVariadic: true, generators: containers } },
  ],
};

export default completionSpec;
