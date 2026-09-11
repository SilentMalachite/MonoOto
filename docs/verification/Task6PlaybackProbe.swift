// Diagnostic runner; see stage-a.md for the compile command.
// --list is read-only. Playback requires explicit --uid and --ear plus --file or --tone.
// Printed times are control observations, not physical silence or callback-duration evidence.
import Foundation
import MonoOtoCore
@testable import MonoOtoAudio

@main struct Task6PlaybackProbe {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        do {
            if arguments == ["--list"] {
                for device in try DeviceOutput.availableDevices() {
                    print("device uid=\(device.uid) name=\(device.name) rate=\(device.sampleRate) channels=\(device.channels) supported=\(device.isSupportedForStageA)")
                }
                return
            }
            guard let uid = value("--uid"), !uid.isEmpty,
                  let earText = value("--ear"), let ear = HearingEar(rawValue: earText),
                  value("--file") != nil || arguments.contains("--tone"),
                  let seconds = Double(value("--seconds") ?? "5"), seconds.isFinite, seconds > 0, seconds <= 3_600,
                  let cycles = Int(value("--cycles") ?? "1"), (1...1_000).contains(cycles) else {
                print("Usage: --list | --uid UID --ear left|right (--file PATH | --tone) [--seconds 5] [--cycles 1] [--pause]")
                return
            }
            let output = DeviceOutput()
            let controller = PlaybackController(output: output, devices: { try DeviceOutput.availableDevices() })
            if let path = value("--file") { try await controller.open(url: URL(fileURLWithPath: path)) }
            controller.selectOutput(uid: uid, ear: ear)
            await controller.waitUntilSettled()
            print("probe os=\(ProcessInfo.processInfo.operatingSystemVersionString) cycles=\(cycles) ear=\(ear.rawValue) gainDB=-18")
            let clock = ContinuousClock()
            for cycle in 0..<cycles {
                if arguments.contains("--tone") { try await controller.playConfirmationTone() }
                else { try await controller.play() }
                let start = clock.now
                var paused = false
                while controller.phase == .running || controller.phase == .preparing {
                    let elapsed = start.duration(to: clock.now)
                    if elapsed >= .seconds(seconds) { break }
                    if arguments.contains("--pause"), !paused, elapsed >= .seconds(seconds / 2) {
                        controller.pause()
                        await controller.waitUntilSettled()
                        print("cycle=\(cycle) pause phase=\(controller.phase) position=\(controller.positionSeconds)")
                        try await controller.play()
                        paused = true
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let sample = controller.diagnostics
                print("cycle=\(cycle) accepted=\(sample.totalAccepted) rendered=\(sample.renderedFrames) underruns=\(sample.underruns) high_water=\(sample.queueHighWater) pending=\(sample.pendingCount) entries=\(sample.callbackEntries) exits=\(sample.callbackExits)")
                let callbacksBefore = output.callbackCount
                let stopAt = clock.now
                controller.stop()
                let gateReturned = stopAt.duration(to: clock.now)
                await controller.waitUntilSettled()
                let settled = stopAt.duration(to: clock.now)
                let callbacksAfter = output.callbackCount
                print("cycle=\(cycle) stop_return=\(gateReturned) settled=\(settled) callbacks_before=\(callbacksBefore) callbacks_after=\(callbacksAfter) phase=\(controller.phase) error=\(controller.lastError != nil)")
                if let error = controller.lastError { print("stopped_reason=\(error)"); throw PlaybackControllerError.sourceFailed }
            }
            controller.stop()
            await controller.waitUntilSettled()
        } catch {
            // Avoid printing arbitrary Foundation/decode errors that can carry a file path.
            if let error = error as? PlaybackControllerError { print("probe_failed=\(error.localizedDescription)") }
            else { print("probe_failed=音源・出力機器・終了条件を確認してください。") }
            exit(1)
        }
    }
}
