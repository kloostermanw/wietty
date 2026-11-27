import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import WiettyCore
@testable import WiettyShared
@testable import Wietty

/// Measurements for phase 3 step 5 of issue #84, a terminal on another Mac shown in a
/// libghostty surface: the surface's `wietty-pty` connects to a `TerminalBridge`, whose
/// link (`RemoteSocketLink`) wraps the package's `TerminalStreamConnection` over a
/// WebSocket to a `RemoteServer`, and the surface is made on every show and destroyed on
/// every hide.
///
/// A measurement, not a test: it asserts only what it needs to stay meaningful, and
/// prints lines starting with `STEP5`. Every measurement runs three times.
///
/// - R1: a snapshot (hard reset, history, screen, modes) fed through the real bridge and
///   helper to a real surface left dirty by its child, compared with the same snapshot
///   on a clean surface and with the libghostty-vt model that produced it; also with the
///   model on the alternate screen (then leaving it, and the fresh snapshot after), and
///   with the model at a grid other than the surface's, imposed on a viewer surface by
///   the product's `OwnPaneGrid`, in the product's order and with the grid settled first.
/// - RECONNECT: through `RemotePanes` as the app builds them, a surface the program left
///   dirty, the server dropped and back on the same port, the pane's own new link on
///   the same surface, and the surface compared with the server's terminal (same grid
///   and a smaller one, entering and leaving the alternate screen).
/// - R2: a real `RemoteServer` on 127.0.0.1 flooding one `TerminalStreamConnection`
///   whose callback is fast, slow (50 ms per message) or stalled: this process's
///   memory, the sockets' queues and the server's resyncs over time.
/// - R3: the cost of a show through `RemotePanes.open` (the turn the pane waits, surface,
///   helper, WebSocket, snapshot) for 1,000, 10,000 and 100,000 lines of history, the
///   hide through `RemotePanes.close`, and what 100 shows and hides leave behind.
/// - R4: the largest snapshots through the helper's 4 KiB pump: the blocking write and
///   the longest gap of a main queue heartbeat meanwhile.
/// - R7: what the surface shows and does when the bridge stops after the session ended,
///   and when it is kept with no link.
/// - R8: 50 destroy and create cycles, with an id per creation, the create in the
///   destroy's main turn (with and without the host's drain on destroy) or on the next
///   turn, own surfaces after own ones and after viewers: which late titles,
///   backgrounds (`OSC 11`) and clipboard writes (`OSC 52`) of an old surface reach
///   its successor.
/// - PANE: `RemoteSurfacePane` in a window over `RemotePanes` as the app builds them: a
///   show, a hide and a second show, a user action, the server stopped and back on the
///   same port, a change of session, the session ended on the server and the last hide,
///   with the state, the claims and where the surface's container sits at each step.
///
/// **Not part of the normal suite.** It needs a window, a Metal device and minutes. It
/// runs only with `WIETTY_REMOTE_SURFACE_CHECK=1` in the test host's environment; see
/// `scripts/remote-surface-check.sh`. Like the other real window checks it builds a
/// `GhosttySurfaceHost` of its own beside the app's, which takes the host callbacks over
/// for the run. The scripted link below lives in the test target only; the link to the
/// server is the product's `RemoteSocketLink`, timed by a thin wrapper, and R3, RECONNECT
/// and PANE go through the product's `RemotePane`.
@MainActor
@Suite(.enabled(if: RemoteSurfaceCheck.isRequested), .serialized)
struct RemoteSurfaceMeasurementTests {
    nonisolated static let runs = 3

    // MARK: R1. A snapshot on a dirty surface

    @Test func r1ASnapshotOnADirtySurface() async throws {
        let rig = try await SurfaceRig.make(width: 1000, height: 700, container: false)
        defer { rig.close() }
        for run in 1...Self.runs {
            for variant in R1Variant.allCases {
                var results: [R1Result] = []
                for dirty in [false, true] {
                    results.append(try await r1(rig, run: run, variant: variant, dirty: dirty))
                }
                let clean = results[0], dirty = results[1]
                let same = clean.answers == dirty.answers && clean.keys == dirty.keys
                    && clean.whole == dirty.whole && clean.viewport == dirty.viewport
                report("""
                    STEP5 R1 run=\(run) model=\(variant.rawValue) compare clean-vs-dirty \
                    identical=\(same ? "yes" : "NO") answers=\(clean.answers == dirty.answers ? "same" : "DIFF") \
                    keys=\(clean.keys == dirty.keys ? "same" : "DIFF") \
                    history=\(clean.whole == dirty.whole ? "same" : "DIFF") \
                    viewport=\(clean.viewport == dirty.viewport ? "same" : "DIFF")
                    """)
                #expect(same)
            }
        }
    }

    /// R1 with the model at a grid other than the surface's, smaller and larger: the
    /// snapshot of a reconnect after another viewer changed the grid, and of every show
    /// whose pane is not the grid's size. The surface is a `RemotePane`'s, opened through
    /// `RemotePanes` (the product path: its `ObservedLink` holds the snapshot until the
    /// surface has the grid its `OwnPaneGrid` imposed). Clean and dirty are compared as
    /// in R1, once the surface has taken the model's grid; each case runs with the
    /// messages sent as the server sends them, and with the test also waiting for the
    /// grid before it sends the snapshot (`settled-first`).
    @Test func r1ASnapshotAtAnotherGrid() async throws {
        let rig = try await SurfaceRig.make(width: 1000, height: 700, container: true)
        defer { rig.close() }
        for run in 1...Self.runs {
            for shift in [(cols: -23, rows: -7), (cols: 17, rows: 5)] {
                for (variant, settledFirst) in [(R1Variant.modes, false), (.alternate, false),
                                                 (.modes, true), (.alternate, true)] {
                    var results: [R1Result] = []
                    for dirty in [false, true] {
                        results.append(try await r1(rig, run: run, variant: variant, dirty: dirty, shift: shift,
                                                    settledFirst: settledFirst))
                    }
                    let clean = results[0], dirty = results[1]
                    let same = clean.answers == dirty.answers && clean.keys == dirty.keys
                        && clean.whole == dirty.whole && clean.viewport == dirty.viewport
                    report("""
                        STEP5 R1 run=\(run) model=\(variant.rawValue)-grid\(shift.cols)x\(shift.rows)\(settledFirst ? "-settled-first" : "") \
                        compare clean-vs-dirty identical=\(same ? "yes" : "NO") \
                        answers=\(clean.answers == dirty.answers ? "same" : "DIFF") \
                        keys=\(clean.keys == dirty.keys ? "same" : "DIFF") \
                        history=\(clean.whole == dirty.whole ? "same" : "DIFF") \
                        viewport=\(clean.viewport == dirty.viewport ? "same" : "DIFF")
                        """)
                    #expect(same)
                }
            }
        }
    }

    enum R1Variant: String, CaseIterable {
        /// The model on its primary screen with history, every mode at its default.
        case plain
        /// The same with modes a snapshot must set again after its reset: mouse (1000,
        /// 1006), bracketed paste, application cursor keys, kitty flags 1 and a
        /// scrolling region.
        case modes
        /// The model on the alternate screen (`ESC [ ? 1049 h`) with text and modes of
        /// its own, its history on the primary screen underneath: the snapshot of a
        /// reconnect while a full screen program runs on the other Mac. After the
        /// comparison the program leaves the alternate screen and the surface is sent a
        /// fresh snapshot, as the server sends one then.
        case alternate
    }

    struct R1Result {
        let answers: String
        let keys: String
        let whole: [String]
        let viewport: [String]
    }

    /// The modes asked with DECRQM after every state change.
    static let r1Modes: [Int] = [1049, 1000, 1002, 1003, 1006, 2004, 1, 6, 25, 7]

    /// The queries: DECRQM per mode, the kitty flags, DECRQSS for the scrolling region,
    /// the cursor style and the pen, the cursor position, and a status report last,
    /// whose answer says every answer before it has been written.
    static var r1Queries: [UInt8] {
        var text = ""
        for mode in r1Modes { text += "\u{1B}[?\(mode)$p" }
        text += "\u{1B}[?u"
        text += "\u{1B}P$qr\u{1B}\\"
        text += "\u{1B}P$q q\u{1B}\\"
        text += "\u{1B}P$qm\u{1B}\\"
        text += "\u{1B}[6n"
        text += "\u{1B}[5n"
        return Array(text.utf8)
    }

    /// What a child leaves behind: 600 lines of history, the alternate screen with text
    /// on it, mouse reporting (1000, 1002, 1006), bracketed paste, application cursor
    /// keys and keypad, kitty flags 5 pushed, a blinking bar cursor, a scrolling region,
    /// origin mode, a coloured pen, a hidden cursor and the cursor moved.
    static var r1History: [UInt8] {
        var text = ""
        for n in 0..<600 { text += "OLD-HIST \(n) the dirty child's own history\r\n" }
        return Array(text.utf8)
    }

    static var r1Dirt: [UInt8] {
        var text = ""
        text += "\u{1B}[?1049h\u{1B}[2J\u{1B}[H"
        for n in 0..<10 { text += "OLD-ALT \(n) full screen program\r\n" }
        text += "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h"
        text += "\u{1B}[?2004h"
        text += "\u{1B}[?1h\u{1B}="
        text += "\u{1B}[>5u"
        text += "\u{1B}[5 q"
        text += "\u{1B}[3;15r"
        text += "\u{1B}[?6h"
        text += "\u{1B}[1;31;44m"
        text += "\u{1B}[?25l"
        text += "\u{1B}[5;10H"
        return Array(text.utf8)
    }

    private func r1Model(_ variant: R1Variant, size: TerminalSize, graphemes: Bool) throws -> GhosttyVtTerminal {
        let model = try GhosttyVtTerminal(size: size, scrollbackLines: 10_000, graphemeClustering: graphemes)
        var text = ""
        for n in 0..<1_500 { text += "NEW-HIST \(n) from the model's own history\r\n" }
        for n in 0..<8 { text += "\u{1B}[3\(n % 7 + 1)mNEW-SCREEN \(n)\u{1B}[0m on the model's screen\r\n" }
        text += "NEW-MARKER end of the model"
        if variant == .modes {
            text += "\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[?1h\u{1B}[>1u\u{1B}[3;20r"
        }
        if variant == .alternate {
            text += "\u{1B}[?1049h\u{1B}[2J\u{1B}[H"
            for n in 0..<6 { text += "\u{1B}[3\(n % 7 + 1)mNEW-ALT \(n)\u{1B}[0m on the model's alternate screen\r\n" }
            text += "\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[>1u"
        }
        text += "\u{1B}[7;15H"
        model.write(Array(text.utf8))
        return model
    }

