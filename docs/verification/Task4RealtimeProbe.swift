// Compile alongside DeviceOutput.swift; no app or package target changes are needed.
// Usage: task4-probe <exact device name> [cycles=8] [running seconds=2]
import Foundation

@main struct Task4RealtimeProbe {
    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, arguments.count <= 4 else {
            throw failure(1) // Explicit device selection is mandatory.
        }
        let cycles = arguments.count > 2 ? Int(arguments[2]) ?? 0 : 8
        let seconds = arguments.count > 3 ? Int(arguments[3]) ?? 0 : 2
        guard (1...100).contains(cycles), (1...60).contains(seconds) else { throw failure(2) }
        let matches = try DeviceOutput.availableDevices().filter { $0.name == arguments[1] }
        guard matches.count == 1, let device = matches.first, device.isSupportedForStageA else {
            throw failure(3)
        }
        print("PROBE pid=\(ProcessInfo.processInfo.processIdentifier) rate=\(device.sampleRate) cycles=\(cycles)")
        // Allows a launched profiler to initialize before the first source is created.
        try await Task.sleep(for: .seconds(3))
        var output: DeviceOutput? = DeviceOutput()
        defer { output?.dispose() }
        for cycle in 0..<cycles {
            try await output!.prepare(uid: device.uid, sampleRate: device.sampleRate)
            try await Task.sleep(for: .milliseconds(100))
            guard !output!.isRunning, output!.verifiedDeviceID == device.deviceID,
                  output!.callbackCount == 0 else { throw failure(4) }
            try output!.startSilence()
            try await Task.sleep(for: .seconds(seconds))
            guard output!.isRunning, output!.verifiedDeviceID == device.deviceID,
                  output!.callbackCount > 0 else { throw failure(5) }
            let mode = cycle % 4
            if mode == 3 {
                weak let released = output
                output = nil // Main-thread last release must stop/dispose before returning.
                guard released == nil else { throw failure(6) }
                print("PROBE cycle=\(cycle) owner-release-returned")
                try await Task.sleep(for: .seconds(1))
                print("PROBE cycle=\(cycle) ownerReleased; verify synchronous disposal with lifetime instrumentation")
                output = DeviceOutput()
            } else {
                let begin = ContinuousClock.now
                if mode == 1 { output!.dispose() } else { output!.stop() }
                let elapsed = begin.duration(to: .now)
                let count = output!.callbackCount
                try await Task.sleep(for: .seconds(1))
                guard !output!.isRunning, output!.verifiedDeviceID == nil,
                      output!.callbackCount == count else { throw failure(7) }
                print("PROBE cycle=\(cycle) mode=\(mode) callbacks=\(count) stopCall=\(elapsed) stable=1s PASS")
            }
        }
        output?.dispose()
        output = nil
        try await Task.sleep(for: .seconds(1))
        print("PROBE PASS")
    }

    static func failure(_ code: Int) -> NSError { NSError(domain: "Task4RealtimeProbe", code: code) }
}
