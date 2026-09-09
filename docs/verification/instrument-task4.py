#!/usr/bin/env python3
"""Create a diagnostic-only copy. Never overwrite product sources.

Usage: python3 docs/verification/instrument-task4.py /private/tmp/task4-output
Compile the generated DeviceOutput.swift with Task4RealtimeProbe.swift.
The added atomics perturb render timing: this build verifies lifetime, not performance.
"""
import hashlib
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[2]
source = root / "Sources/MonoOtoAudio/DeviceOutput.swift"
destination = Path(sys.argv[1]).resolve()
if destination == root or root in destination.parents:
    raise SystemExit("Diagnostic output must be outside the repository")
text = source.read_text()
digest = hashlib.sha256(source.read_bytes()).hexdigest()


def replace_once(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit(f"Source changed; audit instrumentation anchor: {old[:100]}")
    text = text.replace(old, new)


replace_once(
    "    func stop() { engine?.stop() }",
    '''    func stop() {
        engine?.stop()
        renderState?.auditBoundary("stop-returned")
    }''',
)
replace_once(
    "        engine?.stop()\n        diagnosticTimer?.cancel()",
    '''        engine?.stop()
        renderState?.auditBoundary("dispose-stop-returned")
        diagnosticTimer?.cancel()''',
)
replace_once(
    "        if let source { engine?.detach(source) }\n        source = nil\n        engine = nil",
    '''        if let source { engine?.detach(source) }
        renderState?.auditDetached = true
        renderState?.auditBoundary("detach-returned")
        source = nil
        engine = nil
        renderState?.auditBoundary("engine-released")''',
)
replace_once(
    "    init() { count.initialize(to: 0); fault.initialize(to: 0) }",
    '''    private let auditActive = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let auditExited = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    var auditDetached = false // Control-side only; render never reads this field.
    init() {
        count.initialize(to: 0); fault.initialize(to: 0)
        auditActive.initialize(to: 0); auditExited.initialize(to: 0)
        print("LIFETIME created state=\\(Unmanaged.passUnretained(self).toOpaque()) main=\\(Thread.isMainThread)")
    }
    func auditBoundary(_ event: String) {
        let active = OSAtomicAdd64Barrier(0, auditActive)
        let exited = OSAtomicAdd64Barrier(0, auditExited)
        print("LIFETIME \\(event) state=\\(Unmanaged.passUnretained(self).toOpaque()) main=\\(Thread.isMainThread) active=\\(active) entered=\\(callbackCount) exited=\\(exited)")
        precondition(Thread.isMainThread && active == 0 && UInt64(exited) == callbackCount)
    }''',
)
replace_once(
    "    deinit { count.deinitialize(count: 1); count.deallocate(); fault.deinitialize(count: 1); fault.deallocate() }",
    '''    deinit {
        auditBoundary("state-deinit")
        precondition(auditDetached)
        print("LIFETIME deinit-stack \\(Thread.callStackSymbols.joined(separator: " | "))")
        count.deinitialize(count: 1); count.deallocate()
        fault.deinitialize(count: 1); fault.deallocate()
        auditActive.deinitialize(count: 1); auditActive.deallocate()
        auditExited.deinitialize(count: 1); auditExited.deallocate()
    }''',
)
replace_once(
    "        OSAtomicIncrement64Barrier(count)\n        let status = renderDeviceSilence",
    '''        OSAtomicIncrement64Barrier(auditActive)
        defer {
            OSAtomicIncrement64Barrier(auditExited)
            OSAtomicDecrement64Barrier(auditActive)
        }
        OSAtomicIncrement64Barrier(count)
        let status = renderDeviceSilence''',
)
destination.mkdir(parents=True, exist_ok=False)
with (destination / "DeviceOutput.swift").open("x") as generated:
    generated.write(text)
with (destination / "source-sha256.txt").open("x") as manifest:
    manifest.write(digest + "\n")
print(f"Diagnostic copy generated; original SHA256={digest}")