    /// - Parameter shift: nil for a model at the surface's own grid. Otherwise the model
    ///   is that many columns and rows off the surface's grid, and the surface is a
    ///   `RemotePane`'s, opened through `RemotePanes` with the app's dependencies and
    ///   this scripted link: the `resize` before the snapshot reaches the pane's grid on
    ///   the main queue, and the pane holds the snapshot until the surface has that grid
    ///   (the snapshot of a reconnect after another viewer changed the grid).
    /// - Parameter settledFirst: with `shift`, the test itself also waits for the
    ///   surface to have the model's grid before it sends the snapshot, as the product
    ///   order did not before the pane held it: both orders must now give the same.
    private func r1(_ rig: SurfaceRig, run: Int, variant: R1Variant, dirty: Bool,
                    shift: (cols: Int, rows: Int)? = nil, settledFirst: Bool = false) async throws -> R1Result {
        let link = ScriptedLink()
        let shiftLabel = shift.map { "-grid\($0.cols)x\($0.rows)\(settledFirst ? "-settled-first" : "")" } ?? ""
        let id: String
        // At another grid the surface is the product's: a `RemotePane` opened through
        // `RemotePanes` with the app's dependencies, its one link this scripted one (so
        // the pane's `ObservedLink`, its snapshot hold and its grid are in the path).
        var panes: RemotePanes?
        var paneRef: RemoteSessionRef?
        var shownPane: RemotePane?
        var surface: OpenSurface?
        if shift != nil {
            let suite = "step5-r1-\(UUID().uuidString)"
            defer { UserDefaults().removePersistentDomain(forName: suite) }
            let connections = RemoteConnectionsStore(defaults: UserDefaults(suiteName: suite)!,
                                                     secretStore: PaneSecrets())
            let connection = RemoteConnection(id: UUID(), name: "R1", host: "127.0.0.1", port: 1, token: "r1")
            connections.add(connection)
            var dependencies = RemotePane.Dependencies.app(host: rig.host, helperPath: rig.helper,
                                                           connections: connections)
            let first = LinkOnce(link)
            dependencies.makeLink = { _, _ in first.take() }
            let made = RemotePanes(dependencies: dependencies)
            let ref = RemoteSessionRef(connectionId: connection.id,
                                       sessionId: "r1-\(run)-\(variant.rawValue)\(shiftLabel)-\(dirty ? "dirty" : "clean")")
            let pane = made.open(ref)
            #expect(await waitUntil(10) { pane.surfaceId != nil })
            rig.attach(pane)
            id = try #require(pane.surfaceId)
            panes = made
            paneRef = ref
            shownPane = pane
        } else {
            id = "r1-\(run)-\(variant.rawValue)-\(dirty ? "dirty" : "clean")"
            surface = try rig.open(id: id, link: link)
        }
        defer {
            surface?.close()
            if let panes, let paneRef { panes.close(paneRef) }
        }
        #expect(await waitUntil(10) { link.started })
        let ownGrid = try await rig.settledGrid(id)
        let modelSize = shift.map { TerminalSize(cols: ownGrid.cols + $0.cols, rows: ownGrid.rows + $0.rows) } ?? ownGrid
        let model = try r1Model(variant, size: modelSize, graphemes: rig.host.graphemeClustering)
        let prefix = "STEP5 R1 run=\(run) model=\(variant.rawValue)\(shiftLabel) surface=\(dirty ? "dirty" : "clean")"

        if dirty {
            // The history first, read back, so it is known to be in the surface's
            // scrollback before the program switches screens.
            link.deliver(.data(Self.r1History))
            link.deliver(.data(Array("\u{1B}[5n".utf8)))
            _ = try await answers(link)
            let history = rig.host.readText(id: id, maxLines: 1_000_000) ?? []
            report("""
                \(prefix) history-before-dirt surfaceLines=\(normalised(history).count) \
                oldHistLines=\(history.filter { $0.hasPrefix("OLD-HIST ") }.count)
                """)
            link.deliver(.data(Self.r1Dirt))
            link.deliver(.data(Self.r1Queries))
            let control = try await answers(link)
            let keys = shift == nil ? try await probeInput(rig, id: id, link: link) : "not-probed"
            let text = rig.host.readText(id: id, maxLines: 1_000_000) ?? []
            report("""
                \(prefix) before-snapshot answers=\(escaped(control)) keys=\(keys) \
                surfaceLines=\(normalised(text).count) oldLines=\(text.filter { $0.contains("OLD-") }.count)
                """)
        }

        let frame = model.snapshotFrame()
        let snapshot = TerminalPaint.hardReset + frame.bytes
        link.deliver(.resize(cols: frame.size.cols, rows: frame.size.rows, own: false))
        if settledFirst {
            _ = await waitUntil(5) { rig.host.size(id: id) == modelSize }
            try await Task.sleep(for: .milliseconds(300))
        }
        let snapshotSent = now()
        link.deliver(.snapshot(snapshot))
        if let pane = shownPane {
            // The pane held the snapshot and asked its own surface its size meanwhile:
            // none of that may reach the other Mac as input.
            let live = await waitUntil(5) { pane.state == .live }
            let heldMs = Double(now() - snapshotSent) / 1e6
            let input = link.sentSoFar
            // Under the 1 s bound: the terminal answered its size, the bound did not pass it.
            report("""
                \(prefix) held-show live=\(live ? "yes" : "NO") heldMs=\(String(format: "%.1f", heldMs)) \
                inputToServer=\(input.count) bytes
                """)
            #expect(heldMs < RemotePane.snapshotHoldLimit * 1000)
            #expect(live)
            #expect(input.isEmpty)
        }
        link.deliver(.data(Self.r1Queries))
        var after = try await answers(link)
        let gridAtAnswers = rig.host.size(id: id)
        if shift != nil {
            // The grid reaches the surface on the main queue, the snapshot through the
            // helper: either can come first. Once the surface has the model's grid,
            // the queries again, so the answers are those of the surface as it stays.
            let imposed = await waitUntil(5) { rig.host.size(id: id) == modelSize }
            report("""
                \(prefix) grid own=\(ownGrid.cols)x\(ownGrid.rows) model=\(modelSize.cols)x\(modelSize.rows) \
                atFirstAnswers=\(gridAtAnswers.map { "\($0.cols)x\($0.rows)" } ?? "none") \
                imposed=\(imposed ? "yes" : "NO") \
                reported=\((rig.events.grids[id] ?? []).map { "\($0.cols)x\($0.rows)" }.joined(separator: ",")) \
                firstAnswers=\(escaped(after))
                """)
            #expect(imposed)
            try await Task.sleep(for: .milliseconds(200))
            link.deliver(.data(Self.r1Queries))
            after = try await answers(link)
        }
        let grid = rig.host.size(id: id) ?? ownGrid
        let viewport = normalised(rig.host.readText(id: id, maxLines: grid.rows) ?? [])
        let modelViewport = normalised(model.viewportLines(unwrap: true))
        let whole = normalised(rig.host.readText(id: id, maxLines: 1_000_000) ?? [])
        let modelWhole = normalised(model.text(maxLines: 1_000_000).components(separatedBy: "\n"))
        let old = whole.filter { $0.contains("OLD-") }.count
        let newHistory = whole.filter { $0.hasPrefix("NEW-HIST ") }.count
        let modelHistory = modelWhole.filter { $0.hasPrefix("NEW-HIST ") }.count

        // What the model says the answers must be.
        var expected = ""
        for mode in Self.r1Modes { expected += "\u{1B}[?\(mode);\(model.isModeSet(UInt16(mode)) ? 1 : 2)$y" }
        expected += "\u{1B}[?\(model.kittyKeyboardFlags)u"
        let cursor = model.cursor
        let cpr = "\u{1B}[\(cursor.y + 1);\(cursor.x + 1)R"
        let modesMatch = after.hasPrefix(expected)
        let cursorMatch = after.contains(cpr)
        // A key or a click on a viewer claims the grid, which would change what is
        // measured here; R1 at the surface's own grid probes them.
        let keys = shift == nil ? try await probeInput(rig, id: id, link: link) : "not-probed"
        report("""
            \(prefix) after-snapshot grid=\(grid.cols)x\(grid.rows) snapshotBytes=\(snapshot.count) \
            viewportMatchesModel=\(viewport == modelViewport ? "yes" : "NO") \
            historyMatchesModel=\(whole == modelWhole ? "yes" : "NO") surfaceLines=\(whole.count) \
            modelLines=\(modelWhole.count) newHistLines=\(newHistory)/\(modelHistory) oldLines=\(old) \
            modelScrollbackRows=\(model.scrollbackRows) modesMatchModel=\(modesMatch ? "yes" : "NO") \
            cursorMatchesModel=\(cursorMatch ? "yes" : "NO") modelCursor=\(cursor.y + 1);\(cursor.x + 1)
            """)
        report("""
            \(prefix) after-snapshot answers=\(escaped(after)) expectedPrefix=\(escaped(expected)) keys=\(keys) \
            reported=\((rig.events.grids[id] ?? []).map { "\($0.cols)x\($0.rows)" }.joined(separator: ","))
            """)
        if whole != modelWhole { report("\(prefix) first difference: \(firstDifference(whole, modelWhole))") }
        if viewport != modelViewport { report("\(prefix) viewport difference: \(firstDifference(viewport, modelViewport))") }
        #expect(old == 0)
        #expect(whole == modelWhole)
        #expect(viewport == modelViewport)
        #expect(modesMatch && cursorMatch)
        if variant == .alternate {
            try await r1LeaveTheAlternateScreen(rig, id: id, link: link, model: model, prefix: prefix)
        }
        return R1Result(answers: after, keys: keys, whole: whole, viewport: viewport)
    }

    /// The program leaves the alternate screen. The surface holds an empty primary
    /// screen (the snapshot had none), so the server sends a fresh snapshot then
    /// (`PaneStreamHub`, the alternate screen rule); after it the surface must be the
    /// model again, history included.
    private func r1LeaveTheAlternateScreen(_ rig: SurfaceRig, id: String, link: ScriptedLink,
                                           model: GhosttyVtTerminal, prefix: String) async throws {
        let leave = Array("\u{1B}[?1049l".utf8)
        model.write(leave)
        link.deliver(.data(leave))
        link.deliver(.data(Array("\u{1B}[5n".utf8)))
        _ = try await answers(link)
        let left = normalised(rig.host.readText(id: id, maxLines: 1_000_000) ?? [])
        let frame = model.snapshotFrame()
        link.deliver(.snapshot(TerminalPaint.hardReset + frame.bytes))
        link.deliver(.data(Self.r1Queries))
        let after = try await answers(link)
        let grid = rig.host.size(id: id) ?? frame.size
        let viewport = normalised(rig.host.readText(id: id, maxLines: grid.rows) ?? [])
        let whole = normalised(rig.host.readText(id: id, maxLines: 1_000_000) ?? [])
        let modelViewport = normalised(model.viewportLines(unwrap: true))
        let modelWhole = normalised(model.text(maxLines: 1_000_000).components(separatedBy: "\n"))
        var expected = ""
        for mode in Self.r1Modes { expected += "\u{1B}[?\(mode);\(model.isModeSet(UInt16(mode)) ? 1 : 2)$y" }
        expected += "\u{1B}[?\(model.kittyKeyboardFlags)u"
        let cpr = "\u{1B}[\(model.cursor.y + 1);\(model.cursor.x + 1)R"
        report("""
            \(prefix) after-leaving-alternate beforeFreshSnapshot surfaceLines=\(left.count) \
            oldLines=\(left.filter { $0.contains("OLD-") }.count) \
            newHistLines=\(left.filter { $0.hasPrefix("NEW-HIST ") }.count) \
            afterFreshSnapshot viewportMatchesModel=\(viewport == modelViewport ? "yes" : "NO") \
            historyMatchesModel=\(whole == modelWhole ? "yes" : "NO") surfaceLines=\(whole.count) \
            modelLines=\(modelWhole.count) modesMatchModel=\(after.hasPrefix(expected) ? "yes" : "NO") \
            cursorMatchesModel=\(after.contains(cpr) ? "yes" : "NO")
            """)
        if whole != modelWhole { report("\(prefix) after-leaving-alternate first difference: \(firstDifference(whole, modelWhole))") }
        #expect(left.filter { $0.contains("OLD-") }.isEmpty)
        #expect(whole == modelWhole)
        #expect(viewport == modelViewport)
        #expect(after.hasPrefix(expected) && after.contains(cpr))
    }

    /// Everything the surface answered up to and including the status report, which the
    /// queries end with, then cleared.
    private func answers(_ link: ScriptedLink) async throws -> String {
        let done = await waitUntil(10) { String(decoding: link.sentSoFar, as: UTF8.self).contains("\u{1B}[0n") }
        #expect(done, "no answer to the status report")
        return String(decoding: link.takeSent(), as: UTF8.self)
    }

    /// Escape, up arrow and a click in the middle, each pressed and released, and what
    /// reached the link for each.
    private func probeInput(_ rig: SurfaceRig, id: String, link: ScriptedLink) async throws -> String {
        guard let view = rig.host.view(id: id) as? GhosttySurfaceView else { return "noview" }
        _ = link.takeSent()
        var parts: [String] = []
        let window = rig.window
        func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> (NSEvent, NSEvent) {
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            return (down, up)
        }
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        for (name, code, characters, flags) in [("esc", UInt16(53), "\u{1B}", NSEvent.ModifierFlags()),
                                                ("up", UInt16(126), up, NSEvent.ModifierFlags([.function, .numericPad]))] {
            let (down, release) = key(code, characters, flags)
            view.keyDown(with: down)
            view.keyUp(with: release)
            _ = await waitUntil(0.4) { !link.sentSoFar.isEmpty }
            try await Task.sleep(for: .milliseconds(100))
            parts.append("\(name)=\(escaped(String(decoding: link.takeSent(), as: UTF8.self)))")
        }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        _ = await waitUntil(0.4) { !link.sentSoFar.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        parts.append("click=\(escaped(String(decoding: link.takeSent(), as: UTF8.self)))")
        return parts.joined(separator: ",")
    }

    // MARK: R2. Backpressure through URLSessionWebSocketTask

    enum R2Client: String, CaseIterable {
        case fast, slow50ms, stalled
    }

    @Test func r2BackpressureThroughURLSession() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let port = server.port, token = server.token, rig = server.rig
        try await offMain {
            for run in 1...Self.runs {
                for client in R2Client.allCases {
                    try Self.flood(rig: rig, port: port, token: token, run: run, client: client)
                }
            }
        }
    }

