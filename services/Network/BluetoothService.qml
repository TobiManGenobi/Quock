pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Bluetooth adapter state — polls `bluetoothctl show` every 5 s and toggles
// via `bluetoothctl power on|off`.
//
// Plain argv, no shell: `bluetoothctl show` prints the whole adapter state,
// and the single `Powered:` field this service cares about is picked out in
// JS below rather than by piping through `grep` and `awk`. That pipeline cost
// three extra processes per poll (grep, awk, and the `sh` that hosted them).
Singleton {
    id: root

    property bool enabled: false
    property bool ready: false
    // Set when the last toggle command failed. Surfaced rather than swallowed:
    // a failed toggle previously left the icon showing the state the user asked
    // for, with no indication anything went wrong, until the next 5 s poll
    // quietly reverted it.
    property bool lastToggleFailed: false

    function toggle(): void {
        // Busy guard, matching the poll timer: a rapid second click used to
        // restart toggleProc while the first bluetoothctl was still in flight,
        // so the two commands raced and the resulting state was neither
        // requested one.
        if (toggleProc.running) return
        const turningOn = !enabled
        toggleProc.command = turningOn
            ? ["bluetoothctl", "power", "on"]
            : ["bluetoothctl", "power", "off"]
        toggleProc.running = true
        enabled = turningOn // optimistic update
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        // Busy guard: one reusable Process. A tick that arrives while
        // bluetoothctl is still running is dropped rather than queued behind
        // it, so a hung bluetoothctl cannot silently stop the state updating.
        onTriggered: {
            if (pollProc.running) return
            pollProc.running = true
        }
    }

    Process {
        id: pollProc
        command: ["bluetoothctl", "show"]
        // `bluetoothctl show` is silent on stderr when it succeeds (verified:
        // 0 bytes on this machine), so the `2>/dev/null` this replaces has
        // nothing left to do and stderr is left to default handling.
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.enabled = root._parsePowered(text) === "yes"
                root.ready = true
            }
        }
    }

    Process {
        id: toggleProc
        running: false
        // exitCode lives on Process.exited, NOT on StdioCollector (which only
        // exposes text/data plus the streamFinished signal). Re-read the truth
        // immediately instead of waiting up to 5 s for the next poll: on
        // failure this restores the real state and flags the error; on success
        // it confirms the optimistic update straight away.
        onExited: (exitCode, exitStatus) => {
            root.lastToggleFailed = exitCode !== 0
            root.pollProc.running = true
        }
    }

    Component.onCompleted: pollProc.running = true

    // Extract the `Powered:` field exactly as the old
    // `grep 'Powered:' | awk '{print $2}'` did: the FIRST line containing
    // "Powered:" (grep printed every match, but `bluetoothctl show` has only
    // one such line), then its second whitespace-separated field (awk $2).
    // Returns "" when no line matches, which compares false — the same result
    // the empty pipeline produced.
    function _parsePowered(out: string): string {
        const lines = out.split("\n")
        for (let i = 0; i < lines.length; i++) {
            if (lines[i].indexOf("Powered:") === -1) continue
            const fields = lines[i].trim().split(/\s+/)
            return fields.length > 1 ? fields[1] : ""
        }
        return ""
    }
}
