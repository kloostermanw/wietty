import WiettyShared

/// How this framework sees the package's types, so a test can compare it with how the
/// test bundle sees them. `WiettyShared` is linked into the core, the app and the test
/// bundle, and a copy of its framework is embedded in both the app and the test bundle.
/// Should dyld ever load two of those images, each side would have its own type
/// metadata and casts between them would fail without a word.
package enum WiettySharedIdentity {
    package static var streamMessage: ObjectIdentifier { ObjectIdentifier(StreamMessage.self) }
    package static var terminalStreamConnection: ObjectIdentifier {
        ObjectIdentifier(TerminalStreamConnection.self)
    }
}