    /// Floods one session at 16 MiB/s for 15 seconds while one client reads it, then
    /// 5 seconds quiet; samples once a second.
    private nonisolated static func flood(rig: StreamRig, port: Int, token: String, run: Int,
                                          client: R2Client) throws {
        let session = "r2-\(client.rawValue)-\(run)"
        try rig.add(session, cols: 120, rows: 34, scrollback: TerminalScrollback.defaultLines)
        rig.fill(session, lines: TerminalScrollback.defaultLines + 200)
        defer { rig.end(session) }
        let counts = ClientCounts()
        let release = DispatchSemaphore(value: 0)
        let connection = TerminalStreamConnection(
            connection: RemoteConnection(id: UUID(), name: "step5", host: "127.0.0.1", port: port, token: token),
            sessionId: session, resize: .reflow, callbackQueue: DispatchQueue(label: "step5.r2.client"))
        connection.onMessage = { message in
            counts.received(message)
            switch client {
            case .fast: break
            case .slow50ms: usleep(50_000)
            case .stalled:
                if case .data = message, counts.firstData() { _ = release.wait(timeout: .now() + 30) }
            }
        }
        connection.onEnded = { reason in counts.ended(reason) }
        let before = processMemory()
        connection.start()
        defer { connection.stop() }
        guard waitUntil(within: 10, { counts.snapshots >= 1 }) else {
            report("STEP5 R2 run=\(run) client=\(client.rawValue) no snapshot")
            return
        }
        let start = now()
        let feeder = PacedFeeder(rig: rig, session: session, bytesPerSecond: 16 << 20)
        var peakResident: UInt64 = 0, peakFootprint: UInt64 = 0
        var peakRecvQ = 0, peakSendQ = 0
        for second in 1...20 {
            Thread.sleep(until: Date(timeIntervalSinceNow: 1))
            if second == 15 { feeder.stop() }
            if client == .stalled && second == 17 { release.signal() }
            let memory = processMemory()
            let queues = tcpQueues(port: port)
            peakResident = max(peakResident, memory.resident)
            peakFootprint = max(peakFootprint, memory.footprint)
            peakRecvQ = max(peakRecvQ, queues.clientRecvQ)
            peakSendQ = max(peakSendQ, queues.serverSendQ)
            report("""
                STEP5 R2 run=\(run) client=\(client.rawValue) t=\(second)s fedMiB=\(mib(feeder.fed)) \
                residentMiB=\(mib(memory.resident)) footprintMiB=\(mib(memory.footprint)) \
                deltaResidentMiB=\(signedMiB(memory.resident, before.resident)) \
                clientMessages=\(counts.messages) clientDataMiB=\(mib(counts.dataBytes)) \
                clientSnapshots=\(counts.snapshots) serverSnapshots=\(rig.snapshots(of: session)) \
                clientRecvQ=\(queues.clientRecvQ) serverSendQ=\(queues.serverSendQ) end=\(counts.endText)
                """)
        }
        feeder.stop()
        report("""
            STEP5 R2 run=\(run) client=\(client.rawValue) summary seconds=\(String(format: "%.1f", Double(now() - start) / 1e9)) \
            fedMiB=\(mib(feeder.fed)) clientDataMiB=\(mib(counts.dataBytes)) \
            resyncs=\(max(0, rig.snapshots(of: session) - 1)) clientSnapshots=\(counts.snapshots) \
            residentBeforeMiB=\(mib(before.resident)) peakResidentMiB=\(mib(peakResident)) \
            peakFootprintMiB=\(mib(peakFootprint)) footprintBeforeMiB=\(mib(before.footprint)) \
            peakClientRecvQ=\(peakRecvQ) peakServerSendQ=\(peakSendQ) end=\(counts.endText)
            """)
    }

    // MARK: R3 and R4. The cost of a show, and large snapshots

    struct ShowCase {
        let label: String
        let lines: Int
        let scrollback: Int
        let dense: Bool
    }

    static let showCases = [
        ShowCase(label: "hist1k", lines: 1_200, scrollback: 1_000, dense: false),
        ShowCase(label: "hist10k", lines: 10_200, scrollback: 10_000, dense: false),
        ShowCase(label: "hist100k", lines: 100_200, scrollback: 100_000, dense: false),
        ShowCase(label: "dense100k", lines: 100_200, scrollback: 100_000, dense: true),
    ]

