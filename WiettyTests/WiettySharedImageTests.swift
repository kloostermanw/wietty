import Foundation
import MachO
import Testing
import WiettyShared
import WiettyCore

/// `WiettyShared` is linked into three images and its framework is copied into both the
/// app and the test bundle. One image of it must be loaded, or the core and the tests
/// would each have their own `StreamMessage`.
@Suite struct WiettySharedImageTests {
    @Test func theCoreAndTheTestsSeeTheSamePackageTypes() {
        #expect(WiettySharedIdentity.streamMessage == ObjectIdentifier(StreamMessage.self))
        #expect(WiettySharedIdentity.terminalStreamConnection == ObjectIdentifier(TerminalStreamConnection.self))
    }

    @Test func exactlyOneImageOfThePackageIsLoaded() {
        var loaded: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if (path as NSString).lastPathComponent.contains("WiettyShared") { loaded.append(path) }
        }
        #expect(loaded.count == 1, "loaded: \(loaded)")
    }
}
