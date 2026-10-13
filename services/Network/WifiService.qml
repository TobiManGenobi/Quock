pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// WiFi radio state — polls nmcli every 5 s and toggles via `nmcli radio wifi`.
//
// Plain argv throughout: nmcli takes its arguments directly, so `sh -c` was
// pure overhead — an extra fork per poll plus a failed-execve PATH walk for
// `sh` itself on every call.
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
        // restart toggleProc while the first nmcli was still in flight, so the
        // two commands raced and the resulting state was neither requested one.
        if (toggleProc.running) return
        const turningOn = !enabled
        toggleProc.command = turningOn
            ? ["nmcli", "radio", "wifi", "on"]
            : ["nmcli", "radio", "wifi", "off"]
        toggleProc.running = true
        enabled = turningOn // optimistic update
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        // Busy guard: one reusable Process. A tick that arrives while nmcli is
        // still running is dropped rather than queued behind it, so a hung or
        // slow nmcli cannot silently stop Wi-Fi state updating.
        onTriggered: {
            if (pollProc.running) return
            pollProc.running = true
        }
    }

    Process {
        id: pollProc
        command: ["nmcli", "radio", "wifi"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.enabled = text.trim() === "enabled"
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
}