    @Test func r3AndR4TheCostOfAShow() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let rig = try await SurfaceRig.make(width: 1100, height: 760, container: true)
        defer { rig.close() }
        for item in Self.showCases {
            try server.rig.add(item.label, cols: 120, rows: 34, scrollback: item.scrollback)
            server.rig.fill(item.label, lines: item.lines, dense: item.dense)
            server.rig.write(item.label, Array("\r\nSTEP5-END \(item.label)".utf8))
        }
        let heartbeat = Heartbeat()
        heartbeat.start()
        defer { heartbeat.stop() }
        let (connections, connection) = server.connections()
        let links = ProbedLinks()
        let panes = probedPanes(rig, connections: connections, links: links)
        defer { panes.closeAll() }
        for run in 1...Self.runs {
            for item in Self.showCases {
                try await show(rig, panes: panes, links: links,
                               ref: RemoteSessionRef(connectionId: connection.id, sessionId: item.label),
                               item: item, run: run, heartbeat: heartbeat)
            }
        }
    }

    /// `RemotePanes` as the app builds them on this rig's host, but each link the
    /// product's `RemoteSocketLink` wrapped in a `ProbedRemoteLink`, kept in `links`.
    private func probedPanes(_ rig: SurfaceRig, connections: RemoteConnectionsStore,
                             links: ProbedLinks) -> RemotePanes {
        var dependencies = RemotePane.Dependencies.app(host: rig.host, helperPath: rig.helper,
                                                       connections: connections)
        dependencies.makeLink = { connection, session in
            let link = ProbedRemoteLink(RemoteSocketLink(connection: connection, session: session))
            links.all.append(link)
            return link
        }
        return RemotePanes(dependencies: dependencies)
    }

    /// A show through `RemotePanes.open`, the pane's surface put in the window as soon
    /// as it exists (as `RemoteSurfacePane` puts it there), and the hide through
    /// `RemotePanes.close`.
    private func show(_ rig: SurfaceRig, panes: RemotePanes, links: ProbedLinks, ref: RemoteSessionRef,
                      item: ShowCase, run: Int, heartbeat: Heartbeat) async throws {
        let marker = "STEP5-END \(item.label)"
        let linksBefore = links.all.count
        let start = now()
        let pane = panes.open(ref)
        var created: UInt64?
        let visible = await waitUntil(60, poll: .milliseconds(2)) {
            if created == nil, pane.surfaceId != nil { created = now() }
            rig.attach(pane)
            guard let id = pane.surfaceId else { return false }
            return (rig.host.readText(id: id, maxLines: 34) ?? []).contains { $0.contains(marker) }
        }
        let shown = now()
        let id = pane.surfaceId ?? "none"
        let state = "\(pane.state)"
        guard links.all.count > linksBefore else {
            Issue.record("no link was made")
            panes.close(ref)
            return
        }
        let probe = links.all[linksBefore].probe
        let grid = rig.events.firstGrid[id]
        let received = probe.snapshotReceivedAt ?? 0, written = probe.snapshotWrittenAt ?? 0
        let gap = heartbeat.maxGap(from: received, to: shown)
        let gapWrite = heartbeat.maxGap(from: received, to: written)
        // The whole screen read is slow on a deep scrollback; after the timing.
        let kept = normalised(rig.host.readText(id: id, maxLines: 1_000_000) ?? []).count
        report("""
            STEP5 R3 run=\(run) hist=\(item.label) via=RemotePane visible=\(visible ? "yes" : "NO") state=\(state) \
            links=\(links.all.count - linksBefore) \
            snapshotBytes=\(probe.snapshotBytes) toSurfaceMs=\(created.map { ms($0 &- start) } ?? "none") \
            toFirstGridMs=\(grid.map { ms($0 &- start) } ?? "none") \
            toHelperConnectedMs=\(probe.startedAt.map { ms($0 &- start) } ?? "none") \
            toFirstMessageMs=\(probe.firstMessageAt.map { ms($0 &- start) } ?? "none") \
            toSnapshotReceivedMs=\(ms(received &- start)) toSnapshotWrittenMs=\(ms(written &- start)) \
            toVisibleMs=\(ms(shown &- start)) surfaceLinesKept=\(kept)
            """)
        report("""
            STEP5 R4 run=\(run) hist=\(item.label) snapshotBytes=\(probe.snapshotBytes) \
            blockingWriteMs=\(ms(written &- received)) \
            writeMiBps=\(String(format: "%.1f", Double(probe.snapshotBytes) / 1_048_576 / max(1e-9, Double(written &- received) / 1e9))) \
            writtenToVisibleMs=\(ms(shown &- written)) mainGapDuringWriteMs=\(ms(gapWrite)) \
            mainGapUntilVisibleMs=\(ms(gap)) heartbeatMaxRunMs=\(ms(heartbeat.maxGap(from: start, to: shown)))
            """)
        #expect(visible)
        // The hide, timed: the pane's timers, grid and bridge stopped and its surface
        // freed, on the main actor.
        let hideStart = now()
        panes.close(ref)
        let hidden = now()
        #expect(rig.host.view(id: id) == nil)
        try await Task.sleep(for: .milliseconds(200))
        report("""
            STEP5 R3-HIDE run=\(run) hist=\(item.label) hideMs=\(ms(hidden &- hideStart)) \
            mainGapDuringHideMs=\(ms(heartbeat.maxGap(from: hideStart, to: hidden)))
            """)
    }

    @Test func r3HundredShowsAndHides() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let rig = try await SurfaceRig.make(width: 1100, height: 760, container: true)
        defer { rig.close() }
        let session = "cycles"
        try server.rig.add(session, cols: 120, rows: 34, scrollback: 1_000)
        server.rig.fill(session, lines: 1_200)
        server.rig.write(session, Array("\r\nSTEP5-END cycles".utf8))
        let (connections, connection) = server.connections()
        let links = ProbedLinks()
        let panes = probedPanes(rig, connections: connections, links: links)
        defer { panes.closeAll() }
        let ref = RemoteSessionRef(connectionId: connection.id, sessionId: session)
        // One show first, so what is created once per process (the renderer's caches,
        // URLSession, the helper's image in the page cache) is not counted as a leak.
        _ = await cycle(rig, panes: panes, ref: ref)
        try await Task.sleep(for: .seconds(3))
        for run in 1...Self.runs {
            let before = Census.take()
            var times: [UInt64] = []
            var failures = 0
            for index in 0..<100 {
                let start = now()
                let shown = await cycle(rig, panes: panes, ref: ref)
                if !shown { failures += 1 }
                times.append(now() &- start)
                if index == 49 {
                    let middle = Census.take()
                    report("STEP5 R3-CYCLES run=\(run) after=50 \(middle.describe(against: before))")
                }
            }
            let immediately = Census.take()
            try await Task.sleep(for: .seconds(3))
            let settled = Census.take()
            report("STEP5 R3-CYCLES run=\(run) after=100 immediately \(immediately.describe(against: before))")
            report("""
                STEP5 R3-CYCLES run=\(run) after=100 settled3s \(settled.describe(against: before)) \
                failures=\(failures) cycle \(summary(times))
                """)
        }
    }

    /// Show then hide through `RemotePanes`: true when the snapshot became visible.
    private func cycle(_ rig: SurfaceRig, panes: RemotePanes, ref: RemoteSessionRef) async -> Bool {
        let pane = panes.open(ref)
        defer { panes.close(ref) }
        return await waitUntil(10, poll: .milliseconds(2)) {
            rig.attach(pane)
            guard let id = pane.surfaceId else { return false }
            return (rig.host.readText(id: id, maxLines: 34) ?? []).contains { $0.contains("STEP5-END") }
        }
    }

    // MARK: R7. Ends that leave the helper

    @Test func r7EndsThatLeaveTheHelper() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let rig = try await SurfaceRig.make(width: 1100, height: 760, container: true)
        defer { rig.close() }
        for run in 1...Self.runs {
            for keep in [false, true] {
                try await r7(rig, server: server, run: run, keepBridge: keep)
            }
        }
    }

    private func r7(_ rig: SurfaceRig, server: ServerRig, run: Int, keepBridge: Bool) async throws {
        let session = "r7-\(run)-\(keepBridge ? "kept" : "stopped")"
        try server.rig.add(session, cols: 100, rows: 30, scrollback: 1_000)
        server.rig.fill(session, lines: 200)
        server.rig.write(session, Array("\r\nSTEP5-END last screen of \(session)".utf8))
        let prefix = "STEP5 R7 run=\(run) bridge=\(keepBridge ? "kept-no-link" : "stopped-on-ended")"
        let before = Census.take()
        let link = ProbedRemoteLink(port: server.port, token: server.token, session: session)
        let id = "r7-\(run)-\(keepBridge)"
        let surface = try rig.open(id: id, link: link, imposeOnResize: true)
        defer { surface.close() }
        let ended = EndBox()
        let bridge = surface.bridge
        surface.bridge.onEnded = { reason in
            ended.set(reason)
            // As `OwnPaneBridge` does on `.sessionEnded`: off the callback.
            if !keepBridge { DispatchQueue.global().async { bridge.stop() } }
        }
        #expect(await waitUntil(10) {
            (rig.host.readText(id: id, maxLines: 30) ?? []).contains { $0.contains("STEP5-END") }
        })
        let shown = Census.take()
        server.rig.end(session)
        _ = await waitUntil(5) { ended.reason != nil }
        try await Task.sleep(for: .seconds(2))
        let screen = lastLines(rig.host.readText(id: id, maxLines: 30) ?? [], 3)
        let afterEnd = Census.take()
        report("""
            \(prefix) end=\(ended.text) closeRequests=\(rig.events.closes(id)) \
            lastLines=\(screen) surfaceGrid=\(rig.host.size(id: id).map { "\($0.cols)x\($0.rows)" } ?? "none") \
            shown[\(shown.describe(against: before))] afterEnd2s[\(afterEnd.describe(against: before))]
            """)
        if let view = rig.host.view(id: id) as? GhosttySurfaceView {
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: rig.window.windowNumber, context: nil, characters: "a",
                                        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            view.keyDown(with: down)
        }
        try await Task.sleep(for: .seconds(1))
        let afterKey = Census.take()
        report("""
            \(prefix) after-key closeRequests=\(rig.events.closes(id)) \
            lastLines=\(lastLines(rig.host.readText(id: id, maxLines: 30) ?? [], 3)) \
            surfaceExists=\(rig.host.view(id: id) != nil) afterKey[\(afterKey.describe(against: before))]
            """)
        surface.close()
        try await Task.sleep(for: .seconds(2))
        report("\(prefix) after-hide2s[\(Census.take().describe(against: before))]")
    }

    // MARK: RECONNECT. A kept dirty surface, through RemotePane

    enum ReconnectScenario: String, CaseIterable {
        /// On the alternate screen with modes set when the link drops. While it is down
        /// the program leaves it, resets its modes and prints, and another viewer makes
        /// the grid smaller.
        case leftAlternate = "left-alternate"
        /// On the primary screen with modes set when the link drops. While it is down
        /// the program enters the alternate screen, at the same grid. After the
        /// comparison it leaves it again, and the server sends its fresh snapshot.
        case enteredAlternate = "entered-alternate"
    }

    /// A terminal of another Mac through `RemotePanes` as the app builds them (real
    /// `RemoteSocketLink`, `TerminalBridge`, helper and viewer surface) against a real
    /// `RemoteServer` on 127.0.0.1. The program leaves the surface dirty, the server
    /// goes away, the terminal changes while the pane is `reconnecting`, the server
    /// comes back on the same port, and the pane makes a new link by itself on the same
    /// surface. Then the surface is compared with the server's terminal: history,
    /// viewport, modes, kitty flags and cursor (a second terminal fed the same bytes
    /// stands in for the model, which exposes no modes).
    @Test func reconnectOnAKeptDirtySurfaceThroughRemotePane() async throws {
        let server = try await ServerRig.start()
        defer { server.stop() }
        let rig = try await SurfaceRig.make(width: 1100, height: 760, container: true)
        defer { rig.close() }
        let (connections, connection) = server.connections()
        let panes = RemotePanes(host: rig.host, helperPath: rig.helper, connections: connections)
        defer { panes.closeAll() }
        for run in 1...Self.runs {
            for scenario in ReconnectScenario.allCases {
                try await reconnect(rig, server: server, panes: panes, connectionId: connection.id,
                                    run: run, scenario: scenario)
            }
        }
    }

    private func reconnect(_ rig: SurfaceRig, server: ServerRig, panes: RemotePanes, connectionId: UUID,
                           run: Int, scenario: ReconnectScenario) async throws {
        let session = "rc-\(run)-\(scenario.rawValue)"
        let prefix = "STEP5 RECONNECT run=\(run) scenario=\(scenario.rawValue)"
        let streams = server.rig
        try streams.add(session, cols: 100, rows: 30, scrollback: 1_000, shadow: true)
        defer { streams.end(session) }
        streams.fill(session, lines: 300)
        streams.write(session, Array("\r\nSTEP5-RC-SHOWN\r\n".utf8))
        let ref = RemoteSessionRef(connectionId: connectionId, sessionId: session)
        let pane = panes.open(ref)
        defer { panes.close(ref) }
        func text(_ rows: Int) -> [String] {
            guard let id = pane.surfaceId else { return [] }
            return rig.host.readText(id: id, maxLines: rows) ?? []
        }
        func visible(_ marker: String) -> Bool {
            rig.attach(pane)
            return text(200).contains { $0.contains(marker) }
        }
        /// Sends `bytes` through the server, then a status report, and waits for the
        /// surface's answer, which follows every answer to what came before it.
        func through(_ bytes: [UInt8]) async -> String {
            _ = streams.takeInput()
            streams.write(session, bytes + Array("\u{1B}[5n".utf8))
            _ = await waitUntil(10) { String(decoding: streams.inputSoFar, as: UTF8.self).contains("\u{1B}[0n") }
            return String(decoding: streams.takeInput(), as: UTF8.self)
        }

        let shown = await waitUntil(20) { pane.state == .live && visible("STEP5-RC-SHOWN") }
        #expect(shown, "never live")
        let surfaceId = pane.surfaceId

        // The program leaves the surface dirty.
        var dirt = ""
        if scenario == .leftAlternate {
            dirt += "\u{1B}[?1049h\u{1B}[2J\u{1B}[H"
            for n in 0..<10 { dirt += "RC-ALT \(n) full screen program before the drop\r\n" }
        } else {
            for n in 0..<10 { dirt += "RC-PRIMARY \(n) before the drop\r\n" }
        }
        dirt += "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[?1h\u{1B}=\u{1B}[>5u"
        dirt += "\u{1B}[5 q\u{1B}[3;15r\u{1B}[?6h\u{1B}[1;31;44m\u{1B}[?25l\u{1B}[5;10H"
        _ = await through(Array(dirt.utf8))
        let dirtyAnswers = await through(Self.r1Queries)

        // The server goes away; the terminal changes meanwhile.
        server.drop()
        let lost = await waitUntil(10) { pane.state == .reconnecting }
        var down = ""
        if scenario == .leftAlternate {
            down += "\u{1B}[?1049l"
            down += "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?1l\u{1B}>\u{1B}[<u"
            down += "\u{1B}[0 q\u{1B}[r\u{1B}[?6l\u{1B}[0m\u{1B}[?25h"
            for n in 0..<20 { down += "WHILE-DOWN \(n) printed while the link was down\r\n" }
            streams.write(session, Array(down.utf8))
            streams.resize(session, to: TerminalSize(cols: 90, rows: 26))
        } else {
            // Origin mode off first: a cursor report under it is relative to the
            // scrolling region, which the shadow cannot say, and the alternate screen
            // saves the cursor with it.
            down += "\u{1B}[?6l\u{1B}[?1049h\u{1B}[2J\u{1B}[H"
            for n in 0..<8 { down += "\u{1B}[3\(n % 7 + 1)mRC-ALT-DOWN \(n)\u{1B}[0m entered while the link was down\r\n" }
            down += "\u{1B}[?1003h\u{1B}[?2004l"
            streams.write(session, Array(down.utf8))
        }
        streams.write(session, Array("STEP5-RC-BACK\u{1B}[3;7H".utf8))
        let wanted = streams.model(session)?.size

        // It comes back on the same port: the pane reconnects by itself.
        let downAt = now()
        try await server.restart()
        let back = await waitUntil(30) {
            pane.state == .live && visible("STEP5-RC-BACK") && rig.host.size(id: pane.surfaceId ?? "") == wanted
        }
        let backMs = ms(now() &- downAt)
        try await Task.sleep(for: .milliseconds(300))
        let header = "\(prefix) lost=\(lost ? "yes" : "NO") back=\(back ? "yes" : "NO") backMs=\(backMs) "
            + "sameSurface=\(pane.surfaceId == surfaceId ? "yes" : "NO") "
            + "mouseBeforeTheDrop=\(dirtyAnswers.contains("\u{1B}[?1000;1$y") ? "set" : "unset")"
        try await compare(rig, pane: pane, session: session, streams: streams, step: "after-reconnect",
                          prefix: header, through: through)
        #expect(lost && back && pane.surfaceId == surfaceId)

        if scenario == .enteredAlternate {
            // The program leaves the alternate screen: the server sends a fresh snapshot,
            // since the surface joined on it and holds no primary screen.
            streams.write(session, Array("\u{1B}[?1049l".utf8))
            _ = await waitUntil(10) { visible("STEP5-RC-SHOWN") }
            try await Task.sleep(for: .milliseconds(300))
            try await compare(rig, pane: pane, session: session, streams: streams, step: "after-leaving-alternate",
                              prefix: prefix, through: through)
        }
    }

    /// The surface of `pane` against the session's shadow terminal.
    private func compare(_ rig: SurfaceRig, pane: RemotePane, session: String, streams: StreamRig, step: String,
                         prefix: String, through: ([UInt8]) async -> String) async throws {
        let answers = await through(Self.r1Queries)
        guard let id = pane.surfaceId,
              let reference = streams.shadow(session, { terminal in
                  (size: terminal.size,
                   viewport: normalised(terminal.viewportLines(unwrap: true)),
                   whole: normalised(terminal.text(maxLines: 1_000_000).components(separatedBy: "\n")),
                   modes: Self.r1Modes.map { terminal.isModeSet(UInt16($0)) },
                   kitty: terminal.kittyKeyboardFlags,
                   cursor: terminal.cursor,
                   alternate: terminal.isAlternateScreen)
              }) else {
            Issue.record("no surface or no shadow")
            return
        }
        let modelWhole = normalised((streams.model(session)?.text(maxLines: 1_000_000) ?? "").components(separatedBy: "\n"))
        let grid = rig.host.size(id: id)
        let viewport = normalised(rig.host.readText(id: id, maxLines: grid?.rows ?? reference.size.rows) ?? [])
        let whole = normalised(rig.host.readText(id: id, maxLines: 1_000_000) ?? [])
        var expected = ""
        for (mode, set) in zip(Self.r1Modes, reference.modes) { expected += "\u{1B}[?\(mode);\(set ? 1 : 2)$y" }
        expected += "\u{1B}[?\(reference.kitty)u"
        let cpr = "\u{1B}[\(reference.cursor.y + 1);\(reference.cursor.x + 1)R"
        report("""
            \(prefix) \(step) grid=\(grid.map { "\($0.cols)x\($0.rows)" } ?? "none") \
            model=\(reference.size.cols)x\(reference.size.rows) alternate=\(reference.alternate) \
            viewportMatchesModel=\(viewport == reference.viewport ? "yes" : "NO") \
            historyMatchesModel=\(whole == reference.whole ? "yes" : "NO") \
            shadowIsModel=\(reference.whole == modelWhole ? "yes" : "NO") surfaceLines=\(whole.count) \
            modelLines=\(reference.whole.count) modesMatchModel=\(answers.hasPrefix(expected) ? "yes" : "NO") \
            cursorMatchesModel=\(answers.contains(cpr) ? "yes" : "NO")
            """)
        if whole != reference.whole { report("\(prefix) \(step) first difference: \(firstDifference(whole, reference.whole))") }
        if viewport != reference.viewport {
            report("\(prefix) \(step) viewport difference: \(firstDifference(viewport, reference.viewport))")
        }
        if !answers.hasPrefix(expected) || !answers.contains(cpr) {
            report("\(prefix) \(step) answers=\(escaped(answers)) expectedPrefix=\(escaped(expected)) cpr=\(escaped(cpr))")
        }
        #expect(grid == reference.size)
        #expect(reference.whole == modelWhole)
        #expect(whole == reference.whole)
        #expect(viewport == reference.viewport)
        #expect(answers.hasPrefix(expected) && answers.contains(cpr))
    }

    // MARK: A viewer surface

    /// A viewer surface (`createViewerSurface`) on a real surface: a program's `OSC 52`
    /// write leaves the pasteboard alone, before and after a configuration reload, its
    /// `OSC 52` read is answered with nothing, and its title, bell and desktop
    /// notification reach no host callback; a key reaches no `onInput` and claims
    /// through the viewer's grid, and the user's own paste and copy work. The same
    /// program on a surface of this Mac's own (`createSurface`) shows that each would
    /// have been seen. The host is given a private pasteboard, so the user's is never
    /// touched.
    ///
    /// Every absence is proved by an ordering, not a wait: each request is followed by
    /// an `OSC 11` background, which libghostty hands the host after the request on the
    /// same main queue, so once the host holds that background the request has been
    /// handled; and the read's answer would reach the link before the answer to a
    /// device attributes query sent after it.
    @Test func aViewerSurfaceKeepsAProgramOnAnotherMacAwayFromThisMac() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("eu.kloosterman.wietty.step5.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let rig = try await SurfaceRig.make(width: 800, height: 500, container: true, pasteboard: pasteboard)
        defer { rig.close() }
        var marker = 0
        /// Delivers `bytes` and then a background of its own, and waits until the host
        /// holds that background for `id`.
        func deliver(_ bytes: String, to link: ScriptedLink, id: String) async -> Bool {
            marker += 1
            let background = String(format: "rgb:%02x/%02x/00", marker, Self.r8BackgroundMarker)
            link.deliver(.data(Array((bytes + "\u{1B}]11;\(background)\u{07}").utf8)))
            let wanted = marker
            return await waitUntil(5) {
                Self.r8Generation(of: (rig.host.view(id: id) as? GhosttySurfaceView)?.programBackground) == wanted
            }
        }
        func osc52Write(_ text: String) -> String {
            "\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}"
        }
        let events = "\u{1B}]2;a title\u{07}\u{07}\u{1B}]9;a notification\u{07}"

        // This Mac's own terminal: each request is seen.
        let ownLink = ScriptedLink()
        let own = try rig.open(id: "own", link: ownLink)
        #expect(await waitUntil(10) { ownLink.started })
        pasteboard.clearContents()
        pasteboard.setString("on this Mac", forType: .string)
        #expect(await deliver(osc52Write("from the own terminal") + events, to: ownLink, id: "own"))
        #expect(pasteboard.string(forType: .string) == "from the own terminal")
        #expect(rig.events.titles.contains { $0.id == "own" && $0.title == "a title" })
        #expect(rig.events.all.contains { $0.id == "own" && $0.kind == "bell" })
        #expect(rig.events.all.contains { $0.id == "own" && $0.kind == "notification" })
        // Its helper gone while the surface lives, a key asks libghostty to close it,
        // and the request reaches the host's owner by the next main turn.
        #expect(await closeRequestAfterHelperExit(rig, surface: own) == 1)
        own.close()

        // A terminal on another Mac.
        let claims = ClaimLog()
        let grid = OwnPaneGrid(viewer: true, claim: { claims.add($0); return true }, impose: { _ in })
        defer { grid.stop() }
        let link = ScriptedLink()
        let viewer = try rig.open(id: "rv:test:s:1", link: link, viewer: true, grid: grid)
        defer { viewer.close() }
        let id = viewer.id
        #expect(await waitUntil(10) { link.started })
        rig.events.reset()
        pasteboard.clearContents()
        pasteboard.setString("on this Mac", forType: .string)
        let changeCount = pasteboard.changeCount

        #expect(await deliver(osc52Write("from the other Mac") + events, to: link, id: id))
        #expect(pasteboard.changeCount == changeCount)
        #expect(pasteboard.string(forType: .string) == "on this Mac")
        #expect(rig.events.all.filter { $0.id == id && ["title", "bell", "notification", "close", "input"].contains($0.kind) }.isEmpty)

        #expect(rig.host.viewerClipboardAccess.map { GhosttySurfaceHost.isClosed(read: $0.read, write: $0.write) } == true)
        rig.host.reloadConfig()
        #expect(rig.host.viewerClipboardAccess.map { GhosttySurfaceHost.isClosed(read: $0.read, write: $0.write) } == true)
        // The overlay file of this process is gone once loaded, at start and on reload.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))?
            .filter { $0.hasPrefix("wietty-viewer-surface-\(getpid())-") } ?? []
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
        #expect(await deliver(osc52Write("after a reload"), to: link, id: id))
        #expect(pasteboard.changeCount == changeCount)

        _ = link.takeSent()
        #expect(await deliver("\u{1B}]52;c;?\u{07}", to: link, id: id))
        link.deliver(.data(Array("\u{1B}[c".utf8)))
        #expect(await waitUntil(5) { String(decoding: link.sentSoFar, as: UTF8.self).contains("\u{1B}[?") })
        let answered = String(decoding: link.takeSent(), as: UTF8.self)
        #expect(!answered.contains("]52;"), "answered \(escaped(answered))")
        #expect(NSApp.modalWindow == nil)

        // Showing it claimed nothing; a key claims, and reaches no `onInput`.
        #expect(claims.grids.isEmpty)
        guard let view = rig.host.view(id: id) as? GhosttySurfaceView else {
            Issue.record("no view")
            return
        }
        rig.window.makeFirstResponder(view)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: rig.window.windowNumber, context: nil, characters: "x",
                                   charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
        view.keyDown(with: key)
        #expect(!rig.events.all.contains { $0.id == id && $0.kind == "input" })
        #expect(claims.grids.count == 1)
        #expect(await waitUntil(5) { String(decoding: link.sentSoFar, as: UTF8.self).contains("x") })

        // The user's own paste and copy.
        _ = link.takeSent()
        pasteboard.clearContents()
        pasteboard.setString("pasted by the user", forType: .string)
        view.paste(nil)
        #expect(await waitUntil(5) { String(decoding: link.sentSoFar, as: UTF8.self).contains("pasted by the user") })
        #expect(await deliver("\u{1B}[2J\u{1B}[Hcopied by the user", to: link, id: id))
        view.selectAll(nil)
        view.copy(nil)
        #expect(pasteboard.string(forType: .string)?.contains("copied by the user") == true)

        // A close request of the viewer reaches no owner.
        #expect(await closeRequestAfterHelperExit(rig, surface: viewer) == 0)
    }

    /// Stops the bridge of `surface`, so its helper exits while the surface lives,
    /// waits until libghostty shows that, presses a key, and returns how many close
    /// requests reached the host's owner for it by the next main turn. libghostty asks
    /// for the close inside the key's handling and the host hops it to the main queue,
    /// so the turn after the key is late enough; the own surface's 1 shows it.
    private func closeRequestAfterHelperExit(_ rig: SurfaceRig, surface: OpenSurface) async -> Int {
        surface.bridge.stop()
        let exited = await waitUntil(10) {
            (rig.host.readText(id: surface.id, maxLines: 40) ?? []).contains { $0.contains("Press any key") }
        }
        #expect(exited, "the surface never showed its child's exit")
        guard let view = rig.host.view(id: surface.id) as? GhosttySurfaceView else { return -1 }
        rig.window.makeFirstResponder(view)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: rig.window.windowNumber, context: nil, characters: "a",
                                   charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        view.keyDown(with: key)
        await nextMainTurn()
        return rig.events.closes(surface.id)
    }

    // MARK: The SwiftUI pane

    /// `RemoteSurfacePane` in a window, over `RemotePanes` built as the app builds them
    /// (`RemotePane.Dependencies.app`) on this rig's host and a real `RemoteServer` on
    /// 127.0.0.1: a show, a hide and a second show of the same session, a user action
    /// that makes the pane own the grid, the server going away and coming back on the
    /// same port, a change of session, the session ending on the server, and the last
    /// hide. Prints `STEP5 PANE` lines with the state and the pane's layout at each step.
    ///
    /// Asserted: the bar is drawn over the surface (the container keeps the whole pane,
    /// the pane's own grid does not move, and a point in the bar does not hit the
    /// surface); across the drop and the return no claim reaches the server but the one
    /// the lost link rule makes, for the same grid; a reconnect keeps the surface; a
    /// session change destroys the old surface and leaves exactly one.
    @Test func theSwiftUIPaneShowsReconnectsAndEnds() async throws {
        let suite = "test.step5.pane.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let token = RemoteAccessToken(defaults: defaults)
        let projects = ProjectStore(defaults: defaults, service: FakeTerminalService())
        let streams = StreamRig()
        defer { streams.hub.stop() }
        try streams.add("pane", cols: 100, rows: 30, scrollback: 1_000)
        try streams.add("pane-b", cols: 100, rows: 30, scrollback: 1_000)
        streams.write("pane", Array("STEP5-PANE-MARKER\r\n".utf8))
        streams.write("pane-b", Array("STEP5-PANE-B\r\n".utf8))
        var server = RemoteServer(store: projects, streamer: streams.hub, token: token, host: "127.0.0.1", port: 0)
        await server.start()
        #expect(await waitUntil(10) { server.boundPort != nil })
        let port = try #require(server.boundPort)
        defer { server.stop() }

        let rig = try await SurfaceRig.make(width: 1000, height: 700, container: false)
        defer { rig.close() }
        let connections = RemoteConnectionsStore(defaults: defaults, secretStore: PaneSecrets())
        let connection = RemoteConnection(id: UUID(), name: "Loopback", host: "127.0.0.1", port: port,
                                          token: token.value)
        connections.add(connection)
        let panes = RemotePanes(host: rig.host, helperPath: rig.helper, connections: connections)
        defer { panes.closeAll() }
        let ref = RemoteSessionRef(connectionId: connection.id, sessionId: "pane")
        let refB = RemoteSessionRef(connectionId: connection.id, sessionId: "pane-b")
        let shown = PaneShown(session: ref)
        let hosting = NSHostingView(rootView: PaneProbe(shown: shown, panes: panes))
        rig.window.contentView = hosting
        var seenIds: [String] = []

        func current() -> RemotePane? { panes.pane(for: shown.session) }
        func surface() -> GhosttySurfaceView? { current()?.surfaceView as? GhosttySurfaceView }
        func container() -> SurfaceContainerView? { surface()?.superview as? SurfaceContainerView }
        func containerSize() -> CGSize? {
            hosting.layoutSubtreeIfNeeded()
            return container()?.bounds.size
        }
        func layout() -> String {
            guard let container = container() else { return "no-surface" }
            hosting.layoutSubtreeIfNeeded()
            let frame = container.convert(container.bounds, to: hosting)
            let top = hosting.isFlipped ? frame.minY : hosting.bounds.height - frame.maxY
            let grid = surface()?.ownGrid.map { "\($0.cols)x\($0.rows)" } ?? "none"
            return "containerTop=\(Int(top)) containerHeight=\(Int(container.bounds.height)) "
                + "paneHeight=\(Int(hosting.bounds.height)) ownGrid=\(grid) barHitsSurface=\(barHitsSurface())"
        }
        /// Whether a point in the middle of the bar's strip hits the surface.
        func barHitsSurface() -> Bool {
            guard let view = surface() else { return false }
            let y = hosting.isFlipped ? 8 : hosting.bounds.height - 8
            let point = hosting.convert(NSPoint(x: hosting.bounds.midX, y: y), to: hosting.superview)
            guard let hit = hosting.hitTest(point) else { return false }
            return hit === view || hit.isDescendant(of: view)
        }
        func visible(_ marker: String) -> Bool {
            guard let id = current()?.surfaceId else { return false }
            if !seenIds.contains(id) { seenIds.append(id) }
            // More rows than any grid here (the claim makes it 40 rows), so the read
            // reaches the top of the screen.
            return (rig.host.readText(id: id, maxLines: 100) ?? []).contains { $0.contains(marker) }
        }
        func step(_ name: String, _ ok: Bool) {
            let pane = current()
            let state = pane.map { "\($0.state)" } ?? "closed"
            report("STEP5 PANE \(name) ok=\(ok ? "yes" : "NO") state=\(state) "
                + "surface=\(pane?.surfaceId ?? "none") panes=\(panes.count) claims=\(streams.claims.count) \(layout())")
            #expect(ok, "\(name)")
        }

        // Show.
        let first = await waitUntil(20) { current()?.state == .live && visible("STEP5-PANE-MARKER") }
        step("show", first)
        let firstId = try #require(current()?.surfaceId)

        // Hide: the pane closes and its surface goes.
        shown.on = false
        let hidden = await waitUntil(5) { panes.count == 0 && rig.host.view(id: firstId) == nil }
        step("hide", hidden)

        // Show the same session again: a new pane, a new surface, a new attach.
        shown.on = true
        let again = await waitUntil(20) {
            current()?.state == .live && visible("STEP5-PANE-MARKER") && current()?.surfaceId != firstId
        }
        step("show-again", again)
        let liveId = try #require(current()?.surfaceId)

        // A user action: the pane claims its own grid and owns it.
        let fullSize = try #require(containerSize())
        let ownGrid = try #require(surface()?.ownGrid)
        surface()?.onUserAction?()
        let claimed = await waitUntil(10) { streams.claims.count == 1 }
        step("user-action", claimed && streams.claims.last == ownGrid)
        try await Task.sleep(for: .milliseconds(500))
        let claimsBefore = streams.claims.count
        #expect(claimsBefore == 1)

        // The server goes away: the link is lost, the bar comes over the surface.
        server.stop()
        let lost = await waitUntil(10) { current()?.state == .reconnecting }
        let lostLayoutSame = containerSize() == fullSize && surface()?.ownGrid == ownGrid && !barHitsSurface()
        step("server-stopped", lost && lostLayoutSame)

        // It comes back on the same port: the pane reconnects by itself on the same
        // surface, the bar goes, and the one claim of the lost link rule is the only one.
        server = RemoteServer(store: projects, streamer: streams.hub, token: token, host: "127.0.0.1", port: port)
        await server.start()
        streams.write("pane", Array("STEP5-PANE-BACK\r\n".utf8))
        let back = await waitUntil(30) { current()?.state == .live && visible("STEP5-PANE-BACK") }
        try await Task.sleep(for: .milliseconds(1_000))
        // `onClaim` runs only for a grid other than the one in force, so a claim of
        // the unchanged grid (the lost link rule's) resizes nothing and is not logged:
        // any entry here is a resize the other Mac would see.
        let newClaims = Array(streams.claims.dropFirst(claimsBefore))
        let backText = lastLines(rig.host.readText(id: liveId, maxLines: 100) ?? [], 4)
        report("STEP5 PANE server-back-detail back=\(back) sameSurface=\(current()?.surfaceId == liveId) "
            + "resizesAcrossDrop=\(newClaims.map { "\($0.cols)x\($0.rows)" }) text=\(backText)")
        step("server-back", back && current()?.surfaceId == liveId && containerSize() == fullSize
             && newClaims.isEmpty)

        // A change of session in the same view: the old surface goes, a new one comes,
        // and exactly one surface of this test is alive.
        shown.session = refB
        let changed = await waitUntil(20) {
            current()?.state == .live && visible("STEP5-PANE-B") && rig.host.view(id: liveId) == nil
        }
        let alive = seenIds.filter { rig.host.view(id: $0) != nil }
        report("STEP5 PANE surfaces-alive \(alive)")
        step("session-change", changed && panes.count == 1 && panes.pane(for: ref) == nil
             && alive.count == 1 && alive.first == current()?.surfaceId)

        // The session ends on the server: the pane keeps its surface but shows the
        // stopped screen in its place, so the surface is in no container.
        streams.end("pane-b")
        let ended = await waitUntil(10) { current()?.state == .ended }
        let offScreen = await waitUntil(5) { current()?.surfaceView?.superview == nil }
        step("session-ended", ended && current()?.surfaceView != nil && offScreen
             && RemotePaneLayout(state: current()?.state).content == .stopped)

        // The last hide.
        let lastId = current()?.surfaceId
        shown.on = false
        let gone = await waitUntil(5) { panes.count == 0 && lastId.map { rig.host.view(id: $0) == nil } ?? false }
        step("last-hide", gone)
    }

    // MARK: R8. Fast hide and show

    /// When the next surface is created after its predecessor was destroyed.
    enum R8Timing: String, CaseIterable {
        /// Destroy and create in one main turn, on a host made with its drain on
        /// destroy turned off (`drainsOnDestroy: false`): what the host did before it
        /// drained.
        case sameTurnNoDrain = "same-turn-no-drain"
        /// Destroy and create in one main turn, as the host does it: it drains
        /// libghostty's mailbox right after the free.
        case sameTurn = "same-turn"
        /// The create on the main queue turn after the destroy's: everything queued on
        /// the main queue before it (wakeups, action hops) runs first.
        case nextTurn = "one-turn-between"
    }

    /// Which surfaces follow which.
    enum R8Mix: String, CaseIterable {
        /// Every generation a surface of this Mac's own terminal (`createSurface`).
        case ownAfterOwn = "own-after-own"
        /// Even generations viewers (`createViewerSurface`) whose program also writes the
        /// clipboard (`OSC 52`) every 2 ms, odd ones own surfaces: a viewer's late
        /// clipboard write, title or bell would reach an own surface, which runs under
        /// the app's configuration with the clipboard open and reports titles.
        case ownAfterViewer = "own-after-viewer"
    }

    @Test func r8FastHideAndShow() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("eu.kloosterman.wietty.step5.r8.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        // The host's drain is fixed when it is made, so the runs without it have a host
        // of their own, made and dropped before the host of the other runs.
        for drains in [false, true] {
            let rig = try await SurfaceRig.make(width: 1000, height: 700, container: true, pasteboard: pasteboard,
                                                drainsOnDestroy: drains)
            defer { rig.close() }
            #expect(rig.host.drainsOnDestroy == drains)
            for mix in R8Mix.allCases {
                for timing in R8Timing.allCases where (timing == .sameTurnNoDrain) == !drains {
                    for run in 1...Self.runs {
                        try await r8(rig, pasteboard: pasteboard, run: run, timing: timing, mix: mix)
                    }
                }
            }
        }
    }

    /// The marker in the green byte of every background this measurement sets, so a
    /// background it did not set reads as foreign.
    private nonisolated static let r8BackgroundMarker = 0x5A

    /// The generation a program background of this measurement encodes, nil for none,
    /// -1 for a colour it did not set.
    static func r8Generation(of color: NSColor?) -> Int? {
        guard let color else { return nil }
        guard let srgb = color.usingColorSpace(.sRGB) else { return -1 }
        let red = Int((srgb.redComponent * 255).rounded())
        let green = Int((srgb.greenComponent * 255).rounded())
        return green == r8BackgroundMarker ? red : -1
    }

    private func r8(_ rig: SurfaceRig, pasteboard: NSPasteboard, run: Int, timing: R8Timing,
                    mix: R8Mix) async throws {
        let prefix = "STEP5 R8 mix=\(mix.rawValue) timing=\(timing.rawValue) run=\(run)"
        let before = Census.take()
        rig.events.reset()
        pasteboard.clearContents()
        pasteboard.setString("on this Mac", forType: .string)
        let changeCount = pasteboard.changeCount
        func idFor(_ generation: Int) -> String { "r8-\(mix.rawValue)-\(timing.rawValue)-\(run)-\(generation)" }
        func isViewer(_ generation: Int) -> Bool { mix == .ownAfterViewer && generation % 2 == 0 }
        let cycles = 50
        var generationSince: [UInt64] = []
        var handles: [UInt] = []
        func handle(_ id: String) -> UInt {
            (rig.host.view(id: id) as? GhosttySurfaceView)?.surfaceHandle.map { UInt(bitPattern: $0) } ?? 0
        }
        func open(_ generation: Int) throws -> OpenSurface {
            let link = ScriptedLink()
            // As a remote program would: a background (`OSC 11`) and a title every 2 ms
            // and a bell every 20 ms, each naming the generation that sent it, and for a
            // viewer a clipboard write (`OSC 52`) naming it too. The background's red
            // byte is the generation, its green byte the marker.
            let background = String(format: "rgb:%02x/%02x/%02x", generation, Self.r8BackgroundMarker, run)
            let clipboard = isViewer(generation)
                ? "\u{1B}]52;c;\(Data("written by g\(generation)".utf8).base64EncodedString())\u{07}" : ""
            link.generate(everyMilliseconds: 2) { tick in
                let bell = tick % 10 == 0 ? "\u{07}" : ""
                return .data(Array("\u{1B}]11;\(background)\u{07}\(clipboard)\u{1B}]2;g\(generation)-\(tick)\u{07}\(bell)line \(tick)\r\n".utf8))
            }
            let surface = try rig.open(id: idFor(generation), link: link, imposeOnResize: false,
                                       viewer: isViewer(generation))
            generationSince.append(now())
            handles.append(handle(idFor(generation)))
            return surface
        }
        func heldBackground(_ generation: Int) -> Int? {
            Self.r8Generation(of: (rig.host.view(id: idFor(generation)) as? GhosttySurfaceView)?.programBackground)
        }

        // Which generation's background the host holds for the surface shown now,
        // sampled on every title the host reports and on a 1 ms main queue timer.
        let backgrounds = R8BackgroundSamples(host: rig.host, idFor: idFor)
        rig.events.onTitleSample = { [weak backgrounds] in backgrounds?.sample() }
        let sampler = DispatchSource.makeTimerSource(queue: .main)
        sampler.schedule(deadline: .now(), repeating: .milliseconds(1))
        sampler.setEventHandler { [weak backgrounds] in MainActor.assumeIsolated { backgrounds?.sample() } }
        sampler.resume()
        defer {
            sampler.cancel()
            rig.events.onTitleSample = nil
        }

        var current = try open(0)
        backgrounds.shown(generation: 0, at: generationSince[0])
        var destroyed: [(id: String, generation: Int, at: UInt64)] = []
        var notLive = 0
        for generation in 1...cycles {
            // Live: the host holds this generation's own background (a viewer reports
            // no title, so the background is the sign for both kinds).
            if !(await waitUntil(2) { heldBackground(generation - 1) == generation - 1 }) { notLive += 1 }
            // Hide (bridge first, as the host does), then show, at the time measured.
            current.close()
            destroyed.append((idFor(generation - 1), generation - 1, now()))
            switch timing {
            case .sameTurnNoDrain, .sameTurn:
                current = try open(generation)
            case .nextTurn:
                current = try await onNextMainTurn { try open(generation) }
            }
            backgrounds.shown(generation: generation, at: generationSince[generation])
        }
        _ = await waitUntil(2) { heldBackground(cycles) == cycles }
        try await Task.sleep(for: .milliseconds(500))
        current.close()
        destroyed.append((idFor(cycles), cycles, now()))
        try await Task.sleep(for: .seconds(2))

        // Late: an event naming a destroyed id after its destruction. Cross talk: a
        // title of one generation reported under the id of another.
        var late = 0, crossTitles = 0
        let events = rig.events
        for entry in destroyed {
            late += events.all.filter { $0.id == entry.id && $0.at > entry.at }.count
        }
        var foreign: [String] = []
        var crossSamples: [String] = []
        var crossOnReusedAddress = 0
        var cyclesWithCrossedTitle = Set<String>()
        for title in events.titles {
            guard title.title.hasPrefix("g"), let sent = Int(title.title.dropFirst().prefix { $0 != "-" }) else {
                foreign.append("\(title.id)=\(title.title.debugDescription)")
                continue
            }
            guard title.id != idFor(sent) else { continue }
            crossTitles += 1
            cyclesWithCrossedTitle.insert(title.id)
            let receiver = destroyed.firstIndex { $0.id == title.id } ?? cycles
            let reused = receiver > 0 && sent < handles.count && handles[sent] == handles[receiver]
            if reused { crossOnReusedAddress += 1 }
            if crossSamples.count < 6 {
                let age = (Int64(title.at) - Int64(generationSince[receiver])) / 1_000_000
                crossSamples.append("\(title.id)<-\(title.title)(msAfterCreation=\(age),sameHandleAsSender=\(reused))")
            }
        }
        // Every clipboard write of this run is a viewer's, which its own surface refuses:
        // any change of the pasteboard is a write that reached another surface.
        let pasteboardWrites = pasteboard.changeCount - changeCount
        let reusedHandles = (1..<handles.count).filter { handles[$0] == handles[$0 - 1] }.count
        report("""
            \(prefix) crossTitleSamples=\(crossSamples.joined(separator: ",")) \
            crossBackgroundSamples=\(backgrounds.crossedExamples.joined(separator: ",")) \
            creationsOnThePreviousSurfacesAddress=\(reusedHandles)/\(handles.count - 1) \
            crossTitlesOnAReusedAddress=\(crossOnReusedAddress)
            """)
        report("\(prefix) titlesNotFromTheStream=\(foreign.count) samples=\(foreign.prefix(4).joined(separator: ","))")
        let kinds = Dictionary(grouping: events.all, by: \.kind).mapValues(\.count)
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        report("""
            \(prefix) cycles=\(cycles) notLive=\(notLive) events[\(kinds)] lateForDestroyedIds=\(late) \
            crossTitles=\(crossTitles) cyclesWithCrossTitle=\(cyclesWithCrossedTitle.count) \
            backgroundSamples=\(backgrounds.samples) crossBackgroundSamples=\(backgrounds.crossed) \
            cyclesWithCrossBackground=\(backgrounds.cyclesCrossed.count) foreignBackgrounds=\(backgrounds.foreign) \
            crossClipboardWrites=\(pasteboardWrites) pasteboardNow=\((pasteboard.string(forType: .string) ?? "nil").debugDescription) \
            after2s[\(Census.take().describe(against: before))]
            """)
        if timing != .sameTurnNoDrain {
            #expect(crossTitles == 0)
            #expect(backgrounds.crossed == 0)
            #expect(pasteboardWrites == 0)
        }
    }
}

