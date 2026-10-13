pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Default-sink mute state — polls `pactl` every 3 s and toggles via
// `pactl set-sink-mute @DEFAULT_SINK@ toggle`.
// This half is NOT OSD-only: DockControls.qml reads `muted` for the mute
// button and calls `toggleMute()`. That is why this file lives in
// `services/` rather than in `services/OSD/`.
//
// Also tracks the default sink's VOLUME (0..maxLevel — 150, since a PipeWire
// sink overamplifies) so the dock can raise an OSD when it changes — in EITHER
// direction, up or down. The OSD confirms that the system saw the keypress; it
// deliberately does not encode direction.
//
// WHY THIS POLLS INSTEAD OF WATCHING `pactl subscribe`
// `pactl subscribe` is a perfectly good event feed — it prints a line per
// PulseAudio event, and `Event 'change' on sink #N` arrives promptly on a
// volume change (both verified directly against this machine's PulseAudio).
// But it cannot be consumed here: this Quickshell build does not deliver a
// long-lived child's stdout incrementally. Measured with an isolated config
// run via `qs -p`:
//   - `StdioCollector.onDataChanged` fires only when the stream ENDS. A
//     throwaway process printing one line every 2 s produced exactly one
//     dataChanged, at exit, carrying all six lines.
//   - `SplitParser` with `onRead` (the documented streaming API) never fired
//     at all for the same long-running process.
// So a `pactl subscribe` watcher can only ever tell us it died; it can never
// report a change. It is therefore not started — a permanent, silent child
// process that costs a PulseAudio connection and can never do anything.
// The volume is polled every 200 ms instead, which is cheap and is the
// fallback this was specified to allow.
//
// ORDERING NOTE: every Process/Timer is declared BEFORE any function or
// binding that references it. A binding reading a later-declared child's id
// is evaluated while the component is still being constructed, when that child
// does not exist yet — which throws "Cannot read property 'running' of
// undefined" at scene load. The Qt lint tool reports this as
// missing-property; in this file it was a real runtime error.
Singleton {
    id: root

    property bool muted: false
    property bool ready: false

    // ─── Volume ────────────────────────────────────────────────────
    // 0..maxLevel (150): a sink amplifies past 100, see `maxLevel` below.
    // Negative until the first successful read, which is also what
    // keeps that first read from being mistaken for a change.
    property real volume: -1
    property bool volumeReady: false

    // The highest level a sink can be driven to, in percent.
    //
    // A PulseAudio/PipeWire sink amplifies beyond 100%: `wpctl set-volume
    // @DEFAULT_AUDIO_SINK@ 1.5` is legal and `wpctl get-volume` then reports
    // `Volume: 1.50`, which _parseVolume turns into 150. So 100 is NOT the
    // ceiling and must not be treated as one — clamping there silently drops
    // every reading in the overamplified range back to the same value.
    //
    // This belongs here, next to the parse that produces these numbers, so the
    // legal range and the parser cannot drift apart. Consumers that need to
    // normalise a level (the dock's OSD) read this rather than hardcoding 100.
    // Brightness is a different quantity with a genuinely natural 0..100
    // maximum, so BrightnessService deliberately does NOT share this.
    readonly property real maxLevel: 150

    // Emitted when the volume CHANGES in either direction (up or down), with
    // the new level (0..maxLevel) as its payload. Increases and decreases produce
    // the identical OSD; only a change is reported, never a direction. The
    // initial read does not emit (see _applyVolume).
    //
    // The payload exists so the dock can size its OSD from the value rather
    // than a fixed length: it is what makes every repeated step produce a
    // different extension length.
    //
    // Named `volumeAdjusted`, NOT `volumeChanged`: the `volume` property
    // already synthesises a `volumeChanged` signal, and declaring one by that
    // name is an invalid override of it (the same clash that forced
    // `brightnessAdjusted` in BrightnessService.qml).
    signal volumeAdjusted(level: real)

    // Which CLI can answer a volume query: "wpctl" | "pactl" | "none".
    // Resolved once, by a single probe, at start-up.
    property string _backend: "none"
    property bool _hasWpctl: false
    property bool _hasPactl: false
    // Absolute paths reported by that same probe, so every later command is
    // plain argv naming an executable that is resolved ONCE. A bare name
    // would be re-searched down PATH on every query, and `sh -c` costs an
    // extra fork plus a failed-execve PATH walk for `sh` itself each time.
    // Empty until the probe answers; see _pactlArgs() for the fallback.
    property string _wpctlPath: ""
    property string _pactlPath: ""
    // Set by the dock. Gates ONLY the volume work: the mute API below is used
    // by DockControls regardless, so this service is always instantiated, and
    // without this gate an OSD that is switched off would still cost a
    // `wpctl get-volume` every 200 ms for nothing.
    property bool active: false


    // ─── Mute ──────────────────────────────────────────────────────
    // Poll every 3 s for the default sink's mute state, and toggle it on
    // demand via `toggleMute()` below. The toggle is what the dock's mute
    // button calls, so it must stay reachable: it is declared AFTER
    // `muteProc` (see the ORDERING NOTE in the header).
    Timer {
        interval: 3000
        running: true
        repeat: true
        onTriggered: pollProc.running = true
    }

    Process {
        id: pollProc
        command: root._pactlArgs(["get-sink-mute", "@DEFAULT_SINK@"])
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.muted = text.trim().includes("yes")
                root.ready = true
            }
        }
    }

    Process {
        id: muteProc
        command: root._pactlArgs(["set-sink-mute", "@DEFAULT_SINK@", "toggle"])
        running: false
    }

    // ─── Backend probe (one-shot) ──────────────────────────────────
    // Prints the ABSOLUTE PATH of wpctl, then of pactl, one per line
    // ("none" when absent). Runs once. `command -v` has already done the
    // PATH walk here, so the paths are kept, not just the presence flags.
    property string _probeCmd: "command -v wpctl 2>/dev/null || echo none; "
        + "command -v pactl 2>/dev/null || echo none"

    Process {
        id: probeProc
        command: ["sh", "-c", root._probeCmd]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n").map(l => l.trim())
                const wp = lines[0] || ""
                const pa = lines[1] || ""
                root._hasWpctl = wp.length > 0 && wp !== "none"
                root._hasPactl = pa.length > 0 && pa !== "none"
                if (root._hasWpctl) root._wpctlPath = wp
                if (root._hasPactl) root._pactlPath = pa
                root._backend = root._hasWpctl ? "wpctl" : (root._hasPactl ? "pactl" : "none")
                if (root._backend === "none") {
                    console.warn("[dock Audio] neither wpctl nor pactl found; volume OSD disabled")
                } else {
                    root._startVolumePolling()
                }
            }
        }
    }

    // ─── Volume query (one reusable Process for every read) ─────────
    Process {
        id: volumeQueryProc
        running: false
        // Plain argv, no `sh -c`: wpctl takes its arguments directly, so the
        // shell was pure overhead — one fork per query plus a PATH walk.
        command: root._backend === "wpctl"
            ? root._wpctlArgs(["get-volume", "@DEFAULT_AUDIO_SINK@"])
            : root._pactlArgs(["get-sink-volume", "@DEFAULT_SINK@"])
        stdout: StdioCollector {
            onStreamFinished: root._applyVolume(root._parseVolume(text))
        }
    }

    // 200 ms, not 1000 ms: a held volume key steps several times a second, so
    // a 1 s poll can start and end entirely between two samples and the OSD
    // never fires at all.
    //
    // 200 ms is NOT negotiable down to 400 ms, even though 400 ms halves this
    // poll's cost. Measured on this machine by logging every `volumeAdjusted`
    // emission from this file and driving bursts through `wpctl set-volume`:
    //
    //   6 steps at 250 ms spacing: 200 ms -> 5 emissions, 400 ms -> 5 emissions
    //     (identical; the one skipped level is aliasing between sample rate
    //     and key-repeat rate, not a lost trigger)
    //   10 steps inside 0.4 s (~40 ms spacing, faster than any real key
    //   repeat): 200 ms -> 6 emissions, 400 ms -> 4 emissions
    //
    // The second case is the one that matters: the OSD is required to respond
    // to EVERY step, and 400 ms samples slower than the burst it has to catch,
    // so it drops triggers. The saving (about 2.5 processes/sec) does not
    // justify regressing that requirement.
    //
    // The busy guard is what makes this affordable: `wpctl get-volume`
    // measures ~13 ms on this machine, i.e. ~7% duty cycle at 200 ms (the
    // original ~15 ms / ~7% estimate still holds; 13 ms is a tighter
    // measurement of the same thing). A poll that arrives while a query is in
    // flight is dropped rather than queued, and the level it would have
    // reported is picked up by the NEXT poll, so a dropped sample costs
    // latency, never a missed net change.
    Timer {
        id: volumePoll
        interval: 200
        repeat: true
        running: false
        onTriggered: root.refreshVolume()
    }
    onActiveChanged: root._startVolumePolling()



    // ─── Behaviour ─────────────────────────────────────────────────
    // Toggle the default sink's mute state. This is the public entry point
    // for the dock's mute button (DockControls.qml), which calls it on click.
    //
    // `muted` is flipped optimistically so the button's icon responds on the
    // same click rather than up to 3 s later; the 3 s poll above then confirms
    // (or corrects) it from the real sink state.
    function toggleMute(): void {
        muteProc.running = true
        muted = !muted // optimistic update
    }

    // Build a wpctl argv: absolute path + args, no shell.
    // Falls back to the bare name only if the probe has not answered yet
    // (QProcess resolves it through the same PATH the probe searched).
    function _wpctlArgs(args: list<string>): list<string> {
        return [root._wpctlPath || "wpctl"].concat(args)
    }

    // Same for pactl. The mute poll starts at Component.onCompleted, which
    // is BEFORE the probe can have run (the probe is gated on `active`), so
    // the bare-name fallback is load-bearing here, not dead code: with the
    // OSD disabled the probe never runs and the mute poll still has to work.
    function _pactlArgs(args: list<string>): list<string> {
        return [root._pactlPath || "pactl"].concat(args)
    }

    // Begin the volume poll, resolving the backend first if that has not
    // happened yet.
    //
    // The probe cannot simply be kicked off from Component.onCompleted alone:
    // the dock sets `active` through a Binding, which lands AFTER completion,
    // so at completion time `active` is still false and the probe would never
    // start. Starting it from here — whichever comes first — is what makes the
    // gate safe to flip at any time.
    function _startVolumePolling(): void {
        if (!root.active) {
            volumePoll.running = false
            return
        }
        if (root._backend === "none") {
            if (!probeProc.running) probeProc.running = true
            return
        }
        if (!root.volumeReady) root.refreshVolume()
        volumePoll.running = true
    }

    // Busy guard so a slow query can never stack up processes: this is one
    // reusable Process, and a request while it is already running is dropped
    // rather than queued.
    function refreshVolume(): void {
        if (!root.active || root._backend === "none") return
        if (volumeQueryProc.running) return
        volumeQueryProc.running = true
    }

    function _parseVolume(raw: string): real {
        if (raw === undefined || raw === null || String(raw).length === 0) return -1
        const t = String(raw)
        if (root._backend === "wpctl") {
            // "Volume: 0.90" — a 0..1 fraction.
            const m = /Volume:\s*([0-9]*\.?[0-9]+)/.exec(t)
            return m ? Math.round(parseFloat(m[1]) * 100) : -1
        }
        // "Volume: front-left: 58984 /  90% / -2.74 dB" — the raw sample count
        // is NOT the percentage, so match an explicit "%" rather than the first
        // number on the line.
        const m = /([0-9]+)\s*%/.exec(t)
        return m ? parseInt(m[1], 10) : -1
    }

    function _applyVolume(v: real): void {
        if (v < 0) return
        const prev = root.volume
        root.volume = v
        root.volumeReady = true
        // Any real change raises the OSD, in either direction. The first read
        // has prev < 0 and therefore cannot qualify.
        if (prev >= 0 && v !== prev) root.volumeAdjusted(v)
    }

    Component.onCompleted: {
        pollProc.running = true
        if (root.active) probeProc.running = true
    }
}