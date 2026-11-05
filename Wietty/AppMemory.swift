import Foundation
import Darwin
import Observation

/// The app's own memory use, as the status bar shows it.
///
/// The figure is the physical footprint (`phys_footprint` from `TASK_VM_INFO`),
/// which is what Activity Monitor's Memory column reports for a process. It covers
/// this process only: the shells and agents in its terminals are processes of their
/// own and are not included.
enum AppMemory {
    /// This process's physical footprint in bytes, or nil if the kernel would not say.
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Binary units, as Activity Monitor uses while labelling them MB and GB: whole
    /// megabytes below a gigabyte, one decimal above.
    static func format(bytes: UInt64) -> String {
        let mebibyte = 1024.0 * 1024.0
        let megabytes = Double(bytes) / mebibyte
        if megabytes < 1024 { return "\(Int(megabytes)) MB" }
        return String(format: "%.1f GB", megabytes / 1024)
    }
}

/// Samples `AppMemory.footprintBytes` on a timer so the status bar can show it.
/// Owned by `ContentView` for the window's life.
@MainActor
@Observable
final class AppMemoryMonitor {
    private(set) var footprintBytes: UInt64?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Reads once straight away, then every `interval`. Calling it again does nothing.
    func start(interval: Duration = .seconds(2)) {
        guard task == nil else { return }
        task = Task { [weak self] in
            // `self` is only borrowed for each sample, not held across the sleep, so
            // the loop does not keep the monitor alive.
            while !Task.isCancelled, self != nil {
                self?.sample()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func sample() {
        let bytes = AppMemory.footprintBytes()
        // Written only on change, so an idle app does not redraw the bar.
        if bytes != footprintBytes { footprintBytes = bytes }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