/// The grids a pane's grid claimed.
@MainActor
private final class ClaimLog {
    private(set) var grids: [TerminalSize] = []
    func add(_ grid: TerminalSize) { grids.append(grid) }
}

/// R8's record of which generation's background the host holds for the surface shown.
@MainActor
private final class R8BackgroundSamples {
    private let host: GhosttySurfaceHost
    private let idFor: (Int) -> String
    private var generation = 0
    private var since: UInt64 = 0
    private(set) var samples = 0
    private(set) var crossed = 0
    private(set) var foreign = 0
    private(set) var cyclesCrossed = Set<Int>()
    private(set) var crossedExamples: [String] = []

    init(host: GhosttySurfaceHost, idFor: @escaping (Int) -> String) {
        self.host = host
        self.idFor = idFor
    }

    /// The surface of `generation`, created at `at`, is the one shown from now on.
    func shown(generation: Int, at: UInt64) {
        self.generation = generation
        since = at
    }

    func sample() {
        let view = host.view(id: idFor(generation)) as? GhosttySurfaceView
        guard let view, let held = RemoteSurfaceMeasurementTests.r8Generation(of: view.programBackground) else { return }
        samples += 1
        if held == -1 { foreign += 1; return }
        guard held != generation else { return }
        crossed += 1
        cyclesCrossed.insert(generation)
        if crossedExamples.count < 6 {
            let age = (Int64(now()) - Int64(since)) / 1_000_000
            crossedExamples.append("g\(generation)<-bg\(held)(msAfterCreation=\(age))")
        }
    }
}

