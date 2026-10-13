pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Screen brightness as a percentage (0..100), for the dock's OSD. The OSD
// fires on a change in EITHER direction — brighter or dimmer — so a volume-
// style keypress is always acknowledged; the animation does not encode
// direction.
//
// The backlight device and its max value are resolved by ONE probe at
// start-up; after that the level is READ EVENT-DRIVENLY — a FileView watches
// the device's sysfs `brightness` node and the dock is notified only when the
// kernel says that node actually changed. This is the specified fallback path
// after `brightnessctl watch` proved unusable on this machine: against
// intel_backlight (brightnessctl 0.5) it prints its device banner and returns
// immediately with exit code 0, so it can never report a change.
//
// WHY THE WATCH WORKS: `watchChanges` is backed by inotify on Linux, and the
// sysfs attribute node does emit IN_MODIFY when a write lands on it (verified
// directly against /sys/class/backlight/intel_backlight/brightness). So the
// steady state spawns ZERO processes: the only `brightnessctl` use left is the
// one-shot `max_brightness` probe.
//
// PERCENTAGE: always brightness/max_brightness, because the sysfs node reports
// a raw level rather than a percentage.
//
// API NOTE: FileView.text is a FUNCTION, not a property ("Due to technical
// limitations, text() could not be a property"). Read it by calling it, and
// hook `onTextChanged` for updates. `textChanged` fires per documented
// behaviour of the function-property, so the watcher reload-then-reads.
//
// ORDERING NOTE: every Process/FileView child is declared BEFORE any function
// or binding that references it. See the same note in AudioService.qml — a
// binding reading a later-declared child's id is evaluated during construction
// and throws "Cannot read property 'running' of undefined" at scene load.
Singleton {
    id: root

    // Set by the dock. While false this service is completely idle: it runs no
    // probe, spawns no processes and watches nothing. A Quickshell singleton is
    // created on first reference and then lives for the session, so gating the
    // WORK here (rather than trying to avoid referencing it) is what actually
    // stops all cost when the OSD is switched off. Setting the watch path to ""
    // is what unloads the file and tears the inotify watch down.
    property bool active: false

    // 0..100. Negative until the first successful read, which is also what
    // keeps that first read from being mistaken for a change.
    property real brightness: -1
    property bool brightnessReady: false

    // Emitted when the brightness CHANGES in either direction (up or down),
    // with the new percentage (0..100) as its payload. Only a change is
    // reported, never a direction. The initial read does not emit (see
    // _applyLevel). The payload lets the dock size its OSD from the value.
    //
    // Named `brightnessAdjusted`, NOT `brightnessChanged`: the `brightness`
    // property already synthesises a `brightnessChanged` signal, and declaring
    // one by that name is an invalid override of it (verified — the config
    // fails to load with "Duplicate signal name").
    signal brightnessAdjusted(level: real)

    // "none" until the probe resolves, then a backlight device name.
    property string _device: "none"
    property real _maxBrightness: 0
    property bool _hasBrightnessctl: false

    readonly property bool _supported: root._device !== "none"

    // ─── Probe (one-shot — the ONLY process this service ever spawns) ──
    // Picks the first backlight node that exposes `brightness`, and reports its
    // name, its max value, and whether brightnessctl is installed:
    //   "<device> <max> <0|1>"     or     "none 0 0"
    // brightnessctl is retained solely to read `max_brightness`; the level
    // itself now comes from the watched file.
    property string _probeCmd: "d=\"\"; for p in /sys/class/backlight/*; do "
        + "if [ -r \"$p/brightness\" ]; then d=$p; break; fi; done; "
        + "if [ -z \"$d\" ]; then echo 'none 0 0'; else "
        + "b=${d##*/}; m=$(cat \"$d/max_brightness\" 2>/dev/null || echo 0); "
        + "if command -v brightnessctl >/dev/null 2>&1; then c=1; else c=0; fi; "
        + "echo \"$b $m $c\"; fi"

    Process {
        id: probeProc
        command: ["sh", "-c", root._probeCmd]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const t = text.trim().split(/\s+/)
                const dev = t.length > 0 ? t[0] : "none"
                const max = t.length > 1 ? parseFloat(t[1]) : 0
                const tool = t.length > 2 ? t[2] === "1" : false
                if (dev && dev !== "none" && max > 0) {
                    root._device = dev
                    root._maxBrightness = max
                    root._hasBrightnessctl = tool
                    if (root.active) root._start()
                } else {
                    console.warn("[dock Brightness] no usable backlight device; OSD disabled")
                }
            }
        }
    }

    // ─── Watched level (no process; inotify-driven) ─────────────────
    // Path stays "" until the device is known AND active is true, so an
    // unknown device or a disabled OSD means no watch and no reads at all.
    // Declared before every function/binding that touches it (see header).
    FileView {
        id: brightnessFile
        path: root.active && root._supported
            ? "/sys/class/backlight/" + root._device + "/brightness"
            : ""
        watchChanges: true
        preload: true
        // Documented pattern: a change on disk only signals, so reload and
        // let onTextChanged deliver the new level.
        onFileChanged: brightnessFile.reload()
        onTextChanged: root._applyLevel(root._parseLevel(brightnessFile.text()))
    }

    // ─── Behaviour ─────────────────────────────────────────────────
    onActiveChanged: {
        if (root.active) root._start()
        else root._stop()
    }

    function _start(): void {
        if (!root._supported) {
            // Device not known yet — the probe resolves it, then calls back in.
            probeProc.running = true
            return
        }
        // Setting the path above loads (and preloads) the node, so the first
        // value arrives via onTextChanged. Re-read only if it was already
        // loaded, e.g. when re-enabling the OSD on an already-watched device.
        if (brightnessFile.loaded) brightnessFile.reload()
    }

    function _stop(): void {
        // Clearing the path unloads the file and removes the inotify watch.
    }

    // Manual nudge, retained for callers that want a fresh read on demand.
    function refreshBrightness(): void {
        if (!root.active || !root._supported) return
        brightnessFile.reload()
    }

    // The backlight node reports a raw level, so the percentage needs the max
    // that was captured by the probe.
    function _parseLevel(raw: string): real {
        if (raw === undefined || raw === null) return -1
        const m = /([0-9]+(?:\.[0-9]+)?)/.exec(String(raw).trim())
        return m ? parseFloat(m[1]) : -1
    }

    function _applyLevel(level: real): void {
        if (level < 0) return
        if (!(root._maxBrightness > 0)) return
        const pct = Math.max(0, Math.min(100, Math.round(level * 100 / root._maxBrightness)))
        const prev = root.brightness
        root.brightness = pct
        root.brightnessReady = true
        // Any real change raises the OSD, in either direction. The first read
        // has prev < 0 and therefore cannot qualify.
        if (prev >= 0 && pct !== prev) root.brightnessAdjusted(pct)
    }

    Component.onCompleted: {
        if (root.active) probeProc.running = true
    }
}
