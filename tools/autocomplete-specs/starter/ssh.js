// Slimer starter spec (hand-written, not from withfig/autocomplete).
const completionSpec = {
  name: "ssh",
  description: "OpenSSH remote login client",
  options: [
    { name: "-p", description: "Port to connect to", args: { name: "port" } },
    { name: "-i", description: "Identity (private key) file", args: { name: "file", template: "filepaths" } },
    { name: "-l", description: "Login name", args: { name: "user" } },
    { name: "-L", description: "Local port forwarding", isRepeatable: true, args: { name: "port:host:hostport" } },
    { name: "-R", description: "Remote port forwarding", isRepeatable: true, args: { name: "port:host:hostport" } },
    { name: "-D", description: "Dynamic SOCKS forwarding", args: { name: "port" } },
    { name: "-J", description: "Jump host", args: { name: "destination" } },
    { name: "-o", description: "Set a configuration option", isRepeatable: true, args: { name: "option" } },
    { name: "-F", description: "Alternative config file", args: { name: "file", template: "filepaths" } },
    { name: "-A", description: "Enable agent forwarding" },
    { name: "-N", description: "Do not execute a remote command" },
    { name: "-T", description: "Disable pseudo-terminal allocation" },
    { name: "-t", description: "Force pseudo-terminal allocation" },
    { name: "-v", description: "Verbose mode", isRepeatable: 3 },
    { name: "-q", description: "Quiet mode" },
    { name: "-C", description: "Compress all data" },
  ],
  args: [{ name: "destination" }, { name: "command", isOptional: true, isCommand: true }],
};

export default completionSpec;
