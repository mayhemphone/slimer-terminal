// Slimer starter spec (hand-written, not from withfig/autocomplete).
const repoOpt = { name: ["-R", "--repo"], description: "Select another repository", isPersistent: true, args: { name: "owner/repo" } };
const web = { name: ["-w", "--web"], description: "Open in the browser" };
const state = { name: ["-s", "--state"], description: "Filter by state", args: { name: "state", suggestions: ["open", "closed", "merged", "all"] } };
const limit = { name: ["-L", "--limit"], description: "Maximum number of items", args: { name: "number" } };

const completionSpec = {
  name: "gh",
  description: "GitHub CLI",
  options: [{ name: "--help", description: "Show help" }, { name: "--version", description: "Show the gh version" }],
  subcommands: [
    {
      name: "pr",
      description: "Manage pull requests",
      options: [repoOpt],
      subcommands: [
        { name: "create", description: "Create a pull request", options: [{ name: ["-t", "--title"], description: "Title", args: { name: "title" } }, { name: ["-b", "--body"], description: "Body", args: { name: "body" } }, { name: ["-B", "--base"], description: "Base branch", args: { name: "branch" } }, { name: ["-d", "--draft"], description: "Mark as draft" }, { name: ["-f", "--fill"], description: "Use commit info for title and body" }, web] },
        { name: ["list", "ls"], description: "List pull requests", options: [state, limit, { name: ["-a", "--assignee"], description: "Filter by assignee", args: { name: "login" } }, { name: "--author", description: "Filter by author", args: { name: "login" } }, web] },
        { name: "view", description: "View a pull request", options: [web, { name: ["-c", "--comments"], description: "View comments" }], args: { name: "number", isOptional: true } },
        { name: ["checkout", "co"], description: "Check out a pull request", args: { name: "number" } },
        { name: "status", description: "Show status of relevant pull requests" },
        { name: "diff", description: "View changes in a pull request", args: { name: "number", isOptional: true } },
        { name: "checks", description: "Show CI status", options: [{ name: "--watch", description: "Watch until checks finish" }], args: { name: "number", isOptional: true } },
        { name: "merge", description: "Merge a pull request", options: [{ name: ["-m", "--merge"], description: "Merge commit" }, { name: ["-s", "--squash"], description: "Squash and merge" }, { name: ["-r", "--rebase"], description: "Rebase and merge" }, { name: ["-d", "--delete-branch"], description: "Delete the branch after merging" }, { name: "--auto", description: "Merge when requirements are met" }], args: { name: "number", isOptional: true } },
        { name: "review", description: "Add a review", options: [{ name: ["-a", "--approve"], description: "Approve" }, { name: ["-r", "--request-changes"], description: "Request changes" }, { name: ["-c", "--comment"], description: "Comment" }, { name: ["-b", "--body"], description: "Body", args: { name: "body" } }], args: { name: "number", isOptional: true } },
        { name: "close", description: "Close a pull request", isDangerous: true, args: { name: "number" } },
        { name: "reopen", description: "Reopen a pull request", args: { name: "number" } },
        { name: "ready", description: "Mark a pull request as ready for review", args: { name: "number", isOptional: true } },
        { name: "comment", description: "Add a comment", options: [{ name: ["-b", "--body"], description: "Body", args: { name: "body" } }], args: { name: "number", isOptional: true } },
        { name: "edit", description: "Edit a pull request", args: { name: "number", isOptional: true } },
      ],
    },
    {
      name: "issue",
      description: "Manage issues",
      options: [repoOpt],
      subcommands: [
        { name: "create", description: "Create an issue", options: [{ name: ["-t", "--title"], description: "Title", args: { name: "title" } }, { name: ["-b", "--body"], description: "Body", args: { name: "body" } }, { name: ["-l", "--label"], description: "Add labels", args: { name: "name" } }, { name: ["-a", "--assignee"], description: "Assign people", args: { name: "login" } }, web] },
        { name: ["list", "ls"], description: "List issues", options: [state, limit, { name: ["-l", "--label"], description: "Filter by label", args: { name: "label" } }, { name: ["-a", "--assignee"], description: "Filter by assignee", args: { name: "login" } }, web] },
        { name: "view", description: "View an issue", options: [web, { name: ["-c", "--comments"], description: "View comments" }], args: { name: "number" } },
        { name: "status", description: "Show status of relevant issues" },
        { name: "close", description: "Close an issue", args: { name: "number" } },
        { name: "reopen", description: "Reopen an issue", args: { name: "number" } },
        { name: "comment", description: "Add a comment", options: [{ name: ["-b", "--body"], description: "Body", args: { name: "body" } }], args: { name: "number" } },
        { name: "edit", description: "Edit an issue", args: { name: "number" } },
        { name: "delete", description: "Delete an issue", isDangerous: true, args: { name: "number" } },
      ],
    },
    {
      name: "repo",
      description: "Manage repositories",
      subcommands: [
        { name: "clone", description: "Clone a repository locally", args: [{ name: "repository" }, { name: "directory", isOptional: true, template: "folders" }] },
        { name: "create", description: "Create a new repository", options: [{ name: "--public", description: "Make the repository public" }, { name: "--private", description: "Make the repository private" }, { name: ["-s", "--source"], description: "Path to a local repository", args: { name: "path", template: "folders" } }, { name: "--push", description: "Push local commits" }], args: { name: "name", isOptional: true } },
        { name: "view", description: "View a repository", options: [web], args: { name: "repository", isOptional: true } },
        { name: "fork", description: "Create a fork", options: [{ name: "--clone", description: "Clone the fork" }], args: { name: "repository", isOptional: true } },
        { name: ["list", "ls"], description: "List repositories", options: [limit], args: { name: "owner", isOptional: true } },
        { name: "sync", description: "Sync a repository", args: { name: "repository", isOptional: true } },
        { name: "delete", description: "Delete a repository", isDangerous: true, args: { name: "repository", isOptional: true } },
        { name: "edit", description: "Edit repository settings", args: { name: "repository", isOptional: true } },
      ],
    },
    { name: "auth", description: "Authenticate gh and git with GitHub", subcommands: [{ name: "login", description: "Log in" }, { name: "logout", description: "Log out" }, { name: "status", description: "View authentication status" }, { name: "refresh", description: "Refresh credentials" }] },
    { name: "run", description: "View workflow runs", subcommands: [{ name: ["list", "ls"], description: "List recent runs" }, { name: "view", description: "View a run", args: { name: "run-id", isOptional: true } }, { name: "watch", description: "Watch a run until it completes", args: { name: "run-id", isOptional: true } }, { name: "rerun", description: "Rerun a run", args: { name: "run-id", isOptional: true } }] },
    { name: "workflow", description: "View details about workflows", subcommands: [{ name: ["list", "ls"], description: "List workflows" }, { name: "run", description: "Run a workflow", args: { name: "workflow" } }, { name: "view", description: "View a workflow", args: { name: "workflow", isOptional: true } }] },
    { name: "browse", description: "Open the repository in the browser", args: { name: "location", isOptional: true } },
    { name: "api", description: "Make an authenticated GitHub API request", args: { name: "endpoint" } },
  ],
};

export default completionSpec;