/// Returns once a block enqueued on the main queue now has run.
@MainActor
private func nextMainTurn() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// Runs `body` on the main queue turn after this one, and returns what it returned.
@MainActor
private func onNextMainTurn(_ body: @escaping @MainActor () throws -> OpenSurface) async throws -> OpenSurface {
    final class Box: @unchecked Sendable { var result: Result<OpenSurface, Error>? }
    let box = Box()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { box.result = Result { try body() } }
            continuation.resume()
        }
    }
    return try box.result!.get()
}

// MARK: - Gate

/// Outside the suite, because a suite's own traits cannot refer to its members.
enum RemoteSurfaceCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["WIETTY_REMOTE_SURFACE_CHECK"] == "1"
    }
}

// MARK: - Surfaces

/// A host of its own, one window, and surfaces opened on it with a bridge each.
@MainActor
private final class SurfaceRig {
    let host: GhosttySurfaceHost
    let window: NSWindow
    let container: SurfaceContainerView?
    let events: HostEvents
    let directory: URL
    let helper: String
    private static var sequence = 70_000

    private init(host: GhosttySurfaceHost, window: NSWindow, container: SurfaceContainerView?,
                 events: HostEvents, directory: URL, helper: String) {
        self.host = host
        self.window = window
        self.container = container
        self.events = events
        self.directory = directory
        self.helper = helper
    }

