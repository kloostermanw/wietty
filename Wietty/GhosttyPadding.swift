import Foundation

/// The window padding a Ghostty configuration sets, in points per side.
///
/// Read from the configuration files rather than from libghostty, because
/// libghostty will not say: `ghostty_config_get` answers false for
/// `window-padding-x` and `window-padding-y` and writes nothing (measured on the
/// pinned 1.3.2, against a file that set both). It answers for
/// `window-padding-balance`, which does not matter here: balancing hands the pixels
/// left over beyond whole cells to the padding after the grid has been derived from
/// the configured padding, so it changes where the cells are drawn and not how many
/// a size holds. The imposed grid check runs one configuration with it on.
///
/// The padding is what `SurfaceMetrics` needs to give a view the size of a grid,
/// and only the configured value is exact: the pixels a surface has left over beyond
/// its cells are the padding plus up to a cell of slack.
struct GhosttyPadding: Equatable {
    var left: Int, right: Int, top: Int, bottom: Int

    /// Ghostty's own default, 2 points on every side.
    static let ghosttyDefault = GhosttyPadding(left: 2, right: 2, top: 2, bottom: 2)

    /// Both sides together, in pixels at `scale`, as libghostty derives them: each
    /// side is its points times the scale rounded down, on its own. For the integer
    /// scales macOS uses that is simply twice the points times the scale.
    func pixels(scale: Double) -> (x: Int, y: Int) {
        func side(_ points: Int) -> Int { Int((Double(points) * scale).rounded(.down)) }
        return (side(left) + side(right), side(top) + side(bottom))
    }

    /// The padding a configuration made of `files`, loaded in this order, resolves
    /// to. A file that does not exist sets nothing, as it does for libghostty.
    static func resolve(files: [URL]) -> GhosttyPadding {
        var padding = ghosttyDefault
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                padding.apply(line: String(line))
            }
        }
        return padding
    }

    /// The padding the host's own configuration resolves to: the files
    /// `ghostty_config_load_default_files` reads, then Wietty's overlay, which is
    /// what `GhosttySurfaceHost.buildConfig` loads.
    static func resolveHostConfiguration() -> GhosttyPadding {
        resolve(files: defaultFiles() + [GhosttyOverrideFile.defaultURL])
    }

    /// The files libghostty's `loadDefaultFiles` reads on macOS, in its order: the
    /// XDG directory's legacy `config` and then `config.ghostty`, then the same two
    /// in Application Support (libghostty warns when both of a pair exist and loads
    /// both, in that order). `config-file` includes are not followed, because the
    /// host does not call `ghostty_config_load_recursive_files` either.
    static func defaultFiles(environment: [String: String] = ProcessInfo.processInfo.environment,
                             home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let ghostty = xdg.appendingPathComponent("ghostty")
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [ghostty.appendingPathComponent("config"), ghostty.appendingPathComponent("config.ghostty"),
                support.appendingPathComponent("config"), support.appendingPathComponent("config.ghostty")]
    }

    /// One line of a Ghostty configuration file. Only the two padding keys are
    /// read; everything else is libghostty's business.
    ///
    /// The value is one number for both sides or two separated by a comma (left and
    /// right, or top and bottom), whole points. An empty value puts the key back to
    /// its default, as it does in Ghostty. A value Ghostty would reject leaves the
    /// key as it was, which is what a rejected line does to libghostty's own value.
    mutating func apply(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard key == "window-padding-x" || key == "window-padding-y" else { return }
        let pair: (Int, Int)
        if value.isEmpty {
            pair = (2, 2)
        } else {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { UInt32($0.trimmingCharacters(in: .whitespaces)).map(Int.init) }
            switch parts.count {
            case 1: guard let one = parts[0] else { return }; pair = (one, one)
            case 2: guard let first = parts[0], let second = parts[1] else { return }; pair = (first, second)
            default: return
            }
        }
        if key == "window-padding-x" { (left, right) = pair } else { (top, bottom) = pair }
    }
}

/// What a surface's own reports prove about its true padding on one axis, gathered
/// across observations.
///
/// Each report of a surface of more than one cell says the pixels beyond its whole
/// cells, `remainder = pixels - cells * cell`, and the true padding always lies in
/// `[remainder - cell + 1, remainder]`. Every such window holds it, so their
/// intersection narrows as the view takes other sizes: `upper` is the smallest
/// remainder seen and `lower` the largest `remainder - cell + 1`.
///
/// The configured padding is used only while it lies inside. Otherwise `upper`,
/// which is never below the true padding: a size computed with it can be up to a
/// cell less a pixel too large, which still shows exactly the grid, and a grid
/// derived from a pane with it can be one column short but never one too many,
/// so the pane never claims more than it can show. A configured value below the
/// true padding by less than a cell can pass a single window; it is caught as soon
/// as another size narrows the bounds above it, and the closed loop in
/// `GhosttySurfaceView` catches it when it makes an imposed grid come out wrong.
///
/// Starts over when the cell size, the scale or the configuration changes, since
/// the true padding may have moved with them.
struct PaddingWindow: Equatable {
    private(set) var lower = 0
    private(set) var upper = Int.max

    /// Narrows the bounds by one report. A surface of a single cell may have been
    /// clamped up to it, and proves nothing.
    mutating func observe(pixels: Int, cells: Int, cell: Int) {
        guard cells > 1, cell > 0 else { return }
        let remainder = pixels - cells * cell
        guard remainder >= 0 else { return }
        upper = min(upper, remainder)
        lower = max(lower, remainder - cell + 1)
    }

    /// The padding to use: `configured` while the reports allow it, else `upper`.
    func padding(configured: Int) -> Int {
        guard upper != Int.max else { return configured }
        guard lower <= upper else { return upper }
        return (lower...upper).contains(configured) ? configured : upper
    }
}

/// How often the closed loop in `GhosttySurfaceView` may still size an imposed grid
/// again: `limit` times, whole again for every new grid imposed and for every new
/// metrics key (the cell size, the scale and the host's configuration generation,
/// which is what the configured padding is read with).
///
/// Bounded, so a surface that will not settle cannot loop. Whole again on a new key
/// because the padding the loop corrected for may have moved with the cell size, the
/// scale or the configuration: a surface that spent its budget at one scale would
/// otherwise keep a wrong size at the next. The key leaves out the padding the
/// surface's own reports narrow (`PaddingWindow`), since each correction moves that.
struct ImposedSizeCorrections: Equatable {
    static let limit = 2
    private(set) var used = 0
    private var key: [Double]?

    /// A new grid was imposed.
    mutating func gridImposed() { used = 0 }

    /// The metrics were taken for `key`; a key other than the last makes the budget
    /// whole again.
    mutating func metricsTaken(key: [Double]) {
        guard key != self.key else { return }
        self.key = key
        used = 0
    }

    /// Spends one correction, if one is left.
    mutating func take() -> Bool {
        guard used < Self.limit else { return false }
        used += 1
        return true
    }
}
