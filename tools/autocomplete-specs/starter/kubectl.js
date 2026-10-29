// Slimer starter spec (hand-written, not from withfig/autocomplete).
const contexts = {
  script: ["kubectl", "config", "get-contexts", "-o", "name"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((name) => ({ name })),
};

const resourceTypes = [
  "pods", "deployments", "services", "nodes", "namespaces", "configmaps", "secrets",
  "ingresses", "jobs", "cronjobs", "statefulsets", "daemonsets", "replicasets",
  "persistentvolumeclaims", "events", "all",
].map((name) => ({ name }));

const persistent = [
  { name: ["-n", "--namespace"], description: "Namespace scope for the request", isPersistent: true, args: { name: "namespace" } },
  { name: "--context", description: "Kubeconfig context to use", isPersistent: true, args: { name: "context", generators: contexts } },
  { name: ["-A", "--all-namespaces"], description: "List across all namespaces", isPersistent: true },
];

const output = { name: ["-o", "--output"], description: "Output format", args: { name: "format", suggestions: ["json", "yaml", "wide", "name"] } };
const selector = { name: ["-l", "--selector"], description: "Label selector", args: { name: "selector" } };
const file = { name: ["-f", "--filename"], description: "File or directory with the resources", isRepeatable: true, args: { name: "file", template: "filepaths" } };

const completionSpec = {
  name: "kubectl",
  description: "Kubernetes command-line tool",
  options: [...persistent, { name: "--help", description: "Show help" }],
  subcommands: [
    { name: "get", description: "Display one or many resources", options: [output, selector, { name: ["-w", "--watch"], description: "Watch for changes" }], args: [{ name: "type", suggestions: resourceTypes }, { name: "name", isOptional: true, isVariadic: true }] },
    { name: "describe", description: "Show details of a resource", options: [selector], args: [{ name: "type", suggestions: resourceTypes }, { name: "name", isOptional: true }] },
    { name: "logs", description: "Print the logs for a container", options: [{ name: ["-f", "--follow"], description: "Stream the logs" }, { name: ["-c", "--container"], description: "Container name", args: { name: "container" } }, { name: "--tail", description: "Lines of recent log", args: { name: "lines" } }, { name: ["-p", "--previous"], description: "Previous container instance" }], args: { name: "pod" } },
    { name: "apply", description: "Apply a configuration to a resource", options: [file, { name: ["-k", "--kustomize"], description: "Kustomization directory", args: { name: "dir", template: "folders" } }, { name: "--dry-run", description: "Only print the object", requiresSeparator: true, args: { name: "mode", suggestions: ["none", "client", "server"] } }] },
    { name: "delete", description: "Delete resources", isDangerous: true, options: [file, selector, { name: "--all", description: "Delete all resources of the type", isDangerous: true }, { name: "--force", description: "Immediately remove resources", isDangerous: true }], args: [{ name: "type", suggestions: resourceTypes }, { name: "name", isOptional: true, isVariadic: true }] },
    { name: "exec", description: "Execute a command in a container", options: [{ name: ["-i", "--stdin"], description: "Pass stdin" }, { name: ["-t", "--tty"], description: "Allocate a TTY" }, { name: ["-c", "--container"], description: "Container name", args: { name: "container" } }], args: [{ name: "pod" }, { name: "command", isCommand: true, isOptional: true }] },
    { name: "port-forward", description: "Forward local ports to a pod", args: [{ name: "pod" }, { name: "ports", isVariadic: true }] },
    { name: "rollout", description: "Manage the rollout of a resource", subcommands: [{ name: "status", description: "Show rollout status", args: { name: "resource" } }, { name: "restart", description: "Restart a resource", args: { name: "resource" } }, { name: "undo", description: "Undo a previous rollout", args: { name: "resource" } }, { name: "history", description: "View rollout history", args: { name: "resource" } }] },
    { name: "scale", description: "Set a new size for a deployment", options: [{ name: "--replicas", description: "New desired number of replicas", requiresSeparator: true, args: { name: "count" } }], args: { name: "resource" } },
    {
      name: "config",
      description: "Modify kubeconfig files",
      subcommands: [
        { name: "use-context", description: "Set the current context", args: { name: "context", generators: contexts } },
        { name: "current-context", description: "Display the current context" },
        { name: "get-contexts", description: "Describe one or many contexts" },
        { name: "set-context", description: "Set a context entry", options: [{ name: "--current", description: "Modify the current context" }, { name: "--namespace", description: "Namespace", requiresSeparator: true, args: { name: "namespace" } }], args: { name: "context", isOptional: true, generators: contexts } },
        { name: "view", description: "Display merged kubeconfig settings", options: [{ name: "--minify", description: "Only the current context" }] },
      ],
    },
    { name: "create", description: "Create a resource from a file or stdin", options: [file] },
    { name: "edit", description: "Edit a resource on the server", args: [{ name: "type", suggestions: resourceTypes }, { name: "name" }] },
    { name: "top", description: "Display resource usage", subcommands: [{ name: "pod", description: "Pod usage" }, { name: "node", description: "Node usage" }] },
  ],
};

export default completionSpec;
