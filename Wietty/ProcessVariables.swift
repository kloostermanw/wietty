import Foundation

/// Variables Wietty exposes to process commands as environment variables.
///
/// Values are injected into the process environment under the `WIETTY_`
/// prefix and referenced in `command`/`stop`/`status` with normal shell syntax
/// (`$WIETTY_BRANCH` or `${WIETTY_BRANCH}`). Expansion is done by the
/// login shell, so it applies only to those shell-run strings, not to literal
/// `env` map values.
enum ProcessVariables {
    static let prefix = "WIETTY_"

    /// Names of `WIETTY_*` variables referenced in `command` that are not in
    /// `available`. A reference to an unknown or unset variable (which the shell
    /// would silently expand to empty) counts as unresolved, so a typo or a
    /// git-derived value that isn't ready yet is caught rather than run blind.
    /// Returns unique names sorted for stable messaging.
    static func unresolved(in command: String, available: [String: String]) -> [String] {
        var names: Set<String> = []
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            guard chars[i] == "$" else { i += 1; continue }
            var j = i + 1
            let braced = j < chars.count && chars[j] == "{"
            if braced { j += 1 }
            let start = j
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                j += 1
            }
            let name = String(chars[start..<j])
            // A braced reference must actually close with `}` to be a reference.
            let closed = !braced || (j < chars.count && chars[j] == "}")
            if closed, name.hasPrefix(prefix), available[name] == nil {
                names.insert(name)
            }
            i = braced && closed ? j + 1 : j
        }
        return names.sorted()
    }
}