    /// - Parameter pasteboard: the host's; a private one for a test of the clipboard.
    /// - Parameter drainsOnDestroy: the host's; off only for R8's runs without it.
    static func make(width: CGFloat, height: CGFloat, container wantsContainer: Bool,
                     pasteboard: NSPasteboard = .general, drainsOnDestroy: Bool = true) async throws -> SurfaceRig {
        let directory = TestScratch.root.appendingPathComponent("wietty-step5-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = try GhosttySurfaceHost(pasteboard: pasteboard, drainsOnDestroy: drainsOnDestroy)
        let events = HostEvents()
        events.attach(to: host)
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var container: SurfaceContainerView?
        if wantsContainer, let content = window.contentView {
            let view = SurfaceContainerView()
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            container = view
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        report("STEP5-ENV libghostty \(GhosttySurfaceHost.libraryVersion()) scale \(window.backingScaleFactor) pid \(getpid())")
        return SurfaceRig(host: host, window: window, container: container, events: events,
                          directory: directory, helper: try bundledHelperURL().path)
    }

    /// A bridge for `link` and a surface running the helper pointed at it, shown in the
    /// window. With `imposeOnResize` the server's grid is imposed on the surface, as the
    /// pane would.
    /// With `viewer` the surface is made through the host's viewer entry, with `grid`.
    func open(id: String, link: any TerminalStreamLink, imposeOnResize: Bool = false,
              viewer: Bool = false, grid: OwnPaneGrid? = nil) throws -> OpenSurface {
        Self.sequence += 1
        let path = try LocalSocketPaths.bridge(Self.sequence)
        let bridge = try TerminalBridge(helperSocketPath: path, link: link)
        if imposeOnResize {
            let host = self.host
            bridge.onResize = { cols, rows, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { host.impose(grid: TerminalSize(cols: cols, rows: rows), on: id) }
                }
            }
        }
        do {
            let command = PaneBridges.command(helper: helper, socket: path)
            if viewer {
                try host.createViewerSurface(id: id, command: command, grid: grid)
            } else {
                try host.createSurface(id: id, command: command, directory: directory, title: nil)
            }
        } catch {
            bridge.stop()
            throw error
        }
        let view = host.view(id: id)!
        if let container {
            SurfaceContainer.attach(view, to: container)
            window.contentView?.layoutSubtreeIfNeeded()
        } else {
            view.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
            window.contentView?.addSubview(view)
            window.makeFirstResponder(view)
        }
        return OpenSurface(host: host, id: id, bridge: bridge)
    }

    /// Puts the pane's surface in this rig's container once it exists, as
    /// `RemoteSurfacePane` puts it in the window's pane.
    func attach(_ pane: RemotePane) {
        guard let container, let view = pane.surfaceView, view.superview !== container else { return }
        SurfaceContainer.attach(view, to: container)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The surface's grid once it has not moved for 300 ms.
    func settledGrid(_ id: String) async throws -> TerminalSize {
        var last: TerminalSize?
        var since = now()
        let deadline = now() + 20_000_000_000
        while now() < deadline {
            try await Task.sleep(for: .milliseconds(30))
            let grid = host.size(id: id)
            if grid != last { last = grid; since = now() } else if let grid, now() - since > 300_000_000 { return grid }
        }
        throw Step5Error.neverSettled
    }

    func close() {
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// One shown surface. `close` hides it: the bridge first, then the surface, as
/// `GhosttySurfaceHost.destroySurface` does with the bridges it owns.
@MainActor
private final class OpenSurface {
    let host: GhosttySurfaceHost
    let id: String
    let bridge: TerminalBridge
    private var closed = false

    init(host: GhosttySurfaceHost, id: String, bridge: TerminalBridge) {
        self.host = host
        self.id = id
        self.bridge = bridge
    }

    func close() {
        guard !closed else { return }
        closed = true
        bridge.stop()
        host.destroySurface(id: id)
    }
}

/// Every host callback, with the time it arrived.
@MainActor
private final class HostEvents {
    struct Event {
        let at: UInt64
        let kind: String
        let id: String
    }

    private(set) var all: [Event] = []
    private(set) var titles: [(at: UInt64, id: String, title: String)] = []
    private(set) var firstGrid: [String: UInt64] = [:]
    /// Every grid each surface reported, in order.
    private(set) var grids: [String: [TerminalSize]] = [:]
    /// Called after every title is recorded, for a measurement that samples state then.
    var onTitleSample: (() -> Void)?

    func attach(to host: GhosttySurfaceHost) {
        host.onTitle = { [weak self] id, title in
            self?.record("title", id)
            self?.titles.append((now(), id, title))
            self?.onTitleSample?()
        }
        host.onBell = { [weak self] id in self?.record("bell", id) }
        host.onDesktopNotification = { [weak self] id, _, _ in self?.record("notification", id) }
        host.onResized = { [weak self] id, grid in
            self?.record("grid", id)
            self?.grids[id, default: []].append(grid)
            if self?.firstGrid[id] == nil { self?.firstGrid[id] = now() }
        }
        host.onMetricsChanged = { [weak self] id in self?.record("metrics", id) }
        host.onCloseRequested = { [weak self] id in self?.record("close", id) }
        host.onInput = { [weak self] id in self?.record("input", id) }
    }

    private func record(_ kind: String, _ id: String) {
        all.append(Event(at: now(), kind: kind, id: id))
    }

    func closes(_ id: String) -> Int { all.filter { $0.kind == "close" && $0.id == id }.count }

    func reset() {
        all = []
        titles = []
    }
}

// MARK: - Links

/// An in-process link: what it is told to deliver, on a serial queue of its own, and
/// every byte the bridge sends it recorded.
private final class ScriptedLink: TerminalStreamLink, @unchecked Sendable {
    private nonisolated(unsafe) static let key = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "step5.scripted-link")
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?
    private var endHandler: (@Sendable (TerminalEndReason) -> Void)?
    private var isStarted = false
    private var isStopped = false
    private var sent: [UInt8] = []
    private var timer: DispatchSourceTimer?

    init() { queue.setSpecific(key: Self.key, value: 1) }

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { lock.withLock { endHandler } }
        set { lock.withLock { endHandler = newValue } }
    }

    var started: Bool { lock.withLock { isStarted } }
    var sentSoFar: [UInt8] { lock.withLock { sent } }

    func start() {
        let source: DispatchSourceTimer? = lock.withLock {
            isStarted = true
            return timer
        }
        source?.resume()
    }

    func stop() {
        let (source, wasStarted): (DispatchSourceTimer?, Bool) = lock.withLock {
            isStopped = true
            let source = timer
            timer = nil
            return (source, isStarted)
        }
        // A source never resumed must be resumed before it goes, or libdispatch traps.
        if !wasStarted { source?.resume() }
        source?.cancel()
        if DispatchQueue.getSpecific(key: Self.key) == nil { queue.sync {} }
    }

    func send(_ bytes: [UInt8]) {
        lock.withLock { if isStarted && !isStopped { sent += bytes } }
    }

    func claim(cols: Int, rows: Int) {}

    func takeSent() -> [UInt8] {
        lock.withLock {
            let taken = sent
            sent = []
            return taken
        }
    }

    func deliver(_ message: StreamMessage) {
        queue.async { [self] in
            let handler = lock.withLock { isStopped ? nil : messageHandler }
            handler?(message)
        }
    }

    func end(_ reason: TerminalEndReason) {
        queue.async { [self] in
            let handler = lock.withLock { isStopped ? nil : endHandler }
            handler?(reason)
        }
    }

    /// Delivers `make(tick)` every `milliseconds` from `start()` until `stop()`.
    func generate(everyMilliseconds milliseconds: Int, _ make: @escaping @Sendable (Int) -> StreamMessage) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(milliseconds))
        let tick = Counter()
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let handler = self.lock.withLock { self.isStopped ? nil : self.messageHandler }
            handler?(make(tick.next()))
        }
        lock.withLock { timer = source }
    }
}

/// Hands out one link once, then fresh scripted links that deliver nothing (a retry
/// of R1's pane, which a run should never need).
private final class LinkOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var link: ScriptedLink?
    init(_ link: ScriptedLink) { self.link = link }
    func take() -> any TerminalStreamLink {
        lock.withLock {
            defer { link = nil }
            return link ?? ScriptedLink()
        }
    }
}

/// The links `probedPanes` made, in order.
@MainActor
private final class ProbedLinks {
    var all: [ProbedRemoteLink] = []
}

/// When each step of a link's life happened.
private final class LinkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started: UInt64?
    private var first: UInt64?
    private var snapshotIn: UInt64?
    private var snapshotOut: UInt64?
    private var size = 0

    var startedAt: UInt64? { lock.withLock { started } }
    var firstMessageAt: UInt64? { lock.withLock { first } }
    var snapshotReceivedAt: UInt64? { lock.withLock { snapshotIn } }
    var snapshotWrittenAt: UInt64? { lock.withLock { snapshotOut } }
    var snapshotBytes: Int { lock.withLock { size } }

    func markStarted() { lock.withLock { if started == nil { started = now() } } }
    func markHello() { lock.withLock { if first == nil { first = now() } } }

    func handled(_ message: StreamMessage, from start: UInt64, to end: UInt64) {
        lock.withLock {
            if first == nil { first = start }
            if case let .snapshot(bytes) = message, snapshotIn == nil {
                snapshotIn = start
                snapshotOut = end
                size = bytes.count
            }
        }
    }
}

/// The product's `RemoteSocketLink` to a server on 127.0.0.1, with each callback timed
/// for the probe. Everything else is the product link's own.
private final class ProbedRemoteLink: TerminalStreamLink, @unchecked Sendable {
    let probe = LinkProbe()
    private let link: RemoteSocketLink
    private let lock = NSLock()
    private var messageHandler: (@Sendable (StreamMessage) -> Void)?

    convenience init(port: Int, token: String, session: String) {
        self.init(RemoteSocketLink(
            connection: RemoteConnection(id: UUID(), name: "step5", host: "127.0.0.1", port: port, token: token),
            session: session))
    }

    init(_ link: RemoteSocketLink) {
        self.link = link
        link.onMessage = { [weak self] message in self?.deliver(message) }
    }

    var onMessage: (@Sendable (StreamMessage) -> Void)? {
        get { lock.withLock { messageHandler } }
        set { lock.withLock { messageHandler = newValue } }
    }

    var onEnded: (@Sendable (TerminalEndReason) -> Void)? {
        get { link.onEnded }
        set { link.onEnded = newValue }
    }

    func start() {
        probe.markStarted()
        link.start()
    }

    func stop() { link.stop() }
    func send(_ bytes: [UInt8]) { link.send(bytes) }
    func claim(cols: Int, rows: Int) { link.claim(cols: cols, rows: rows) }

    private func deliver(_ message: StreamMessage) {
        guard let handler = lock.withLock({ messageHandler }) else { return }
        let start = now()
        handler(message)
        probe.handled(message, from: start, to: now())
    }
}

// MARK: - The serving side

/// A hub over libghostty-vt models this rig owns, wired as `GhosttyStack` wires one
/// without a pty (as `Step4bMeasurementTests` does), counting snapshots per session.
private final class StreamRig: @unchecked Sendable {
    let hub = PaneStreamHub(startTimer: true)
    private let lock = NSLock()
    private var models: [String: GhosttyVtScreenModel] = [:]
    private var snapshotCounts: [String: Int] = [:]
    private var claimLog: [TerminalSize] = []
    private var inputLog: [UInt8] = []
    /// A second terminal per session, written and resized as the model is, whose modes,
    /// cursor and viewport the model does not expose.
    private var shadows: [String: GhosttyVtTerminal] = [:]
    /// Every claim the hub applied, in order.
    var claims: [TerminalSize] { lock.withLock { claimLog } }
    /// What the viewers sent as input (the pty's writer would get it), of every session.
    var inputSoFar: [UInt8] { lock.withLock { inputLog } }

    init() {
        hub.onIngest = { [weak self] session, bytes in
            guard let self else { return }
            self.model(session)?.write(bytes)
            self.lock.withLock { self.shadows[session]?.write(bytes) }
        }
        hub.onInput = { [weak self] _, bytes in
            guard let self else { return }
            self.lock.withLock { self.inputLog += bytes }
        }
        hub.onSnapshot = { [weak self] session in
            guard let self, let model = self.model(session) else { return nil }
            let frame = model.snapshotFrame()
            self.lock.withLock { self.snapshotCounts[session, default: 0] += 1 }
            return frame.bytes.isEmpty ? nil : frame
        }
        hub.onRepaint = { [weak self] session in self?.model(session)?.repaintFrame() }
        hub.onAlternateScreen = { [weak self] session in self?.model(session)?.isAlternateScreen ?? false }
        hub.onClaim = { [weak self] session, size in
            guard let self else { return }
            self.lock.withLock {
                self.claimLog.append(size)
                self.shadows[session]?.resize(to: size)
            }
            self.model(session)?.resize(to: size)
        }
        hub.onSessionCensus = { [weak self] in
            guard let self else { return .unknown }
            return .sessions(self.lock.withLock { Set(self.models.keys) })
        }
    }

    func model(_ session: String) -> GhosttyVtScreenModel? { lock.withLock { models[session] } }
    func snapshots(of session: String) -> Int { lock.withLock { snapshotCounts[session, default: 0] } }

    /// - Parameter shadow: also keep a `GhosttyVtTerminal` fed the same, for `shadow(_:_:)`.
    func add(_ session: String, cols: Int, rows: Int, scrollback: Int, shadow: Bool = false) throws {
        let size = TerminalSize(cols: cols, rows: rows)
        let model = try GhosttyVtScreenModel(size: size, scrollbackLines: scrollback, graphemeClustering: true)
        let twin = shadow ? try GhosttyVtTerminal(size: size, scrollbackLines: scrollback, graphemeClustering: true) : nil
        lock.withLock {
            models[session] = model
            shadows[session] = twin
        }
    }

    /// Reads the session's shadow under the lock every write to it takes.
    func shadow<T>(_ session: String, _ body: (GhosttyVtTerminal) -> T) -> T? {
        lock.withLock { shadows[session].map(body) }
    }

    /// Resizes the model and its shadow, as a claim of a viewer not in this measurement
    /// would.
    func resize(_ session: String, to size: TerminalSize) {
        model(session)?.resize(to: size)
        lock.withLock { shadows[session]?.resize(to: size) }
    }

    func takeInput() -> [UInt8] {
        lock.withLock {
            let taken = inputLog
            inputLog = []
            return taken
        }
    }

    /// Lines straight into the model, before any viewer: coloured log lines, or with
    /// `dense` a 256 colour change every eight cells across 119 cells.
    func fill(_ session: String, lines: Int, dense: Bool = false) {
        guard let model = model(session) else { return }
        var from = 0
        while from < lines {
            let count = min(2_000, lines - from)
            let bytes = dense ? Self.denseLines(from: from, count: count) : Self.logLines(from: from, count: count)
            model.write(bytes)
            lock.withLock { shadows[session]?.write(bytes) }
            from += count
        }
    }

    /// Through the hub, as the pty's reader would.
    func write(_ session: String, _ bytes: [UInt8]) { hub.write(session: session, bytes: bytes) }

    /// The session ends: its viewers are sent `ended`, and it leaves the census.
    func end(_ session: String) {
        hub.endViewers(ofSession: session)
        lock.withLock {
            models[session] = nil
            shadows[session] = nil
        }
    }

