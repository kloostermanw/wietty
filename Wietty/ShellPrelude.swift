import Foundation

/// Composes a `shell_init` prelude and a command into one shell script, so the
/// prelude's `export`s and `source`s run in the same shell as the command and
/// are visible to it. Pure: no I/O, no app state.
///
/// Non-blank lines are emitted verbatim and unquoted, because being shell code is
/// the point: that is what makes `$HOME`, `$PATH`, and `source` work where the
/// literal `env` map cannot. Whitespace-only entries are dropped so a stray `""`
/// does not leave an empty statement in the script.
///
/// Lines are newline separated rather than `&&` chained, so a line that fails
/// does not by itself abort the script. Whether it aborts is the shell's call,
/// not this type's: under `zsh` and `bash` a failed `source` prints and carries
/// on, while a POSIX `sh` aborts on a failed `.`. A prelude line that runs
/// `exit`, or `set -e` ahead of a line that then fails, skips the command.
enum ShellPrelude {
    static func script(lines: [String], command: String) -> String {
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !kept.isEmpty else { return command }
        return (kept + [command]).joined(separator: "\n")
    }

    /// The effective prelude for one process or test: the workspace-wide lines
    /// first, then the definition's own. Appending rather than replacing is what
    /// lets a shared `PATH` stay in effect while one definition layers something
    /// on top. Lives here so both supervisors share one implementation of the
    /// ordering rule instead of spelling it out twice.
    static func merge(global: [String], local: [String]) -> [String] {
        global + local
    }
}
