import Foundation

/// A dot-separated numeric version, compared component by component.
/// Tolerant of a leading `v`/`V` and of a missing trailing component
/// (`"1.2"` equals `"1.2.0"`). Non-numeric components parse as `0`.
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]

    init(_ string: String) {
        var trimmed = string.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, first == "v" || first == "V" {
            trimmed.removeFirst()
        }
        components = trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }

    private func component(at index: Int) -> Int {
        index < components.count ? components[index] : 0
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let l = lhs.component(at: i)
            let r = rhs.component(at: i)
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count)
        where lhs.component(at: i) != rhs.component(at: i) {
            return false
        }
        return true
    }

    func isNewer(than other: AppVersion) -> Bool { self > other }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// The running app's version, from `CFBundleShortVersionString`.
    static var current: AppVersion {
        let string = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return AppVersion(string)
    }
}
