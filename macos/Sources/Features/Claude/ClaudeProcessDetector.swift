import Darwin
import Foundation

/// Decides whether a surface's foreground process is Claude Code.
///
/// Called only when the surface title changes (throttled), never on a timer. One
/// check is a `proc_pidpath` call plus, for `node`/`bun` foreground processes, one
/// `KERN_PROCARGS2` sysctl: a few microseconds.
enum ClaudeProcessDetector {
    /// Pure matcher.
    ///
    /// - A native install: the executable is named `claude`, or lives in Claude
    ///   Code's versioned install directory (`~/.local/share/claude/versions/<v>`,
    ///   which `~/.local/bin/claude` links to).
    /// - An npm install: `node` (or `bun`) running a script whose path is named
    ///   `claude` or sits inside a `claude-code` package.
    static func isClaude(executablePath: String, arguments: [String]) -> Bool {
        let name = (executablePath as NSString).lastPathComponent
        if name == "claude" { return true }
        if executablePath.contains("/claude/versions/") { return true }
        guard name == "node" || name == "bun" else { return false }
        // arguments[0] is argv[0]; look at the script argument(s) that follow.
        for argument in arguments.dropFirst().prefix(4) where !argument.hasPrefix("-") {
            if (argument as NSString).lastPathComponent == "claude" { return true }
            if argument.contains("/@anthropic-ai/claude-code/") || argument.contains("/claude-code/cli") { return true }
            return false
        }
        return false
    }

    /// Whether `pid` is a Claude Code process.
    static func isClaude(pid: Int) -> Bool {
        guard pid > 0, let path = executablePath(pid: pid_t(pid)) else { return false }
        let name = (path as NSString).lastPathComponent
        let arguments = (name == "node" || name == "bun") ? (self.arguments(pid: pid_t(pid)) ?? []) : []
        return isClaude(executablePath: path, arguments: arguments)
    }

    static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// argv of `pid` via `KERN_PROCARGS2` (same-user processes only).
    static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Parse a `KERN_PROCARGS2` buffer: `argc` (Int32), the executable path,
    /// NUL padding, then `argc` NUL-terminated arguments.
    static func parseProcArgs(_ buffer: [UInt8]) -> [String]? {
        let intSize = MemoryLayout<Int32>.size
        guard buffer.count > intSize else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { raw in
            for index in 0..<intSize { raw[index] = buffer[index] }
        }
        guard argc > 0, argc < 4096 else { return nil }
        var index = intSize
        // Skip the executable path.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        // Skip NUL padding.
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(argc), index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(bytes: buffer[start..<index], encoding: .utf8) ?? "")
            index += 1
        }
        return arguments
    }
}
