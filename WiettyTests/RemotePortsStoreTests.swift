import Testing
import Foundation
@testable import Wietty

@MainActor
@Suite struct RemotePortsStoreTests {
    @Test func defaultsMatchTheServerPorts() {
        let store = ProjectStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, service: FakeTerminalService())
        #expect(store.mcpPort == MCPServerHost.defaultPort)
        #expect(store.remotePort == RemoteServer.defaultPort)
        #expect(store.remoteEnabled == false)
    }

    @Test func persistsPortsAndEnabledAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store1 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store1.mcpPort = 8001
        store1.remotePort = 8002
        store1.remoteEnabled = true
        let store2 = ProjectStore(defaults: defaults, service: FakeTerminalService())
        #expect(store2.mcpPort == 8001)
        #expect(store2.remotePort == 8002)
        #expect(store2.remoteEnabled == true)
    }

    @Test func clampsOutOfRangePorts() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ProjectStore(defaults: defaults, service: FakeTerminalService())
        store.mcpPort = 80          // below the allowed range
        store.remotePort = 70_000   // above the allowed range
        #expect(store.mcpPort == ProjectStore.portRange.lowerBound)
        #expect(store.remotePort == ProjectStore.portRange.upperBound)
    }
}