    static func logLines(from: Int, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 120)
        for n in from..<(from + count) {
            let line = "\u{1B}[2m2026-11-26 12:00:\(n % 60 + 10)\u{1B}[0m \u{1B}[32mINFO\u{1B}[0m "
                + "worker[\(n % 97)] processed item \(n) in \(n % 1000) ms, queue depth \(n % 31), status ok\r\n"
            out += Array(line.utf8)
        }
        return out
    }

    static func denseLines(from: Int, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 300)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
        for n in from..<(from + count) {
            var line: [UInt8] = []
            for cell in 0..<119 {
                if cell % 8 == 0 { line += Array("\u{1B}[38;5;\((n + cell) % 256)m".utf8) }
                line.append(alphabet[(n + cell) % alphabet.count])
            }
            line += Array("\u{1B}[0m\r\n".utf8)
            out += line
        }
        return out
    }
}

/// A `RemoteServer` on 127.0.0.1 with a throwaway token, over a `StreamRig`.
@MainActor
private final class ServerRig {
    let rig: StreamRig
    private(set) var server: RemoteServer
    let port: Int
    let token: String
    private let accessToken: RemoteAccessToken
    private let suite: String
    private let defaults: UserDefaults
    private let store: ProjectStore

    private init(server: RemoteServer, store: ProjectStore, port: Int, accessToken: RemoteAccessToken,
                 suite: String, defaults: UserDefaults, rig: StreamRig) {
        self.server = server
        self.store = store
        self.port = port
        self.accessToken = accessToken
        token = accessToken.value
        self.suite = suite
        self.defaults = defaults
        self.rig = rig
    }

    static func start() async throws -> ServerRig {
        let suite = "test.step5.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let token = RemoteAccessToken(defaults: defaults)
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        let rig = StreamRig()
        let server = RemoteServer(store: store, streamer: rig.hub, token: token, host: "127.0.0.1", port: 0)
        await server.start()
        let port = try #require(await Self.boundPort(server))
        return ServerRig(server: server, store: store, port: port, accessToken: token, suite: suite,
                         defaults: defaults, rig: rig)
    }

    private static func boundPort(_ server: RemoteServer) async -> Int? {
        let deadline = Date().addingTimeInterval(10)
        while server.boundPort == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return server.boundPort
    }

    /// The server goes away (every viewer's socket closes) and the hub and its models
    /// stay, as when the other Mac's network drops or Wietty restarts its server there.
    func drop() { server.stop() }

    /// A new server on the same port, the same hub and the same token.
    func restart() async throws {
        server = RemoteServer(store: store, streamer: rig.hub, token: accessToken, host: "127.0.0.1", port: port)
        await server.start()
        _ = try #require(await Self.boundPort(server))
    }

    /// A store holding one connection to this server, with its secret in memory.
    func connections() -> (store: RemoteConnectionsStore, connection: RemoteConnection) {
        let connections = RemoteConnectionsStore(defaults: defaults, secretStore: PaneSecrets())
        let connection = RemoteConnection(id: UUID(), name: "Loopback", host: "127.0.0.1", port: port, token: token)
        connections.add(connection)
        return (connections, connection)
    }

    func stop() {
        server.stop()
        rig.hub.stop()
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

/// Feeds a session through the hub at a set rate, 4 KiB at a time, from a thread of
/// its own, until stopped.
private final class PacedFeeder: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var total = 0
    private let done = DispatchSemaphore(value: 0)

    var fed: Int { lock.withLock { total } }

    init(rig: StreamRig, session: String, bytesPerSecond: Int) {
        let source = StreamRig.logLines(from: 0, count: 12_000)
        let thread = Thread { [self] in
            let chunk = 4096
            let start = now()
            var offset = 0
            var sent = 0
            while lock.withLock({ running }) {
                let due = start + UInt64(Double(sent) / Double(bytesPerSecond) * 1e9)
                let current = now()
                if current < due { usleep(useconds_t(min(10_000, (due - current) / 1000))); continue }
                if offset + chunk > source.count { offset = 0 }
                rig.write(session, Array(source[offset..<(offset + chunk)]))
                offset += chunk
                sent += chunk
                lock.withLock { total = sent }
            }
            done.signal()
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        let wasRunning = lock.withLock {
            let was = running
            running = false
            return was
        }
        if wasRunning { done.wait() }
    }
}

private final class ClientCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var messageCount = 0
    private var data = 0
    private var snapshotCount = 0
    private var sawData = false
    private var reason: TerminalEndReason?

    var messages: Int { lock.withLock { messageCount } }
    var dataBytes: Int { lock.withLock { data } }
    var snapshots: Int { lock.withLock { snapshotCount } }
    var endText: String { lock.withLock { reason.map { "\($0)" } ?? "none" } }

    func received(_ message: StreamMessage) {
        lock.withLock {
            messageCount += 1
            switch message {
            case let .data(bytes): data += bytes.count
            case .snapshot: snapshotCount += 1
            default: break
            }
        }
    }

    /// True the first time only.
    func firstData() -> Bool {
        lock.withLock {
            defer { sawData = true }
            return !sawData
        }
    }

    func ended(_ value: TerminalEndReason) { lock.withLock { reason = value } }
}

private final class EndBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TerminalEndReason?
    var reason: TerminalEndReason? { lock.withLock { stored } }
    var text: String { reason.map { "\($0)" } ?? "none" }
    func set(_ value: TerminalEndReason) { lock.withLock { stored = value } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

// MARK: - The main queue's heartbeat

/// A 1 ms timer on the main queue, recording each gap between two fires.
@MainActor
private final class Heartbeat {
    private var timer: DispatchSourceTimer?
    private var last: UInt64 = 0
    private var samples: [(at: UInt64, gap: UInt64)] = []

    func start() {
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.beat() } }
        source.resume()
        timer = source
    }

    private func beat() {
        let current = now()
        if last != 0 { samples.append((current, current - last)) }
        last = current
    }

    /// The longest gap that overlapped `[from, to]`.
    func maxGap(from: UInt64, to: UInt64) -> UInt64 {
        samples.filter { $0.at >= from && $0.at &- $0.gap <= to }.map(\.gap).max() ?? 0
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - What a process holds

/// The test host's descendants by name, its descriptors, threads and memory, and the
/// bridge socket files of this process.
private struct Census {
    let login: Int, bash: Int, helper: Int, other: Int, zombies: Int
    let descriptors: Int
    let threads: Int
    let sockets: Int
    let resident: UInt64
    let footprint: UInt64

    static func take() -> Census {
        let rows = processRows()
        var children: [Int32: [ProcessRow]] = [:]
        for row in rows { children[row.ppid, default: []].append(row) }
        var stack = [getpid()]
        var found: [ProcessRow] = []
        while let pid = stack.popLast() {
            for child in children[pid] ?? [] where child.command != "ps" {
                found.append(child)
                stack.append(child.pid)
            }
        }
        let names = found.map { ($0.command as NSString).lastPathComponent }
        let memory = processMemory()
        let directory = NSTemporaryDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let sockets = files.filter { $0.hasPrefix("wty-\(getpid())-") || $0.hasPrefix(".wty-") }.count
        return Census(login: names.filter { $0 == "login" }.count,
                      bash: names.filter { $0 == "bash" }.count,
                      helper: names.filter { $0 == "wietty-pty" }.count,
                      other: names.filter { !["login", "bash", "wietty-pty"].contains($0) }.count,
                      zombies: found.filter { $0.state.hasPrefix("Z") }.count,
                      descriptors: descriptorCount(), threads: threadCount(), sockets: sockets,
                      resident: memory.resident, footprint: memory.footprint)
    }

    func describe(against before: Census) -> String {
        """
        login=\(login) bash=\(bash) wietty-pty=\(helper) otherChildren=\(other) zombies=\(zombies) \
        fds=\(descriptors)(\(signed(descriptors - before.descriptors))) \
        threads=\(threads)(\(signed(threads - before.threads))) bridgeSockets=\(sockets) \
        residentMiB=\(mib(resident))(\(signedMiB(resident, before.resident))) \
        footprintMiB=\(mib(footprint))(\(signedMiB(footprint, before.footprint)))
        """
    }

    private func signed(_ value: Int) -> String { value >= 0 ? "+\(value)" : "\(value)" }
}

private struct ProcessRow {
    let pid: Int32
    let ppid: Int32
    let state: String
    let command: String
}

private func processRows() -> [ProcessRow] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-A", "-o", "pid=,ppid=,stat=,comm="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
        return ProcessRow(pid: pid, ppid: ppid, state: String(parts[2]),
                          command: String(parts[3]).trimmingCharacters(in: .whitespaces))
    }
}

private func descriptorCount() -> Int {
    let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return -1 }
    let capacity = Int(size) / MemoryLayout<proc_fdinfo>.stride + 64
    var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
    let used = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &buffer, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
    return Int(used) / MemoryLayout<proc_fdinfo>.stride
}

private func threadCount() -> Int {
    var list: thread_act_array_t?
    var count: mach_msg_type_number_t = 0
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return -1 }
    for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                  vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
    return Int(count)
}

private func processMemory() -> (resident: UInt64, footprint: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (info.resident_size, info.phys_footprint)
}

/// The receive queue of the client's socket to `port` and the send queue of the
/// server's socket for it, from `netstat`; 0 when not found.
private func tcpQueues(port: Int) -> (clientRecvQ: Int, serverSendQ: Int) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    process.arguments = ["-an", "-p", "tcp"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (0, 0) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var recv = 0, send = 0
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6, parts[5] == "ESTABLISHED", let recvQ = Int(parts[1]), let sendQ = Int(parts[2]) else { continue }
        if parts[4] == "127.0.0.1.\(port)" { recv = max(recv, recvQ) }
        if parts[3] == "127.0.0.1.\(port)" { send = max(send, sendQ) }
    }
    return (recv, send)
}

// MARK: - Helpers

private enum Step5Error: Error {
    case neverSettled
}

/// Prints a result line on a line of its own, flushed.
private func report(_ line: String) {
    print(line)
    fflush(stdout)
}

private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func ms(_ nanoseconds: UInt64) -> String { String(format: "%.1f", Double(nanoseconds) / 1e6) }

private func mib(_ bytes: UInt64) -> String { String(format: "%.1f", Double(bytes) / 1_048_576) }
private func mib(_ bytes: Int) -> String { mib(UInt64(max(0, bytes))) }

private func signedMiB(_ value: UInt64, _ base: UInt64) -> String {
    String(format: "%+.1f", (Double(value) - Double(base)) / 1_048_576)
}

/// Nearest rank median, p95 and max, in milliseconds.
private func summary(_ samples: [UInt64]) -> String {
    guard !samples.isEmpty else { return "n=0" }
    let sorted = samples.sorted()
    func quantile(_ q: Double) -> UInt64 {
        let rank = Int((q * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
    return "median=\(ms(quantile(0.5)))ms p95=\(ms(quantile(0.95)))ms max=\(ms(sorted[sorted.count - 1]))ms n=\(sorted.count)"
}

/// Control bytes made visible: ESC as `\e`, others as `\xNN`.
private func escaped(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x1B: out += "\\e"
        case 0x00..<0x20, 0x7F: out += String(format: "\\x%02x", scalar.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out.isEmpty ? "(none)" : out
}

/// Trailing spaces and trailing blank rows are not content.
private func normalised(_ rows: [String]) -> [String] {
    var rows = rows.map { row -> String in
        var row = row
        while row.hasSuffix(" ") { row.removeLast() }
        return row
    }
    while rows.last?.isEmpty == true { rows.removeLast() }
    return rows
}

private func lastLines(_ rows: [String], _ count: Int) -> String {
    normalised(rows).filter { !$0.isEmpty }.suffix(count).map { $0.debugDescription }.joined(separator: " | ")
}

private func firstDifference(_ surface: [String], _ model: [String]) -> String {
    let count = max(surface.count, model.count)
    let differing = (0..<count).filter { index in
        (index < surface.count ? surface[index] : nil) != (index < model.count ? model[index] : nil)
    }
    guard let first = differing.first else { return "none" }
    return """
        \(differing.count) of \(count) lines differ (surface \(surface.count), model \(model.count)); \
        first at \(first): surface \((first < surface.count ? surface[first] : "<none>").debugDescription) \
        model \((first < model.count ? model[first] : "<none>").debugDescription)
        """
}

/// Polls `condition` on the main actor until it holds or `seconds` pass.
@MainActor
private func waitUntil(_ seconds: Double, poll: Duration = .milliseconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = now() + UInt64(seconds * 1e9)
    while now() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: poll)
    }
    return condition()
}

/// Runs a blocking body on a thread of its own.
private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try body() }) }
    }
}

// MARK: - The SwiftUI pane

/// Whether the probe shows the pane, and which session.
@MainActor @Observable
private final class PaneShown {
    var on = true
    var session: RemoteSessionRef

    init(session: RemoteSessionRef) { self.session = session }
}

/// The pane, as `RightTerminalView` puts it: keyed by its session, and gone when hidden.
private struct PaneProbe: View {
    let shown: PaneShown
    let panes: RemotePanes

    var body: some View {
        if shown.on {
            RemoteSurfacePane(panes: panes, session: shown.session)
                .id(shown.session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }
}

/// Secrets in memory, so the keychain is never touched.
private final class PaneSecrets: SecretStore {
    private var secrets: [String: String] = [:]
    func secret(for key: String) -> String? { secrets[key] }
    func setSecret(_ value: String, for key: String) { secrets[key] = value }
    func removeSecret(for key: String) { secrets[key] = nil }
}
