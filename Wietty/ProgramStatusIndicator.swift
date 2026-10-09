import Foundation

/// What a sidebar row draws for the program status its terminal reported
/// (`OSC 7501`), decided apart from the view so it is asserted in tests rather than
/// only visible when a program reports something.
///
/// An `idle` program draws nothing: at rest is what a terminal is when nothing is
/// said at all, and a marker on every row with an agent at its prompt would say
/// nothing the green glyph does not.
struct ProgramStatusIndicator: Equatable {
    enum Glyph: Hashable {
        case spinner
        case symbol(String)
    }

    /// Roles rather than colours, so the view picks the colour and a test can tell
    /// the four apart without comparing `Color` values.
    enum Tint: Equatable {
        case neutral, attention, success, failure
    }

    let glyph: Glyph
    /// Words beside the glyph, for the states worth the width.
    let text: String?
    let tint: Tint
    /// The program's own message, which a row is too narrow to show. Named by the
    /// record's title when it has one, because a program with several records uses
    /// it to say which part of the work this is.
    let tooltip: String

    init?(_ record: ProgramStatusRecord) {
        switch record.state {
        case .idle:
            return nil
        case .working:
            glyph = .spinner
            text = record.progress.map { "\($0)%" }
            tint = .neutral
        case .blocked:
            switch record.kind {
            case .permission: glyph = .symbol("hand.raised.fill")
            case .question: glyph = .symbol("questionmark.bubble.fill")
            case .auth: glyph = .symbol("key.fill")
            case nil: glyph = .symbol("pause.circle.fill")
            }
            text = "needs you"
            tint = .attention
        case .done:
            glyph = .symbol("checkmark.circle.fill")
            text = nil
            tint = .success
        case .error:
            glyph = .symbol("xmark.octagon.fill")
            text = nil
            tint = .failure
        }
        let words = record.msg ?? record.stateDescription
        tooltip = record.title.map { "\($0): \(words)" } ?? words
    }
}

extension ProgramStatusRecord {
    /// The state in words, for a record that carries no message of its own: the
    /// row's tooltip and a banner both need something to say, and an empty banner
    /// says less than none.
    var stateDescription: String {
        switch state {
        case .idle: return "Ready"
        case .working: return "Working"
        case .blocked:
            switch kind {
            case .permission: return "Waiting for your permission"
            case .question: return "Waiting for your answer"
            case .auth: return "Waiting for you to sign in"
            case nil: return "Waiting on you"
            }
        case .done: return "Finished"
        case .error: return "Failed"
        }
    }
}
