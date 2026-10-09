import Foundation

/// What a program says it is doing, in the Program Status Protocol (`OSC 7501`).
///
/// The protocol is a draft by Mitchell Hashimoto
/// (https://gist.github.com/mitchellh/7acae3abd8355c1c00287d67e96c913a, revision
/// 0.1). Section numbers in the comments below refer to it.
enum ProgramStatusState: String, Equatable, Sendable {
    case idle, working, done, blocked, error
}

/// What a `blocked` program is waiting for (section 6).
enum ProgramStatusKind: String, Equatable, Sendable {
    case permission, question, auth
}

/// One record as the terminal stores it: exactly the keys of the last report that
/// addressed its id, already validated and decoded.
struct ProgramStatusRecord: Equatable, Sendable {
    var state: ProgramStatusState
    var kind: ProgramStatusKind? = nil
    var progress: Int? = nil
    var app: String? = nil
    var title: String? = nil
    var msg: String? = nil
}

/// One `OSC 7501` report, parsed from the text between `7501;` and the terminator.
///
/// Untrusted input from a program that already controls the screen (section 8), so
/// every rule is applied here, before anything reaches a stored record: a report
/// that breaks a limit, carries text that does not decode, or names no state this
/// build knows is `nil`, and nothing of it is applied.
enum ProgramStatusReport: Equatable, Sendable {
    /// Replaces the record at `id`, or the root record when `id` is nil.
    case set(id: String?, ProgramStatusRecord)
    /// Removes the record at `id` and every record beneath it, or every record on
    /// the terminal when `id` is nil.
    case clear(id: String?)

    // Section 9. The size of the whole sequence is the scanner's to enforce, since
    // only it sees the introducer and the terminator.
    private static let keyLimit = 16
    private static let appLimit = 32
    private static let idLimit = 128
    private static let idSegmentLimit = 32
    private static let idDepthLimit = 8
    private static let msgEncodedLimit = 2732
    private static let msgDecodedLimit = 2048
    private static let titleEncodedLimit = 256
    private static let titleDecodedLimit = 192

    static func parse(_ body: String) -> ProgramStatusReport? {
        var pairs: [String: String] = [:]
        for pair in body.split(separator: ":", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // A limit discards the report; a malformed pair only loses itself.
            guard key.utf8.count <= keyLimit else { return nil }
            guard !key.isEmpty, key.unicodeScalars.allSatisfy(isKeyScalar),
                  value.unicodeScalars.allSatisfy(isValueScalar) else { continue }
            pairs[key] = value
        }

        var id: String?
        if let raw = pairs["id"] {
            guard isValidId(raw) else { return nil }
            id = raw
        }
        // A state this build does not know is ignored rather than read as `idle`,
        // so a state added later never shows up as something else here.
        guard let rawState = pairs["state"] else { return nil }
        if rawState == "clear" { return .clear(id: id) }
        guard let state = ProgramStatusState(rawValue: rawState) else { return nil }

        var record = ProgramStatusRecord(state: state)
        if state == .blocked, let kind = pairs["kind"] {
            record.kind = ProgramStatusKind(rawValue: kind)
        }
        if state == .working || state == .blocked, let progress = pairs["progress"],
           progress.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
           let value = Int(progress), (0...100).contains(value) {
            record.progress = value
        }
        if let app = pairs["app"] {
            guard app.utf8.count <= appLimit else { return nil }
            if !app.isEmpty, app.unicodeScalars.allSatisfy(isNameScalar) { record.app = app }
        }
        if let title = pairs["title"] {
            guard let text = decodeText(title, encodedLimit: titleEncodedLimit,
                                        decodedLimit: titleDecodedLimit) else { return nil }
            record.title = text.isEmpty ? nil : text
        }
        if let msg = pairs["msg"] {
            guard let text = decodeText(msg, encodedLimit: msgEncodedLimit,
                                        decodedLimit: msgDecodedLimit) else { return nil }
            record.msg = text.isEmpty ? nil : text
        }
        return .set(id: id, record)
    }

    /// `id := segment ("/" segment)*`, `segment := [A-Za-z0-9_.+-]{1,32}`, within
    /// the limits of section 9. Failing it ignores the report rather than falling
    /// back to the root, which would let a typo overwrite the program's own record.
    private static func isValidId(_ id: String) -> Bool {
        guard id.utf8.count <= idLimit else { return false }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count <= idDepthLimit else { return false }
        return segments.allSatisfy {
            (1...idSegmentLimit).contains($0.utf8.count) && $0.unicodeScalars.allSatisfy(isNameScalar)
        }
    }

    /// Standard base64 of UTF-8, padding optional (section 3), with the encoded
    /// size checked before anything is decoded. Nil discards the whole report: text
    /// that does not decode, is too long, or carries a control character.
    private static func decodeText(_ encoded: String, encodedLimit: Int, decodedLimit: Int) -> String? {
        guard encoded.utf8.count <= encodedLimit else { return nil }
        var padded = encoded
        switch encoded.utf8.count % 4 {
        case 0: break
        case 2: padded += "=="
        case 3: padded += "="
        default: return nil
        }
        guard let data = Data(base64Encoded: padded), data.count <= decodedLimit,
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard !text.unicodeScalars.contains(where: isControl) else { return nil }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisibleFormatting($0) }))
    }

    private static func isKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar)
    }

    /// `[A-Za-z0-9_.,+/=-]`. Excludes `:` and `;`, which is why nothing in the
    /// protocol needs escaping.
    private static func isValueScalar(_ scalar: Unicode.Scalar) -> Bool {
        isNameScalar(scalar) || scalar == "," || scalar == "/" || scalar == "="
    }

    /// `[A-Za-z0-9_.+-]`, the set ids and `app` are spelled in.
    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                           || "_.+-".unicodeScalars.contains(scalar))
    }

    /// C0, DEL and C1 (section 3).
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// Text direction overrides and other invisible formatting (Unicode category
    /// Cf), which section 8 says to disarm before showing text outside the grid: a
    /// right-to-left override can make a message read as something it does not say.
    /// The zero width joiner is kept, because emoji sequences are built from it and
    /// it reorders nothing.
    private static func isInvisibleFormatting(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format && scalar.value != 0x200D
    }
}
