pragma ComponentBehavior: Bound

import qs
import qs.services.Audio
import qs.services.Desktop
import qs.services.OSD
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Wayland
import Quickshell.Io

Scope {
    id: root
    // pinnedOnStartup conflicts with hoverToReveal — let hover-reveal win
    // so the dock actually hides when the user asks it to.
    property bool pinned: (Config.options?.dock?.pinnedOnStartup ?? false)
        && !(Config.options?.dock?.hoverToReveal ?? false)
    readonly property string position: Config.options?.dock?.position ?? "bottom"
    readonly property bool isVertical: root.position === "left" || root.position === "right"
    readonly property bool isTop: root.position === "top"
    readonly property bool isLeft: root.position === "left"

    // Configurable layout metrics (fall back to Appearance defaults).
    readonly property real _margin: Config.options?.dock?.margin ?? Appearance.sizes.elevationMargin
    readonly property real _spacing: Config.options?.dock?.spacing ?? 2
    readonly property real _padding: Config.options?.dock?.padding ?? 5

    // Niri compositor blur: switches the layer namespace to one your niri config
    // blurs (background-effect { blur true }) and renders the panel translucent so
    // the blur shows through.
    readonly property bool _blur: Config.options?.dock?.blur ?? false
    readonly property bool _useExclusive: (Config.options?.dock?.exclusiveZone ?? 0) > 0
    // Effective background opacity: blur mode auto-glass when user left it opaque.
    readonly property real _effectiveBgOpacity: {
        const op = Config.options?.dock?.backgroundOpacity ?? 1.0
        return root._blur ? (op >= 1.0 ? 0.6 : op) : op
    }
    // Key to force panel recreation when position or blur namespace changes
    // Master opt-in gate (mock: dockMayBeEnabled). When false the dock
    // creates no panel surface at all.
    readonly property bool _enabled: (Config.options?.dock?.enabled ?? true)

    property string _positionKey: `${root.position}_${root._blur}`
    // ─── Volume / brightness OSD ───────────────────────────────────
    // Two 0..1 drivers live on the OUTER Scope, so every per-output panel
    // animates from one shared trigger (and one debounce) instead of each
    // panel running its own pair of timers. Panels multiply these by their own
    // configured growWidth.
    //
    // ANY CHANGE is handled: AudioService/BrightnessService emit
    // volumeAdjusted/brightnessAdjusted for rises AND falls alike.
    //
    // WHY THE LENGTH CARRIES THE LEVEL (and not just "grow to full")
    // The OSD used to animate a fixed 0 → 1 ramp. That works exactly once:
    // by the time the second step of a held key arrives the driver is already
    // parked at 1, so `up.start()` animates 1 → 1 and not a single pixel
    // moves. Measured: six consecutive 5% steps produced six triggers, every
    // one of them with grow == 1.000 — the OSD looked completely dead while
    // the volume was in fact climbing. The same held for 1% steps and for
    // brightness (event-driven, six steps, six triggers, all at grow 1.000).
    //
    // Retargeting the driver at `level / max` instead fixes that for every
    // step: consecutive triggers necessarily carry DIFFERENT levels (a trigger
    // is only emitted when the level actually changed), so consecutive steps
    // always land on different lengths. A fixed-length bar could never do
    // that; a level-proportional bar can, and it also tells the user where
    // their volume/brightness actually ended up.
    //
    // There is deliberately NO floor: the mapping is a straight 0..max → 0..1
    // — max is the ceiling of the quantity being shown (150 for volume,
    // 100 for brightness; see _osdGrowForLevel) — so a 0% level targets 0 and
    // the dock background is left completely untouched — it is then exactly
    // as wide as the resting dock. A level-proportional bar needs no minimum
    // to stay strictly monotonic in the level, which is all the held-key
    // argument above actually requires.
    readonly property bool _osdEnabled: (Config.options?.dock?.osd?.enabled ?? true)
        && !Appearance.gameModeMinimal

    // The AudioService singleton, held ONCE and read through everywhere else.
    //
    // Quickshell singletons do not resolve from inside a plain JS function, and
    // every unqualified textual reference to one trips a `unqualified` qmllint
    // warning. Both the level ceiling and the mute state are needed, so the
    // singleton is captured in a single binding here and everything downstream
    // reads it via `root._osdAudio`, which IS qualified. One reference instead
    // of two keeps this file's warning count unchanged.
    readonly property var _osdAudio: AudioService

    // Ceiling for the volume OSD, taken from the service that defines the
    // legal range (AudioService.maxLevel = 150, because a PipeWire sink
    // overamplifies). Read as a binding rather than inside the function so the
    // lookup is statically resolved.
    //
    // It lives on `root`, beside the _osd*Grow drivers it feeds, rather than
    // on the per-output dockRoot: the OSD animation state is global, so the
    // ceiling for it belongs here too.
    readonly property real _osdVolumeMaxLevel: root._osdAudio.maxLevel

    // Mute state, for _osdVolumeBand below: a muted sink KEEPS its volume, so
    // the level alone cannot distinguish "muted" from "sitting at that level",
    // which is why the shell script checks it too.
    readonly property bool _osdMuted: root._osdAudio.muted

    property real _osdVolumeGrow: 0
    property real _osdBrightnessGrow: 0

    // 0..max → 0..1, clamped. `max` is the ceiling of the quantity being
    // shown: AudioService.maxLevel (150) for volume, because a sink
    // overamplifies, and 100 for brightness, which has a natural 0..100
    // range. They are deliberately NOT the same number — see maxLevel.
    //
    // Linear, and therefore strictly monotonic in the level: any two triggers
    // at different levels differ in length, which is exactly the property the
    // held-key case depends on (a repeated step must still move the bar).
    // Keep it that way — a curve that flattens at either end would reintroduce
    // "doesn't react if steps are repeated".
    //
    // Level 0 maps to 0: the extra width added to the dock background is then
    // exactly 0, so its width equals panelW and nothing is grown at all. An
    // invalid level (NaN/undefined/negative) also returns 0 for the same
    // reason: an unknown level must not invent a background width.
    function _osdGrowForLevel(level: real, max: real): real {
        if (!(level >= 0)) return 0
        if (!(max > 0)) return 0
        return Math.min(max, Math.max(0, level)) / max
    }

    readonly property int _osdHoldMs: Config.options?.dock?.osd?.holdMs ?? 1500
    // Honour the global animations switch, matching how every other duration
    // in this file is gated.
    readonly property int _osdDurationMs: Appearance.animationsEnabled
        ? (Config.options?.dock?.osd?.durationMs ?? 260)
        : 0

    // ─── OSD level-band colour tint ─────────────────────────────────
    // While the volume/brightness OSD is showing, the dock background is
    // tinted with the SAME colour mako paints that notification's bar in, so
    // the dock and the OSD the user actually sees always agree.
    //
    // ─────────────────────────────────────────────────────────────────
    // !! DUPLICATED FROM MAKO — KEEP IN SYNC !!
    // These tables are a verbatim copy of `~/.config/mako/config`, sections
    // `[app-name=OSD category=volume-*]` and `[app-name=OSD category=brightness-*]`
    // (their `progress-color` values), and of the band thresholds in
    // `~/.config/niri/scripts/volume-osd.sh` (~lines 297-315) and
    // `~/.config/niri/scripts/brightness-osd.sh` (~lines 297-301).
    // mako cannot colour a progress bar by value, so those two scripts send
    // their computed band as the notification CATEGORY and mako matches it
    // against the sections above. If mako's colours or the scripts' thresholds
    // are ever edited, these tables must be edited with them or the dock will
    // disagree with the OSD. Edit them HERE, in one place, only.
    // ─────────────────────────────────────────────────────────────────
    //
    // The colours are kept as the full `#rrggbbaa` string from mako, alpha
    // byte included, so the table stays byte-comparable against the mako config.
    readonly property var _osdVolumeBands: ({
        // progress-color, `[app-name=OSD category=volume-*]`
        low:   "#4a90d950",   // blue
        mid:   "#4eb35650",   // green
        high:  "#e0683f50",   // green turning orange
        max:   "#e04b4550",   // orange turning red
        boost: "#e04b4580",   // >100%: same red, higher alpha
        muted: "#00000050"    // black
    })
    readonly property var _osdBrightnessBands: ({
        // progress-color, `[app-name=OSD category=brightness-*]`
        low:  "#f6c36d20",
        mid:  "#f3c64140",
        high: "#ebca0f60",
        max:  "#dccf0e90"
    })

    // ── Band selection ──────────────────────────────────────────────
    // Mirrors volume-osd.sh:
    //   if muted -> muted; elif pct < 20 -> low; elif pct < 90 -> mid;
    //   elif pct <= 100 -> high; elif pct <= 120 -> max; else -> boost.
    //
    // The level is compared directly, with no rescaling: both shell scripts
    // band on the plain percentage, and the levels arriving here are already
    // integers (AudioService rounds the wpctl fraction to a percent;
    // BrightnessService rounds to a percent), so the shell's integer
    // comparisons reproduce exactly here.
    //
    // Mute is checked FIRST and outranks the level: a muted sink keeps its
    // volume, so the level alone cannot tell "muted" apart from "sitting at
    // that level". volume-osd.sh makes the same check in the same position.
    // `muted` arrives via root._osdMuted — see the note on _osdAudio for why it
    // is a binding rather than a singleton read inside this function.

    function _osdVolumeBand(level: real): string {
        if (root._osdMuted) return "muted"
        const pct = Math.max(0, level)
        if (pct < 20) return "low"
        if (pct < 90) return "mid"
        if (pct <= 100) return "high"
        if (pct <= 120) return "max"
        return "boost"
    }

    // Mirrors brightness-osd.sh:
    //   pct < 34 -> low; pct < 67 -> mid; pct < 100 -> high; else -> max.
    function _osdBrightnessBand(level: real): string {
        const pct = Math.max(0, level)
        if (pct < 34) return "low"
        if (pct < 67) return "mid"
        if (pct < 100) return "high"
        return "max"
    }

    // ── Which tint is showing ───────────────────────────────────────
    // One animated colour per quantity, each set by its own trigger.
    //
    // SIMULTANEOUS VOLUME + BRIGHTNESS — the rule is VOLUME WINS while the
    // volume driver is above zero, brightness otherwise. That is a fixed
    // precedence on the state, not "whatever the binding evaluated last", so
    // it cannot flicker depending on evaluation order; and because a quantity
    // whose grow has decayed to 0 contributes nothing to the tint strength
    // anyway, the losing quantity is already invisible and cannot fight the
    // winner.
    // Deliberately WRITABLE (not readonly): _triggerOsd assigns them, and each
    // is eased toward its new value by the Behavior below.
    property color _osdVolumeBandColor: "transparent"
    property color _osdBrightnessBandColor: "transparent"
    readonly property color _osdBandTint:
        root._osdVolumeGrow > 0 ? root._osdVolumeBandColor : root._osdBrightnessBandColor

    // ── mako colour string → Qt colour ─────────────────────────────
    // Mako (like CSS, and like the band tables above) writes 8-digit hex as
    // #RRGGBBAA. Qt/QML does NOT: `Qt.color` parses an 8-digit hex string as
    // #AARRGGBB. Measured on this machine:
    //     Qt.color("#4eb35650") -> r=179 g=86  b=80 a=78   (i.e. #b356504e)
    //     Qt.color("#504eb356") -> r=78  g=179 b=86 a=80   (i.e. the real #4eb35650)
    // So handing a mako string to Qt verbatim silently ROTATES the bytes: the
    // volume mid band's green would render as a desaturated brown. Every band
    // colour therefore goes through this, which is also the one place the byte
    // order is documented.
    //
    // The tables keep the mako spelling so they stay diffable against
    // ~/.config/mako/config; only the value handed to Qt is reordered.
    function _makoColor(value: string): color {
        const s = String(value).trim()
        // 8 hex digits plus '#' is the only form whose order differs.
        if (s.length === 9 && s.charAt(0) === "#")
            return Qt.color("#" + s.substring(7, 9) + s.substring(1, 7))
        return Qt.color(s)
    }

    // Strength of the tint, 0..1. Taken from the SAME grow drivers the
    // background's WIDTH is taken from, so the colour is not animated on a
    // timer of its own that could drift out of step with the geometry: colour
    // strength and width are literally the same number at every instant.
    //
    // Band-to-band changes (e.g. blue -> green on the way through 20%) are the
    // only thing a Behaviour is used for, and it only ever eases _toward_ the
    // new band's colour. It never touches the grow drivers, so it cannot fight
    // the show/hide animations: on HIDE no band changes (the end-of-hold timer
    // changes no band), so the Behaviour is idle and the tint's decay is done
    // entirely by the grow driver easing back to 0.
    Behavior on _osdVolumeBandColor {
        animation: ColorAnimation {
            duration: root._osdDurationMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on _osdBrightnessBandColor {
        animation: ColorAnimation {
            duration: root._osdDurationMs
            easing.type: Easing.OutCubic
        }
    }

    readonly property real _osdTintStrength:
        root._osdVolumeGrow > 0 ? root._osdVolumeGrow : root._osdBrightnessGrow

    // Composites the current OSD band colour OVER the dock's resting
    // background colour, scaled by the grow driver. The resting colour is
    // passed IN rather than computed here, so this function does pure colour
    // maths and the dock's base-colour expression keeps exactly one home —
    // its original binding, unchanged.
    //
    // ── How the band's own alpha byte is handled ────────────────────
    // The mako colours are translucent on purpose (alpha `20`..`90`) so the
    // mako bar sits over the desktop rather than replacing it, and that has to
    // carry over: the dock must NOT be dragged toward opaque when the OSD
    // fires, or a user who configured a 0.2-opacity glass dock would watch it
    // turn into a solid slab for 1.5 s and the compositor blur behind it would
    // stop showing through.
    //
    // So the tint is composited with the ordinary SOURCE-OVER rule against the
    // base colour — the base KEEPS its own alpha and only contributes to the
    // parts the tint does not cover:
    //
    //   ta   = tint.a * strength              (band alpha, scaled by grow)
    //   outA = ta + base.a * (1 - ta)
    //   outC = (tint.rgb*ta + base.rgb*base.a*(1-ta)) / outA
    //
    // Because base.a < 1 and ta <= 0x90/255, outA stays strictly below 1: the
    // dock can only ever blend further, never go opaque, and it returns to
    // exactly base.a the moment grow reaches 0. Blur and translucency
    // therefore survive the OSD intact.
    //
    // ── At rest this is byte-identical to the old colour ────────────
    // At grow 0 the strength is 0, so ta is 0 and this returns `base`
    // UNCHANGED — the very object the pre-tint binding produced, not a
    // recomputed lookalike. The early return is what guarantees that; without
    // it the divide-by-outA round trip would reintroduce float rounding into
    // the resting colour.
    function _osdBlendTint(base: color, tint: color, strength: real): color {
        if (!(strength > 0)) return base
        const ta = tint.a * strength
        if (!(ta > 0)) return base
        const ba = base.a
        const outA = ta + ba * (1 - ta)
        if (!(outA > 0)) return base
        const inv = ba * (1 - ta)
        return Qt.rgba(
            (tint.r * ta + base.r * inv) / outA,
            (tint.g * ta + base.g * inv) / outA,
            (tint.b * ta + base.b * inv) / outA,
            outA)
    }

    // Restart-on-trigger: a new change retargets the driver at the new level
    // and pushes the hold back out, so holding a volume key up ramps
    // continuously instead of queueing feedback. stop() leaves the driver's
    // value where it is, so the replay resumes from wherever the previous
    // ease had reached — the bar grows or shrinks smoothly from there and
    // never snaps or flickers back to zero between steps.
    function _triggerOsd(which: string, level: real): void {
        if (!root._osdEnabled) return
        const show = which === "volume" ? osdVolumeAnimShow : osdBrightnessAnimShow
        const hide = which === "volume" ? osdVolumeAnimHide : osdBrightnessAnimHide
        const hold = which === "volume" ? osdVolumeHold : osdBrightnessHold
        // The ceiling differs per quantity: volume may overamplify to 150,
        // brightness tops out at 100. Brightness keeps its literal 100 here
        // rather than borrowing AudioService.maxLevel — it is a different
        // quantity with a different natural maximum.
        const max = which === "volume" ? root._osdVolumeMaxLevel : 100
        // Pick this level's band and adopt its mako colour as the tint. The
        // band-colour properties are plain writable properties driven by these
        // explicit writes, each animated by its own Behavior, rather than
        // bindings that would re-evaluate on every unrelated change.
        // No assignment happens on the end-of-hold path, so the band — and so
        // the tint's hue — survives untouched while the grow driver decays
        // the tint strength to zero.
        if (which === "volume") {
            root._osdVolumeBandColor = root._makoColor(
                root._osdVolumeBands[root._osdVolumeBand(level)] ?? "#00000050")
        } else {
            root._osdBrightnessBandColor = root._makoColor(
                root._osdBrightnessBands[root._osdBrightnessBand(level)] ?? "#00000000")
        }
        show.to = root._osdGrowForLevel(level, max)
        show.stop()
        hide.stop()
        show.start()
        hold.restart()
    }

    NumberAnimation {
        id: osdVolumeAnimShow
        target: root
        property: "_osdVolumeGrow"
        to: 1
        duration: root._osdDurationMs
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: osdVolumeAnimHide
        target: root
        property: "_osdVolumeGrow"
        to: 0
        duration: root._osdDurationMs
        easing.type: Easing.InOutCubic
    }
    Timer {
        id: osdVolumeHold
        interval: root._osdHoldMs
        repeat: false
        onTriggered: {
            osdVolumeAnimShow.stop()
            // restart() replays from the value the hold found it at, so an
            // interrupted shrink eases back rather than snapping.
            osdVolumeAnimHide.restart()
        }
    }

    NumberAnimation {
        id: osdBrightnessAnimShow
        target: root
        property: "_osdBrightnessGrow"
        to: 1
        duration: root._osdDurationMs
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: osdBrightnessAnimHide
        target: root
        property: "_osdBrightnessGrow"
        to: 0
        duration: root._osdDurationMs
        easing.type: Easing.InOutCubic
    }
    Timer {
        id: osdBrightnessHold
        interval: root._osdHoldMs
        repeat: false
        onTriggered: {
            osdBrightnessAnimShow.stop()
            osdBrightnessAnimHide.restart()
        }
    }

    // Gate the services' WORK on the OSD being enabled.
    //
    // The target cannot be `root._osdEnabled ? AudioService : null`: a
    // Quickshell singleton is instantiated on first reference and then lives
    // for the whole session, and before Config has hydrated the key is absent
    // so `_osdEnabled` is briefly true anyway. Measured with osd.enabled=false,
    // the conditional target still spawned a brightnessctl every second. So
    // the singletons are referenced unconditionally and switched off from the
    // inside, which is the only thing that actually stops the processes.
    Binding {
        target: AudioService
        property: "active"
        value: root._osdEnabled
    }
    Binding {
        target: BrightnessService
        property: "active"
        value: root._osdEnabled
    }

    Connections {
        target: AudioService
        function onVolumeAdjusted(level: real) { root._triggerOsd("volume", level) }
    }
    Connections {
        target: BrightnessService
        function onBrightnessAdjusted(level: real) { root._triggerOsd("brightness", level) }
    }

    // ─── mock geometry constants (dock_geometry.cpp / shadow.cpp) ───────
    readonly property int kCellPad: 6
    readonly property int kAutoHideTriggerPx: 2
    readonly property int kScreenEdgeOverlapPx: 1
    readonly property real kAutoHideSlideExtraPx: 16
    readonly property real kBadgeSizeRatio: 0.30
    readonly property real kBadgeCornerOverhang: 0.45
    readonly property real kBlurRadius: 12
    readonly property real kShadowOffset: 2

    // Per-corner border radius resolution: corner-specific override →
    // uniform borderRadius → Appearance default. `cfg` is the resolved
    // per-output config so a monitor override can carry radii.
    function _cornerRadius(cfg: var, corner: string): real {
        const per = cfg?.[corner]
        // null (and historically -1) means "auto" — fall through to the uniform
        // borderRadius then the Appearance default.
        if (per !== undefined && per !== null && per >= 0) return per
        const r = cfg?.borderRadius ?? -1
        if (r !== null && r !== undefined && r >= 0) return r
        return Appearance.rounding.normal
    }

    // ─── Focused output + workspace occupancy ────────────────────────
    // Quickshell 0.3.1 exposes no per-screen workspace/focus data on Wayland
    // (Screen is a Qt screen; ToplevelManager is empty under niri's
    // foreign-toplevel support), so both the focused output (activeMonitorOnly)
    // and the active workspace's window count (smartAutoHide) come from niri's
    // IPC. Polls are coalesced: any signal schedules exactly one deferred read.
    property string _focusedScreenName: Quickshell.screens[0]?.name ?? ""
    property bool _focusedWorkspaceEmpty: false
    property int _focusEpoch: 0
    property bool _focusQueryQueued: false

    // POSIX `sh` does not expand \u escapes in `echo`, so \u001e would be
    // emitted literally and the split below would never find a separator.
    // printf with an octal escape is portable.
    property string _niriProbe: "niri msg -j workspaces; printf '\\036'; niri msg -j outputs"

    function _pollNiri(): void {
        if (niriProbeProcess.running) return
        niriProbeProcess.running = true
    }

    function _queuePoll(): void {
        if (root._focusQueryQueued) return
        root._focusQueryQueued = true
        Qt.callLater(() => {
            root._focusQueryQueued = false
            root._focusEpoch = (root._focusEpoch + 1) % 1000000
            root._pollNiri()
        })
    }

    function _applyNiriProbe(raw: string): void {
        const sep = raw.indexOf("\u001e")
        if (sep < 0) return
        let workspaces = []
        let outputs = []
        try {
            workspaces = JSON.parse(raw.slice(0, sep).trim())
            // `niri msg -j outputs` is an OBJECT keyed by connector name, not
            // an array. Normalise it to a list of values.
            const parsedOutputs = JSON.parse(raw.slice(sep + 1).trim())
            outputs = Array.isArray(parsedOutputs)
                ? parsedOutputs
                : Object.values(parsedOutputs)
        } catch (e) {
            return
        }
        if (!Array.isArray(outputs) || !Array.isArray(workspaces)) return

        // The focused workspace, used for both focused-output and emptiness.
        let focusedWs = workspaces.find(w => w && w.is_focused)
        if (!focusedWs) focusedWs = workspaces.find(w => w && w.is_active)

        // Focused OUTPUT comes from the focused workspace's `output` field.
        // niri's output objects carry no is_focused flag, so this is the only
        // reliable source; fall back to the previously known screen.
        const focusedOutput = focusedWs?.output
        if (focusedOutput !== undefined && focusedOutput !== null && String(focusedOutput).length > 0)
            root._focusedScreenName = String(focusedOutput)

        // smartAutoHide: the focused workspace holds no toplevels. niri exposes
        // that as a null active_window_id; `!active_window_id` also covers 0.
        root._focusedWorkspaceEmpty = !focusedWs
            ? true
            : !focusedWs.active_window_id
    }

    Process {
        id: niriProbeProcess
        command: ["sh", "-c", root._niriProbe]
        running: false
        stdout: StdioCollector { onStreamFinished: root._applyNiriProbe(this.text) }
    }

    // Only the two features that need compositor focus/workspace state require
    // this probe. Both default to false, so a default dock must not fork two
    // `niri msg` processes every second for state nothing reads.
    readonly property bool _probeNeeded:
        (Config.options?.dock?.smartAutoHide ?? false)
        || (Config.options?.dock?.activeMonitorOnly ?? false)

    // Coalesced re-evaluation: any toplevel change, plus a slow heartbeat for
    // workspace switches that raise no toplevel signal.
    Timer {
        interval: 1000
        repeat: true
        running: root._probeNeeded
        onTriggered: root._queuePoll()
    }
    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() { if (root._probeNeeded) root._queuePoll() }
    }
    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() { if (root._probeNeeded) root._queuePoll() }
    }
    // Probe once when a dependent feature is switched on.
    Connections {
        target: Config.options?.dock
        function onSmartAutoHideChanged() { if (root._probeNeeded) root._queuePoll() }
        function onActiveMonitorOnlyChanged() { if (root._probeNeeded) root._queuePoll() }
    }

    // ─── geometry resolution helpers ─────────────────────────────────
    // Shared by the per-output panels and the exclusive-zone spacer so both
    // reserve exactly the same strip.
    function _shadowOffsetFor(direction: string): vector2d {
        const m = root.kShadowOffset
        switch (direction) {
        case "down": return Qt.vector2d(0, m)
        case "up": return Qt.vector2d(0, -m)
        case "left": return Qt.vector2d(-m, 0)
        case "right": return Qt.vector2d(m, 0)
        case "downLeft": return Qt.vector2d(-m, m)
        case "downRight": return Qt.vector2d(m, m)
        case "upLeft": return Qt.vector2d(-m, -m)
        case "upRight": return Qt.vector2d(m, -m)
        }
        return Qt.vector2d(0, 0)
    }

    // mock: shell::surface_shadow::bleed() — blur radius plus the flat offset
    // pushing that way.
    function _bleedFor(offset: vector2d): var {
        if (offset.x === 0 && offset.y === 0) {
            return { l: root.kBlurRadius, r: root.kBlurRadius, u: root.kBlurRadius, d: root.kBlurRadius }
        }
        return {
            l: root.kBlurRadius + Math.max(0, -offset.x),
            r: root.kBlurRadius + Math.max(0, offset.x),
            u: root.kBlurRadius + Math.max(0, -offset.y),
            d: root.kBlurRadius + Math.max(0, offset.y),
        }
    }

    // mock: dockThickness() — icon + cell padding + cross-axis padding.
    function _thicknessFor(cfg: var): real {
        const icon = cfg?.iconSize ?? 35
        const cross = cfg?.crossAxisPadding ?? 8
        return icon + root.kCellPad * 2 + cross * 2
    }

    // mock: exclusive zone — reserved regardless of auto-hide.
    function _exclusiveZoneFor(cfg: var, position: string): real {
        if (!(cfg?.reserveSpace ?? false)) return 0
        const bleed = root._bleedFor(_shadowOffsetFor(cfg?.shadowDirection ?? "down"))
        const mEdge = cfg?.marginEdge ?? 0
        const t = root._thicknessFor(cfg)
        if (position === "bottom") return t + Math.min(mEdge, bleed.d)
        if (position === "top") return Math.min(mEdge, bleed.u) + t
        if (position === "right") return t + Math.min(mEdge, bleed.r)
        return Math.min(mEdge, bleed.l) + t
    }

    Variants {
        model: {
            const screens = Quickshell.screens;
            const list = Config.options?.dock?.screenList ?? [];
            if (!list || list.length === 0)
                return screens;
            const matchedScreens = screens.filter(screen => {
                const screenName = screen?.name ?? "";
                return screenName.length > 0 && list.includes(screenName);
            });
            // Fallback safety: stale monitor names (e.g. output re-enumeration after VRR changes)
            // should never hide the dock on every screen.
            return matchedScreens.length > 0 ? matchedScreens : screens;
        }

        Loader {
            id: panelLoader
            required property var modelData
            // activeMonitorOnly: only the focused output gets a panel. The
            // focused name is a plain property so the binding re-runs when the
            // active toplevel moves between outputs.
            active: {
                root._focusEpoch;
                if (!root._enabled) return false;
                const cfg = Config.dockConfigForScreen(modelData);
                if (!(cfg?.activeMonitorOnly ?? false)) return true;
                return (modelData?.name ?? "") === root._focusedScreenName;
            }

            // Recrear cuando cambie la posición del dock o de la barra
            property string posKey: root._positionKey
            onPosKeyChanged: {
                active = false
                Qt.callLater(() => { active = true })
            }

            // ─── Deferred dock model rebuild ────────────────────────────
            // Lives outside the sourceComponent so it survives PanelWindow
            // toggles.  Uses Qt.callLater to defer past current component
            // construction so the PanelWindow tree is stable.  No dedup guard
            // — the _rebuilding re-entrancy check in DockApps drops redundant
            // calls, and _dockItemsEqual prevents unnecessary model updates.
            function _deferDockRebuild() {
                Qt.callLater(() => {
                    const win = panelLoader.item
                    if (!win) return
                    if (win.dockAppsAlias) win.dockAppsAlias.rebuildDockItems()
                    if (win.dockAppsVerticalAlias) win.dockAppsVerticalAlias.rebuildDockItems()
                })
            }

            Connections {
                target: ToplevelManager.toplevels
                function onValuesChanged() { panelLoader._deferDockRebuild() }
            }

            Connections {
                target: CompositorService
                function onSortedToplevelsChanged() { panelLoader._deferDockRebuild() }
            }

            Connections {
                target: Config.options?.dock
                function onPinnedAppsChanged() { panelLoader._deferDockRebuild() }
                function onIgnoredAppRegexesChanged() { panelLoader._deferDockRebuild() }
            }

            sourceComponent: PanelWindow {
                id: dockRoot
                screen: panelLoader.modelData
                property alias dockAppsAlias: dockApps
                property alias dockAppsVerticalAlias: dockAppsVertical

                // ─── Per-output resolved config ──────────────────────────
                // dockConfigForScreen returns a PLAIN object, so it is not
                // reactive on its own: _cfgEpoch is bumped on configChanged to
                // force this binding to re-resolve.
                property int _cfgEpoch: 0
                property var cfg: dockRoot._resolveCfg()
                function _resolveCfg(): var {
                    if (dockRoot._cfgEpoch < 0) return null   // dependency read
                    return Config.dockConfigForScreen(dockRoot.screen)
                }
                Connections {
                    target: Config
                    function onConfigChanged() {
                        dockRoot._cfgEpoch = (dockRoot._cfgEpoch + 1) % 1000000
                        dockRoot.cfg = dockRoot._resolveCfg()
                        panelLoader._deferDockRebuild()
                    }
                }

                // Panel visibility depends on three singletons:
                //   GlobalStates.screenLocked   → hidden while the screen is locked
                //   GameMode.shouldHidePanels   → hidden in game mode (HUD overlay)
                //   GlobalStates.widgetEditMode → hidden while editing widgets
                // The && chain means the dock is only drawn when every condition
                // is satisfied (all must be false to show).
                visible: !GlobalStates.screenLocked && !GameMode.shouldHidePanels && !GlobalStates.widgetEditMode

                // ─── Readiness gate ───────────────────────────────────────
                // The dock surface stays fully transparent — background, shadow
                // and all — until its icons genuinely have something to draw.
                //
                // This USED to be a bare timer (300 ms, the since-deleted
                // `dock.behavior.slideInDelay` key) with no connection to icon
                // loading whatsoever, which is why the dock
                // appeared first and the icons popped in behind it: nothing in
                // that timer waited on AppSearch, on the icon theme index, or on
                // any image. The real signal is per-icon `Image.Ready`, which
                // DockApps aggregates into `iconsReady` (see the note there for
                // why neither AppSearch.ready nor IconThemeService._indexReady
                // is sufficient on its own).
                //
                // Both orientations are constructed at all times and only one is
                // laid out, so the gate reads the visible one's report.
                readonly property bool _iconsReady: root.isVertical
                    ? (dockAppsVertical?.iconsReady === true)
                    : (dockApps?.iconsReady === true)

                // Bounded fallback. An icon the resolver cannot place leaves its
                // Image at status Null and never reports, so without this the
                // dock could stay invisible indefinitely. This is the
                // pathological-case brake, not the normal path — the timeout is
                // generous enough (5 s against a measured ~2.8 s worst case for
                // the theme-index harvest) that a cold icon cache still wins
                // the race on its own.
                readonly property int _iconsReadyTimeoutMs:
                    Config.options?.dock?.iconsReadyTimeoutMs ?? 5000
                property bool _revealForced: false
                Timer {
                    id: iconsReadyTimeout
                    interval: Math.max(0, dockRoot._iconsReadyTimeoutMs)
                    repeat: false
                    onTriggered: dockRoot._revealForced = true
                }

                // `slideIn: false` is the existing opt-out for the whole gate:
                // show immediately, with no wait and no fade.
                //
                // `_launchArmed` exists so the reveal ALWAYS has a start state
                // to animate FROM. Without it there is a real failure mode: if
                // the icons happen to report ready during the very first
                // layout pass (a warm icon cache makes that possible), `_ready`
                // is already true before the surface has rendered anything,
                // so `Behavior on opacity` has no 0 to start from and the
                // slide margin has no off-screen value to start from — the
                // dock simply appears, with no animation at all. That is the
                // "sometimes the slide does not fire" case, and it is silent.
                //
                // 120 ms is a few rendered frames, not a delay anyone can see:
                // the dock is fully transparent until `_ready` anyway, so the
                // arm only guarantees that the off-screen frame exists. It is
                // deliberately NOT part of the reveal's timing budget.
                // `_revealForced` bypasses it, so the 5 s brake below still
                // shows the dock immediately when it fires.
                property bool _launchArmed: false
                Timer {
                    id: launchArmTimer
                    interval: 120
                    repeat: false
                    onTriggered: dockRoot._launchArmed = true
                }

                readonly property bool _ready: (Config.options?.dock?.slideIn ?? true)
                    ? (dockRoot._revealForced
                        || (dockRoot._launchArmed && dockRoot._iconsReady))
                    : true

                // Launch reveal timing, in ms. See Config.qml for why 520.
                // Read as one value by BOTH the slide and the cross-fade so
                // they are always the same motion — a short fade over a long
                // slide (what this was before) reads as a pop followed by a
                // drift, because the content is fully opaque while it is
                // still travelling.
                readonly property int _revealDurationMs:
                    Math.max(0, Config.options?.dock?.slideInDurationMs ?? 520)

                // Shrink PanelWindow surface to the auto-hide trigger strip after
                // slide-out completes, so niri blur disappears. On reveal, expand
                // instantly before the slide-in animation starts.
                property bool _surfaceShrunk: false
                Timer {
                    id: shrinkTimer
                    interval: Appearance.animation.elementMoveEnter.duration + 50
                    repeat: false
                    onTriggered: dockRoot._surfaceShrunk = true
                }


                Component.onCompleted: {
                    dockRoot.cfg = dockRoot._resolveCfg()

                    // Arm the launch. See `_launchArmed` above: this is what
                    // guarantees the reveal always has an off-screen frame to
                    // animate from, so the slide fires even when the icons
                    // report ready during the first layout pass.
                    launchArmTimer.start()

                    // Arm the bounded fallback. It runs alongside the real gate,
                    // not instead of it: whichever fires first wins, and on a
                    // healthy start the icon gate has long since opened.
                    if (!dockRoot._ready) iconsReadyTimeout.start()
                }

                // ─── smartAutoHide ───────────────────────────────────────
                // Show while the active workspace holds no windows. The
                // occupancy comes from root's coalesced compositor probe, so
                // this is a plain read of already-deferred state.
                readonly property bool _smartAutoHide: cfg?.smartAutoHide ?? false
                readonly property bool _smartAllowsReveal: !dockRoot._smartAutoHide || root._focusedWorkspaceEmpty
                // mock: pointer Enter calls revealAutoHideDock() even while
                // smartAutoHide suppresses the default (dock.cpp:557). smart
                // hide only governs the AMBIENT state — an explicit "user
                // wants it" signal (hover / requestDockShow) always reveals.
                readonly property bool _userWantsDock: (dockRoot.cfg?.hoverToReveal && dockMouseArea.containsMouse)
                    || !!(dockApps?.requestDockShow || dockAppsVertical?.requestDockShow)


                property bool reveal: dockRoot._ready
                    && !GlobalStates.coverflowSelectorOpen
                    && GlobalStates.shellEntryReady
                    && (dockRoot._smartAllowsReveal || dockRoot._userWantsDock)

                    && (root.pinned
                        || (Config.options?.dock?.exclusiveZone ?? 0) > 0
                        || (dockRoot.cfg?.hoverToReveal && dockMouseArea.containsMouse)
                        || (dockApps?.requestDockShow || dockAppsVertical?.requestDockShow)
                        || (dockRoot.cfg?.showOnDesktop !== false && !CompositorService.hasActiveActivatedToplevel))

                onRevealChanged: {
                    if (dockRoot.reveal) {
                        // Expanding surface instantly — cancel pending shrink
                        shrinkTimer.stop()
                        dockRoot._surfaceShrunk = false
                    } else {
                        // Start timer to shrink surface after slide-out finishes
                        if (dockRoot.cfg?.hoverToReveal)
                            shrinkTimer.start()
                    }
                }

                // ─── Resolved metrics ────────────────────────────────────
                readonly property real iconSize: cfg?.iconSize ?? 35
                readonly property real itemSpacing: cfg?.spacing ?? 2
                readonly property real mainAxisPadding: cfg?.padding ?? 5
                readonly property real crossAxisPadding: cfg?.crossAxisPadding ?? 8
                readonly property real marginEnds: cfg?.marginEnds ?? 0
                readonly property real marginEdge: cfg?.marginEdge ?? 0
                readonly property bool autoHide: cfg?.hoverToReveal ?? false
                // mock: iconSize + kCellPad*2 + crossAxisPadding*2
                readonly property real thickness: root._thicknessFor(dockRoot.cfg)

                // mock: kScreenEdgeOverlapPx. A flush dock on an output whose
                // scale is NOT an integer (e.g. 1.8) would otherwise sit one
                // logical pixel shy of the screen edge, because the compositor
                // rounds the edge to a device pixel. Overlap by 1px to close
                // that gap. Only applies when flush: marginEdge > 0 floats the
                // dock, and the auto-hide gutter already offsets it.
                readonly property real screenScale: dockRoot.screen?.devicePixelRatio ?? 1
                readonly property bool fractionalScale: !Number.isInteger(dockRoot.screenScale)
                readonly property bool _autoHideGutter: (dockRoot.autoHide && (cfg?.marginEdge ?? 0) > 0) ? (cfg?.marginEdge ?? 0) : 0
                readonly property bool _flushToEdge: (cfg?.marginEdge ?? 0) <= 0 && dockRoot._autoHideGutter === 0
                readonly property real edgeOverlap: (dockRoot._flushToEdge && dockRoot.fractionalScale)
                        ? root.kScreenEdgeOverlapPx : 0

                readonly property real dockHeight: dockRoot.thickness
                readonly property real _viewportWidth: (dockRoot.screen?.width ?? 1920) - 2 * root._margin
                readonly property real _viewportHeight: (dockRoot.screen?.height ?? 1080) - 2 * root._margin
                readonly property real _maxDockHeight: cfg?.maxDockHeight ?? 0
                readonly property real _effectiveMaxHeight: _maxDockHeight > 0 ? Math.min(_maxDockHeight, _viewportHeight) : _viewportHeight
                readonly property real _pageWidth: Math.max(100, _viewportWidth - 2 * root._margin)

                // ─── Hover-zoom padding (mock: dockHoverZoom*Pad) ──────
                // Magnified icons (and their badges) overhang the pill, so the
                // surface must reserve room for them or they get clipped.
                // peak = max(1, max(activeScale,inactiveScale) * max(1,magnifyScale))
                // Peak icon scale the surface must reserve room for.
                //
                // mock: dockHoverZoomPeakScale (dock_geometry.cpp:55-61) returns
                // 1 unless magnification is on AND magnificationScale > 1.
                //
                // We additionally fold in the base active/inactive scale, because
                // an active icon is enlarged by activeScale with no pointer
                // involved, and that overhang must not be clipped either. With
                // magnifyScale 1.0 and activeScale 1.5 this yields peak 1.5.
                //
                // Enlarging the surface no longer costs us the blur:
                // BackgroundEffect.blurRegion is set in SURFACE-LOCAL
                // coordinates from panelOffsetX/panelOffsetY + panelW/panelH, so
                // it tracks the pill while the padding around it stays
                // unblurred. That is exactly the mock's arrangement — an
                // enlarged surface whose blur region is the panel rect.
                readonly property real _zoomPeak: {
                    const base = Math.max(cfg?.activeScale ?? 1.0, cfg?.inactiveScale ?? 0.85)
                    const ms = (cfg?.magnify ?? false) ? Math.max(1, cfg?.magnifyScale ?? 1.45) : 1
                    return Math.max(1, base * ms)
                }
                readonly property real _badgeSize: Math.max(16, (cfg?.iconSize ?? 35) * root.kBadgeSizeRatio)
                readonly property real _badgeOverhang: (cfg?.showInstanceCount ?? true)
                        ? dockRoot._badgeSize * root.kBadgeCornerOverhang * dockRoot._zoomPeak : 0
                // mock: ceil(iconSize*(peak-1) + badgeOverhang + 6)
                readonly property real zoomCrossPad: dockRoot._zoomPeak <= 1 ? 0
                        : Math.ceil((cfg?.iconSize ?? 35) * (dockRoot._zoomPeak - 1) + dockRoot._badgeOverhang + root.kCellPad)
                // mock: ceil(iconSize*(peak-1)*0.5 + badgeOverhang)
                readonly property real zoomMainPad: dockRoot._zoomPeak <= 1 ? 0
                        : Math.ceil((cfg?.iconSize ?? 35) * (dockRoot._zoomPeak - 1) * 0.5 + dockRoot._badgeOverhang)
                readonly property real _pageHeight: Math.max(100, _effectiveMaxHeight - 2 * root._margin)

                // ─── Shadow bleed ────────────────────────────────────────
                readonly property real shadowAlpha: cfg?.shadowAlpha ?? 0.55
                // mock: surface_shadow::style() renders
                // rgba(0,0,0, clamp(shadow.alpha,0,1) * clamp(backgroundOpacity,0,1)).
                readonly property real shadowRenderAlpha:
                    Math.max(0, Math.min(1, dockRoot.shadowAlpha)) * Math.max(0, Math.min(1, root._effectiveBgOpacity))
                // mock: surface_shadow::enabled() consults ONLY the per-component
                // `shadow` bool — never the background opacity.
                readonly property bool shadowEnabled: (cfg?.shadow ?? true)
                    && !Appearance.gameModeMinimal
                    && dockRoot.shadowRenderAlpha > 0
                    && (cfg?.shadowDirection ?? "down") !== "center"

                readonly property vector2d shadowOffset: dockRoot.shadowEnabled
                    ? root._shadowOffsetFor(cfg?.shadowDirection ?? "down")
                    : Qt.vector2d(0, 0)
                readonly property var bleed: dockRoot.shadowEnabled
                    ? root._bleedFor(dockRoot.shadowOffset)
                    : { l: 0, r: 0, u: 0, d: 0 }

                // ─── Concave edge corners (mock: dockConcaveShape) ───────
                // Only when enabled AND the dock is flush with the screen edge.
                // Capped at half the thickness so the carve can never swallow
                // the panel; ceil keeps the inset integral for surface sizing.
                readonly property real concaveCap: Math.ceil(dockRoot.thickness * 0.5)
                function _cappedConcave(r: real): real {
                    return Math.ceil(Math.min(dockRoot.concaveCap, Math.max(0, r)))
                }
                readonly property bool concaveEnabled: (cfg?.concaveEdgeCorners ?? true) && dockRoot.marginEdge <= 0
                readonly property real rTL: root._cornerRadius(dockRoot.cfg, "borderRadiusTopLeft")
                readonly property real rTR: root._cornerRadius(dockRoot.cfg, "borderRadiusTopRight")
                readonly property real rBR: root._cornerRadius(dockRoot.cfg, "borderRadiusBottomRight")
                readonly property real rBL: root._cornerRadius(dockRoot.cfg, "borderRadiusBottomLeft")

                readonly property bool concaveTL: dockRoot.concaveEnabled && (root.isTop || root.isLeft)
                readonly property bool concaveTR: dockRoot.concaveEnabled && (root.isTop || root.position === "right")
                readonly property bool concaveBR: dockRoot.concaveEnabled && (root.position === "right" || root.position === "bottom")
                readonly property bool concaveBL: dockRoot.concaveEnabled && (root.position === "bottom" || root.isLeft)

                readonly property real insetL: dockRoot.concaveEnabled && (root.isTop ? dockRoot._cappedConcave(dockRoot.rTL) : (root.isLeft ? dockRoot._cappedConcave(dockRoot.rTL) : (root.position === "bottom" ? dockRoot._cappedConcave(dockRoot.rBL) : 0)))
                readonly property real insetT: dockRoot.concaveEnabled && (root.isLeft ? dockRoot._cappedConcave(dockRoot.rTL) : (root.isTop ? 0 : (root.position === "right" ? dockRoot._cappedConcave(dockRoot.rTR) : 0)))
                readonly property real insetR: dockRoot.concaveEnabled && (root.isTop ? dockRoot._cappedConcave(dockRoot.rTR) : (root.position === "right" ? dockRoot._cappedConcave(dockRoot.rTR) : (root.position === "bottom" ? dockRoot._cappedConcave(dockRoot.rBR) : 0)))
                readonly property real insetB: dockRoot.concaveEnabled && (root.isLeft ? dockRoot._cappedConcave(dockRoot.rBL) : (root.position === "right" ? dockRoot._cappedConcave(dockRoot.rBR) : (root.position === "bottom" ? 0 : 0)))

                // ─── Layer (mock: layer top|overlay) ─────────────────────
                readonly property bool overlayLayer: (cfg?.layer ?? "top") === "overlay"

                // ─── Surface geometry ────────────────────────────────────
                // The surface wraps the panel with the shadow bleed on every
                // side (so the shadow is never clipped) and the concave
                // logical inset plus marginEnds along the main axis.
                readonly property real panelW: root.isVertical
                    ? Math.min(dockColumn.implicitHeight + dockRoot.mainAxisPadding * 2, _viewportHeight - 2 * dockRoot.marginEnds)
                    : Math.min(dockRow.implicitWidth + dockRoot.mainAxisPadding * 2, _viewportWidth - 2 * dockRoot.marginEnds)
                readonly property real panelH: root.isVertical
                    ? dockRoot.thickness
                    : dockRoot.thickness

                // Zoom padding (mock: dockHoverZoomCrossPad / MainPad).
                //
                // On the CROSS axis the pad goes ONLY on the side facing AWAY
                // from the screen edge. The mock keeps the pill flush with the
                // edge and grows the surface inward; padding symmetrically would
                // insert transparent space between the pill and the edge and
                // visibly float the dock off the screen.
                //
                // Overflow that reaches BACK TOWARD the edge is fine — the layer
                // surface simply extends past the screen edge there, which is
                // what the fractional-scale edgeOverlap already does.
                //
                // On the MAIN axis the pad stays symmetric: it covers icon/badge
                // overhang past the two pill ends and does not affect edge flush.
                //
                // ─── Static surface sizing ─────────────────────────────
                // The surface is sized ONCE to the largest main-axis extent
                // the pill can EVER reach on this screen, and is never resized
                // when the icon count changes. The pill simply animates inside
                // a permanently oversized, transparent surface.
                //
                // This removes the resize entirely rather than retiming it. A
                // layer-shell resize is not a repaint: every distinct size
                // reconfigures the wl_surface and makes niri redo its crop and
                // blur work — the single worst frame in the transition
                // (measured ~50 ms main-thread stall), which previously had to
                // be hidden under the tail of the pill's ease.
                //
                // The bound is a real upper bound: DockApps caps its extent at
                // pageWidth / pageHeight and pages instead, so the pill can
                // never exceed the viewport minus the end margins. Nothing can
                // clip.
                //
                // An oversized transparent surface is only acceptable because:
                //  - input is masked to the pill rect (`mask: Region`), so the
                //    transparent margin is click-through;
                //  - blur is confined by `BackgroundEffect.blurRegion`, the
                //    client-side ext-background-effect-v1 path, which stays on
                //    the pill rect (see the note there);
                //  - the exclusive zone lives on a separate spacer surface,
                //    which this width does not touch.
                readonly property real _surfacePanelW: root.isVertical
                    ? dockRoot._viewportHeight - 2 * dockRoot.marginEnds
                    : dockRoot._viewportWidth - 2 * dockRoot.marginEnds
                readonly property real _surfacePanelH: dockRoot.thickness



                readonly property real surfaceW: root.isVertical
                    ? dockRoot.bleed.l + dockRoot.insetL + dockRoot._surfacePanelW + dockRoot.insetR + dockRoot.bleed.r + dockRoot.zoomCrossPad
                    : dockRoot.bleed.l + dockRoot.insetL + dockRoot._surfacePanelW + dockRoot.insetR + dockRoot.bleed.r + 2 * dockRoot.marginEnds + 2 * dockRoot.zoomMainPad
                readonly property real surfaceH: root.isVertical
                    ? dockRoot.bleed.u + dockRoot.insetT + dockRoot._surfacePanelH + dockRoot.insetB + dockRoot.bleed.d + 2 * dockRoot.marginEnds + 2 * dockRoot.zoomMainPad
                    : dockRoot.bleed.u + dockRoot.insetT + dockRoot._surfacePanelH + dockRoot.insetB + dockRoot.bleed.d + dockRoot.zoomCrossPad

                // Where the panel sits inside the surface: bleed, then the
                // concave logical inset, then marginEnds, then the zoom pad on
                // whichever sides actually carry it. The half-slack term keeps
                // the pill visually centred while it eases inside the held
                // (larger) surface.
                readonly property real _surfaceSlackW: Math.max(0, (dockRoot._surfacePanelW - dockRoot.panelW) * 0.5)
                // Vertical docks: the main axis is vertical, so centre the pill
                // inside the permanently full-height surface the same way.
                // panelH is the MAIN-axis extent there (it is the thickness,
                // which never animates), while panelW is the cross-axis
                // thickness and is NOT what the vertical slack measures.
                readonly property real _surfaceSlackH: root.isVertical
                    ? Math.max(0, (dockRoot._surfacePanelH - dockRoot.panelH) * 0.5)
                    : 0
                readonly property real panelOffsetX: root.isVertical
                    ? dockRoot.bleed.l + dockRoot.insetL + (root.position === "right" ? dockRoot.zoomCrossPad : 0)
                    : dockRoot.bleed.l + dockRoot.insetL + dockRoot.marginEnds + dockRoot.zoomMainPad + dockRoot._surfaceSlackW
                readonly property real panelOffsetY: root.isVertical
                    ? dockRoot.bleed.u + dockRoot.insetT + dockRoot.marginEnds + dockRoot.zoomMainPad + dockRoot._surfaceSlackH
                    : dockRoot.bleed.u + dockRoot.insetT + (root.isTop ? 0 : dockRoot.zoomCrossPad)

                // ─── OSD background growth ───────────────────────────
                // The OSD IS the dock background: the pill's painted shape
                // grows, so volume stretches it toward its LEFT end and
                // brightness stretches it toward its RIGHT end. There is no
                // separate rectangle anywhere.
                //
                // Three properties make that safe to do:
                //   - The painted shape and the input mask are SEPARATE
                //     items. `dockBackground` stays pinned to the functional
                //     pill rect and is what the PanelWindow's `mask` Region
                //     tracks, so the clickable/hit area never changes size.
                //     `dockVisualRoot` is the grown painted rect.
                //   - The dock icons live in `dockBackground` and are centred
                //     in THAT item, not in the grown shape, so widening the
                //     background cannot re-centre or slide them.
                //   - The surface is already held at viewport width (see
                //     _surfacePanelW), so the growth renders inside padding
                //     that already exists: no layer-shell resize, which is
                //     the frame this file goes out of its way to avoid.
                //
                // A vertical dock is excluded: on that axis "left/right" is
                // the pill's THICKNESS, so growing there would change the
                // dock's size rather than its length.
                readonly property real _osdGrowPx: root.isVertical
                    ? 0
                    : (Config.options?.dock?.osd?.growWidth ?? 240)
                // Clamp: the background must never be drawn outside the
                // surface. panelOffsetX is the pill's left edge in
                // surface-local coordinates, so there is exactly panelOffsetX
                // of room to its left. The shadow bleed and the concave
                // logical inset are excluded from that budget because they
                // belong to the pill itself, not to the growth. (The zoom pad
                // is left usable — it is transparent, and it is only occupied
                // transiently by a magnified icon.)
                readonly property real _osdMaxGrowL: Math.max(0,
                    dockRoot.panelOffsetX - dockRoot.bleed.l - dockRoot.insetL)
                readonly property real _osdMaxGrowR: Math.max(0,
                    dockRoot.surfaceW - (dockRoot.panelOffsetX + dockRoot.panelW)
                        - dockRoot.bleed.r - dockRoot.insetR)
                readonly property real _osdGrowL: Math.min(
                    root._osdVolumeGrow * dockRoot._osdGrowPx, dockRoot._osdMaxGrowL)
                readonly property real _osdGrowR: Math.min(
                    root._osdBrightnessGrow * dockRoot._osdGrowPx, dockRoot._osdMaxGrowR)

                // The painted shape's own rect: the pill, extended by
                // whichever end is currently driven. At grow 0 both terms are
                // 0, so these are exactly panelOffsetX / panelW and the dock
                // is indistinguishable from its resting self.
                readonly property real _bgX: dockRoot.panelOffsetX - dockRoot._osdGrowL
                readonly property real _bgW: dockRoot.panelW + dockRoot._osdGrowL + dockRoot._osdGrowR

                // Whether the blur Region below has non-zero geometry YET.
                //
                // `QRegion(x, y, 0, 0)` is EMPTY, and Quickshell turns an
                // empty region into `set_blur_region(nil)`
                // (src/wayland/background_effect/surface.cpp:
                //     if (region.isEmpty()) { this->set_blur_region(nullptr); return; }).
                // On the first polish `_bgW`/`panelH` are still 0, because the
                // dock has not been laid out, so before this gate existed the
                // dock really did send nil — verified in a WAYLAND_DEBUG trace
                // of a real launch:
                //     39.311 wl_surface#40.commit()                       <- no region at all
                //     39.356 ext_background_effect_surface_v1#44.set_blur_region(nil)
                //     39.382 wl_surface#40.commit()
                //     39.392 set_blur_region(wl_region#52)   <- the off-surface rects
                // Both early commits were at the FULL surface size, and both
                // are exactly the state niri answers with the layer rule's
                // whole-surface blur (handlers/background_effect.rs: `unset` /
                // never-set -> `blur_region` None -> `has_blur_region` false ->
                // `blur = effect.blur == Some(true)` -> rule says true).
                // That is the ghost.
                readonly property bool _layoutReady: dockRoot._bgW > 0 && dockRoot.panelH > 0

                // Corner rounding is CONSTANT and is NOT a function of growth:
                // rTL/rTR/rBL/rBR and concaveTL/TR/BL/BR are bound straight
                // into dockVisualBackground, so the pill is equally rounded at
                // rest and fully expanded. Nothing here squares off or
                // un-carves a corner when the OSD fires — that is the point of
                // having one single shape instead of a pill plus a bolted-on
                // rectangle.

                // mock: computeHiddenSlideDelta — push the panel a further
                // kAutoHideSlideExtraPx past the edge, measured from the panel
                // rect unioned with its shadow-offset rect.
                readonly property real hiddenSlideDelta: {
                    const bw = dockRoot.surfaceW
                    const bh = dockRoot.surfaceH
                    const x = dockRoot.panelOffsetX
                    const y = dockRoot.panelOffsetY
                    const w = dockRoot.panelW
                    const h = dockRoot.panelH
                    const sx = x + dockRoot.shadowOffset.x
                    const sy = y + dockRoot.shadowOffset.y
                    const contentLeft = Math.min(x, sx)
                    const contentTop = Math.min(y, sy)
                    const contentRight = Math.max(x + w, sx + w)
                    const contentBottom = Math.max(y + h, sy + h)
                    if (root.position === "bottom") return (bh - contentTop) + root.kAutoHideSlideExtraPx
                    if (root.isTop) return contentBottom + root.kAutoHideSlideExtraPx
                    if (root.position === "right") return (bw - contentLeft) + root.kAutoHideSlideExtraPx
                    return contentRight + root.kAutoHideSlideExtraPx
                }

                anchors {
                    top: root.isTop || root.isVertical
                    bottom: !(root.isTop || root.isVertical)
                    left: root.position !== "right"
                    right: root.position === "right"
                }

                // Always float as a content-sized surface positioned via margins.
                // _blur only controls the layer namespace (compositor blur), not
                // positioning — so toggling blur doesn't move the dock.
                margins {
                    // Layer-shell anchors the cross axis too (see the anchors
                    // block), so the along-the-dock offset must be expressed as
                    // a margin: edge insets come from marginEdge, and the
                    // surface is centred across the remaining span.
                    //
                    // The static surface's main axis is viewport-sized, so with
                    // the shadow bleed and zoom pad added it can be WIDER than
                    // the screen. The centring terms below must therefore be
                    // allowed to go NEGATIVE; clamping them at 0 would leave the
                    // pill off-centre by half the overhang.
                    // mock: marginEdge<=0 ? -edgeOverlap : max(0, marginEdge - bleed)
                    left: root.isVertical
                        ? (root.isLeft ? (dockRoot.marginEdge <= 0 ? -dockRoot.edgeOverlap : Math.max(0, dockRoot.marginEdge - dockRoot.bleed.l)) : 0)
                        : Math.round(((dockRoot.screen?.width ?? 1920) - dockRoot.surfaceW) / 2)
                    right: root.position === "right"
                        ? (dockRoot.marginEdge <= 0 ? -dockRoot.edgeOverlap : Math.max(0, dockRoot.marginEdge - dockRoot.bleed.r))
                        : 0
                    top: root.isVertical
                        ? Math.round(((dockRoot.screen?.height ?? 1080) - dockRoot.surfaceH) / 2)
                        : (root.isTop ? (dockRoot.marginEdge <= 0 ? -dockRoot.edgeOverlap : Math.max(0, dockRoot.marginEdge - dockRoot.bleed.u)) : 0)
                    bottom: root.position === "bottom"
                        ? (dockRoot.marginEdge <= 0 ? -dockRoot.edgeOverlap : Math.max(0, dockRoot.marginEdge - dockRoot.bleed.d))
                        : 0
                }

                exclusiveZone: -1

                // ── Surface size: full size from the first laid-out frame ──
                //
                // The ghost is NOT stopped by this file's `_ready` gate. It is
                // stopped by making sure niri never sees the dock surface at
                // its real size while it still has no client blur region.
                //
                // Mechanism (from a WAYLAND_DEBUG trace of a real launch, see
                // `_layoutReady` above): Quickshell creates and commits the
                // wl_surface with the window's CURRENT size BEFORE it has
                // polished the blur Region. With an unconditional full size
                // that creation commit was 1087x118 with no region at all, and
                // a second commit 70 ms later still carried
                // `set_blur_region(nil)`. Both land in the state
                //     blur_region == None
                // for which niri uses the LAYER RULE instead of the client
                //     let has_blur_region = blur_region.as_ref().is_some_and(|r| !r.is_empty());
                //     let blur = if has_blur_region { effect.blur != Some(false) }
                //               else { effect.blur == Some(true) };
                // (src/render_helpers/background_effect.rs) and the user's
                // `layer-rule { match namespace="quickshell" ... blur true }`
                // (matched by substring in src/layer/mod.rs:130) blurs the
                // WHOLE surface. Hence "a large blurred rectangle before the
                // dock does".
                //
                // So the surface stays small — 1x1 — only until `_layoutReady`,
                // i.e. until the Region has non-zero geometry and can therefore
                // be committed as a non-empty rect list instead of nil. That is
                // the first layout pass, well before any frame the user can see
                // and ~1 s before the reveal, so the ghost is bounded to a
                // surface that is a single pixel.
                //
                // This is NOT the old `_ready ? … : 1` gate, which held the
                // surface at 1x1 for the whole icon wait and left the reveal no
                // distance to travel — that is what made the launch slide
                // impossible. `_ready` deliberately does NOT appear here: from
                // `_layoutReady` onward the surface is at full size, so the
                // panel has the whole `hiddenSlideDelta` to travel over the
                // 520 ms `slideInDurationMs` reveal.
                //
                // The 1x1 fallback of the auto-hide strip is untouched, and so
                // is the exclusive-zone reservation, which lives on the
                // SEPARATE `quickshell:dock-exclusive` surface.
                implicitWidth: !dockRoot._layoutReady ? 1
                    : (root.isVertical
                        ? (dockRoot._surfaceShrunk ? dockRoot.kAutoHideTriggerPx : dockRoot.surfaceW)
                        : dockRoot.surfaceW)
                implicitHeight: !dockRoot._layoutReady ? 1
                    : (root.isVertical
                        ? dockRoot.surfaceH
                        : (dockRoot._surfaceShrunk ? dockRoot.kAutoHideTriggerPx : dockRoot.surfaceH))

                WlrLayershell.namespace: "quickshell:dock"
                WlrLayershell.layer: dockRoot.overlayLayer ? WlrLayer.Overlay : WlrLayer.Top
                color: "transparent"

                Item { id: emptyMask; width: 0; height: 0 }
                // Masked to the FUNCTIONAL PILL (item: dockBackground), not to
                // the painted background (dockVisualRoot). Widening the painted
                // shape must not change what the dock swallows clicks on, so the
                // mask item keeps the un-grown panel rect while the visible
                // background grows past it. This mask combined with the ABSENCE
                // of BackgroundEffect below is the configuration under which the
                // dock's blur was visible (with the hover-zoom padding also
                // blurring — the halo). Change neither without re-testing both.
                // Also switched to the empty mask while the dock is pre-ready.
                // The pill then sits over the screen edge fully transparent, and
                // an invisible bar swallowing clicks there would be worse than
                // the pop-in this gate exists to remove.
                //
                // The ready mask targets `dockMaskTarget`, NOT `dockBackground`
                // directly. Quickshell mirrors a Region's `item` by tracking
                // THAT ITEM'S OWN geometry; movement of an ANCESTOR is not
                // tracked. `dockBackground` sits under `dockHoverRegion`, whose
                // bottom/left/right margin animates the slide, so swapping the
                // mask to it at the instant _ready flipped captured the region
                // mid-slide — surface-local at x = (surface width - dock
                // width)/2, y = resting offset + height (i.e. y well past the
                // surface's own height). The compositor clips input regions
                // to the surface, so that rect became empty: the dock stayed
                // visible and swallowed nothing. Verified with
                // WAYLAND_DEBUG=1 (the first wl_region.add is emitted out of
                // bounds at y = restingY + height, never re-sent at that value)
                // and reproduced in a two-line micro-test (animate the item ->
                // region re-sent every frame; animate its parent -> one stale
                // send). `dockMaskTarget` is an invisible proxy whose own x/y
                // are bound to the animated slide offsets, so the region is
                // re-sent as the dock slides and settles on exactly the same
                // resting rect dockBackground occupies.
                //
                // The numeric rects measured in WAYLAND_DEBUG traces are NOT
                // stable constants — do not hardcode them into a comment or a
                // test assertion. Both the dock width and the surface height
                // are derived from the user's config: width tracks the icon
                // strip (iconSize and the number of items), height tracks the
                // configured dock height plus margins, and the x origin is the
                // surface width minus the dock width, halved. So the resting
                // rect scales with `iconSize` / dock height, and a reading
                // taken at one iconSize is wrong at another. Observed shapes in
                // those traces ranged from a 440 px-wide dock at iconSize 35 up
                // to a 527 px-wide dock at iconSize 80, both with the same
                // 92 px pill height; the y origin moved from 26 to 134 as the
                // surface grew. Same bug, same mechanism, different numbers.
                mask: Region { item: (GameMode.shouldHidePanels || !dockRoot._ready) ? emptyMask : dockMaskTarget }

                // The dock sets the layer namespace "quickshell:dock" and commits
                // a client `blurRegion`. The region's geometry and the painted
                // background come from the same bindings (`_bgX`, `_bgW`,
                // `panelOffsetY`, `panelH`, `rTL/rTR/rBR/rBL`), so by
                // construction there is no geometry gap between the blurred
                // region and the dock background, and the region deliberately
                // tracks `_bgX`/`_bgW` so it follows the OSD growth.
                //
                // Coordinates are SURFACE-LOCAL. An earlier version anchored
                // this to `item: dockBackground`, which emitted the region at
                // the item's offset inside the surface and niri stopped
                // blurring entirely — a coordinate bug, not niri rejecting
                // the region.
                //
                // niri consults the layer rule's `background-effect.blur` in
                // BOTH branches (src/render_helpers/background_effect.rs:
                // `let blur = if has_blur_region { effect.blur != Some(false) }
                // else { effect.blur == Some(true) };`). An explicit
                // `blur false` would veto the client region; an explicit
                // `blur true` enables blur even with no client region.
                //
                // SCOPE — this holds for THIS surface and must not be
                // generalised. `layer-rule` genuinely reaches a layer-shell
                // surface; `window-rule` does NOT (a layer surface's rules are
                // computed from `config.layer_rules` alone —
                // src/handlers/layer_shell.rs:162-163 — and `config.window_rules`
                // is read only on the xdg/toplevel path). A POPUP of this dock
                // therefore gets `ResolvedPopupsRules::default()`, whose blur
                // is `None`, and with no client region the else-branch above is
                // false — so the context menu needs its OWN committed region to
                // be blurred at all. Do not read this block as "a rule already
                // covers our surfaces". See
                // modules/common/widgets/ContextMenu.qml.
                //
                // THE REPORTED SYMPTOM — "the blurred region looks slightly
                // smaller than the dock background" — HAS NOT BEEN DIAGNOSED.
                // Do not attribute it to a cause. Any numbers obtained from
                // throwaway probe surfaces were measurements of a synthetic
                // setup, not of the user's real dock on their real desktop,
                // and they do not reproduce what the user sees. The cause
                // remains unknown; future work must measure the real dock on
                // the real desktop rather than a synthetic surface.
                //
                // Still load-bearing:
                //  - `blurRegion` is singular; assigning a list fails with
                //    "Cannot assign multiple values to a singular property".
                //    That is about the PROPERTY, not about `Region` itself:
                //    `Region` is the C++ `PendingRegion` with
                //    `defaultProperty: "regions"` and an `isList` `regions`
                //    property (quickshell-core.qmltypes:644, :724-732), so one
                //    Region can hold several sub-regions combined by its
                //    `shape`/`intersection` enums. The dock uses the single
                //    rounded-rect form, which Quickshell tessellates into
                //    rectangles for ext-background-effect-v1.
                //  - Opacity does not reach the compositor (this is a
                //    protocol-side effect on the layer-shell surface), so the
                //    region's GEOMETRY is what decides whether niri blurs
                //    anything before the dock is up. Do not "simplify" the
                //    gate away.
                //
                // CORRECTION to the note that used to sit here. It claimed the
                // off-surface region alone was the whole ghost fix, and that
                // "no ghost frame was observed before the dock's first frame,
                // so that window is zero-length in practice". BOTH halves of
                // that were wrong, and the WAYLAND_DEBUG trace of a real
                // launch shows why: the window is NOT zero-length, it is the
                // whole startup.
                //   [14:20:39.311390] wl_surface#40.commit()          <- no region yet
                //   [14:20:39.356681] set_blur_region(nil)
                //   [14:20:39.382632] wl_surface#40.commit()          <- still nil
                //   [14:20:39.392414] set_blur_region(wl_region#52)   <- off-surface rects
                // The two early commits were at the FULL surface size, and both
                // put niri in `blur_region == None` — the layer rule's
                // whole-surface blur. The pixel measurement that "proved" the
                // old claim was worthless: this machine's desktop is not
                // static, so the changed-pixel counts were dominated by
                // unrelated churn in the sampled band.
                //
                // The `nil` is Quickshell's, not niri's:
                //   src/wayland/background_effect/surface.cpp
                //     void BackgroundEffectSurface::setBlurRegion(const QRegion& region) {
                //       if (region.isEmpty()) { this->set_blur_region(nullptr); return; }
                // and src/core/region.cpp builds the region from this QML's
                // x/y/width/height, where a zero width or height yields an
                // empty QRegion. Before the dock is laid out `_bgW`/`panelH`
                // are both 0, hence `nil`. `Math.max(1, …)` below makes that
                // impossible.
                //
                // The surface-size gate above handles the other half: the
                // creation commit that carries no region at all, which no
                // amount of region geometry can reach because it happens
                // before Quickshell has polished anything.
                BackgroundEffect.blurRegion: Region {
                    // Surface-local, and it MUST include dockHoverRegion.x:
                    // the painted rect is dockVisualRoot (x: _bgX) INSIDE
                    // dockHoverRegion, while this Region is surface-local, so
                    // the two agree only when the ancestor offset is added.
                    // dockHoverRegion is surfaceW wide but the layer surface is
                    // clamped by niri to the screen once surfaceW exceeds it, so
                    // its centre anchor lands it at x = -(clamp/2) ≠ 0. That
                    // measured −5 logical px here — the blur sat 9 device px
                    // right of the paint at BOTH ends. Same idiom as
                    // dockMaskTarget below.
                    // Pre-ready the region is moved OFF-SURFACE, not collapsed
                    // to zero size, so `has_blur_region` stays true and niri
                    // never falls back to the layer rule's whole-surface blur.
                    //
                    // niri branches on whether the client committed a
                    // NON-EMPTY region
                    // (src/render_helpers/background_effect.rs:305):
                    //     let has_blur_region = blur_region.as_ref()
                    //         .is_some_and(|r| !r.is_empty());
                    //     let blur = if has_blur_region {
                    //         effect.blur != Some(false)
                    //     } else {
                    //         effect.blur == Some(true)      // rule wins
                    //     };
                    // The layer rule `match namespace="quickshell"` in
                    // ~/.config/niri/config.kdl carries `blur true`, and it
                    // matches this surface because niri tests the namespace
                    // with an UNANCHORED regex (src/layer/mod.rs:130
                    // `namespace_re.0.is_match(surface.namespace())`), so
                    // "quickshell" matches "quickshell:dock". An empty/absent
                    // rect list therefore hands the WHOLE surface geometry to
                    // the rule — that is the large blurred rectangle.
                    //
                    // With a non-empty region niri keeps the whole surface as
                    // the effect geometry
                    // (background_effect.rs:245-248, `effect_geometry =
                    // surface_geo`) but hands the element the region as
                    // `subregion`, and BOTH draw paths intersect their damage
                    // with that subregion and return without drawing when
                    // nothing survives:
                    //   xray.rs:320-336            `if filtered_damage.is_empty()
                    //                                   { return Ok(()); }`
                    //   framebuffer_effect.rs:378-380  same, on `filtered`
                    // and filter_damage itself drops rects that miss the crop
                    // (utils/region.rs:72-75). So the element is BUILT over
                    // the whole surface but never rasterised outside the
                    // region, and an off-surface region rasterises nowhere.
                    // (The rule carries `xray false`, so the live path here is
                    // the framebuffer one; the xray path is quoted because it
                    // is the one that reads as "builds anyway".)
                    //
                    // `-100000` is far enough off-surface that it survives the
                    // render_params_for_tile subregion crop, and MEASURED
                    // non-empty on the wire: the trace above shows the
                    // committed rects as e.g. `wl_region#52.add(-99989, -99915,
                    // 135, 1)` — one rect per scanline of the rounded pill,
                    // all far off-surface. Nothing clamps them away.
                    //
                    // `Math.max(1, …)` on width/height is load-bearing and is
                    // what keeps `set_blur_region(nil)` from being sent: an
                    // empty QRegion is what produces the nil (see the
                    // correction note above). It only ever engages before the
                    // dock is laid out, where the pre-ready region is
                    // off-surface anyway and the exact size is irrelevant.
                    x: dockRoot._ready
                        ? (dockHoverRegion.x + dockRoot._bgX)
                        : -100000
                    width: Math.max(1, dockRoot._bgW)
                    height: Math.max(1, dockRoot.panelH)
                    y: dockRoot._ready ? dockRoot.panelOffsetY : -100000
                    topLeftRadius: dockRoot.rTL
                    topRightRadius: dockRoot.rTR
                    bottomRightRadius: dockRoot.rBR
                    bottomLeftRadius: dockRoot.rBL
                }

                Item {
                    id: dockContentRoot
                    anchors.fill: parent

                    // The fade half of the reveal. dockContentRoot holds the
                    // background, the shadow and the icon row (dockVisualRoot
                    // and dockBackground are both nested under it), so a zero
                    // here hides the whole surface — not just the icons —
                    // which is what the requirement asks for.
                    //
                    // Shares `dock.slideInDurationMs` with the slide on
                    // dockHoverRegion below, deliberately. This used to use
                    // elementMoveFast (170 ms) under a 280 ms slide, which
                    // measured as a 177 ms fade against a 273 ms slide: the
                    // dock was fully opaque with 96 px of travel still to go,
                    // so the last 38% of the motion was a slide with nothing
                    // to look at, and the whole thing read as a pop. One
                    // duration for both halves is what makes them one motion.
                    //
                    // Honouring animationsEnabled collapses this — and the
                    // slide — to an instant cut, matching every other
                    // Behaviour in this file. That is the one switch that
                    // makes the reveal genuinely not animate, and it is a
                    // single `theme.animations: false`.
                    opacity: dockRoot._ready ? 1.0 : 0.0
                    Behavior on opacity {
                        enabled: Appearance.animationsEnabled
                        animation: NumberAnimation {
                            duration: dockRoot._revealDurationMs
                            easing.type: Appearance.animation.elementMoveEnter.type
                        }
                    }

                    MouseArea {
                    id: dockMouseArea
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton

                    anchors.fill: parent

                    // Input-mask proxy. Invisible, zero visual effect: it
                    // exists only so the PanelWindow's `mask` Region has an
                    // item whose OWN x/y follow the slide. Its geometry is
                    // the dock pill rect (dockBackground, which holds the
                    // icons) expressed in window coordinates — dockMouseArea
                    // and dockContentRoot are both at 0,0 filling the
                    // surface, so the only offset is the animated
                    // dockHoverRegion slide. Same resting rect as before the
                    // gate, but the region is now re-sent while the dock
                    // slides instead of frozen at one stale position.
                    Item {
                        id: dockMaskTarget
                        x: dockHoverRegion.x + dockBackground.x
                        y: dockHoverRegion.y + dockBackground.y
                        width: dockBackground.width
                        height: dockBackground.height
                    }

                    Item {
                        id: dockHoverRegion

                        // Explicit surface-sized box (independent of the window,
                        // which shrinks to the trigger strip when hidden) so the
                        // panel keeps a stable position across the slide.
                        width: dockRoot.surfaceW
                        height: dockRoot.surfaceH

                        // Anchor to the edge of the window that is physically attached to the screen.
                        // This edge's compositor coordinate never moves when the window shrinks.
                        anchors {
                            horizontalCenter: !root.isVertical ? parent.horizontalCenter : undefined
                            verticalCenter: root.isVertical ? parent.verticalCenter : undefined

                            left: root.isLeft ? parent.left : undefined
                            right: root.position === "right" ? parent.right : undefined
                            top: root.isTop ? parent.top : undefined
                            bottom: root.position === "bottom" ? parent.bottom : undefined
                        }

                        // ── The slide ──────────────────────────────────────
                        //
                        // mock: computeHiddenSlideDelta. Sign is applied by the
                        // caller (negative margin pushes the panel off-screen).
                        //
                        // The panel travels a full `hiddenSlideDelta` (measured
                        // 108 logical px on a 118 px surface at the user's
                        // current config), and the surface is now full-size for
                        // the whole trip so there is real distance to cover.
                        // While the surface was 1x1 pre-ready there was none,
                        // and the "slide" could not be seen at all.
                        //
                        // The travel is the SUM of two terms, and it has to be:
                        //
                        //  - `launchSlide` is the launch reveal, on the
                        //    `slideInDurationMs` token.
                        //  - `hiddenOffset` is the auto-hide slide-out, kept on
                        //    the existing `elementMoveEnter` token so
                        //    auto-hide is unchanged.
                        //
                        // They cannot be one property with a direction test. A
                        // `Behavior` builds its animation at the instant the
                        // target property changes and reads `duration` from the
                        // binding at that moment, so a test that flips in the
                        // same propagation pass is always one step stale — and
                        // both `reveal` and `_ready` do exactly that. Measured
                        // with the 520 ms token configured, the slide still ran
                        // 258 ms: once keyed on `reveal`, and again on `_ready`.
                        // A term whose duration never changes at runtime has no
                        // such dependency.
                        //
                        // There is deliberately NO `Behavior` on the anchor
                        // margins themselves. The margin now just carries the
                        // sum, which is already smooth, so animating it a
                        // second time is not "belt and braces" — it is a
                        // second animation in series. Measured: `launchSlide`
                        // correctly ran 521 ms while the margin sat frozen for
                        // all of it and then ran its own 280 ms afterwards,
                        // giving a two-stage 801 ms slide whose first stage
                        // moved nothing. Smoothing belongs on the terms only.
                        //
                        // Both terms are non-negative and both only fall during
                        // a reveal, so the sum is monotonic and reaches zero
                        // exactly when the launch finishes. Pre-ready the sum
                        // is 2 * delta rather than delta — merely "further
                        // off-screen than before", and unobservable: the input
                        // mask is empty and the blur region is off-surface for
                        // that entire window.
                        property real launchSlide: dockRoot._ready
                            ? 0 : dockRoot.hiddenSlideDelta
                        Behavior on launchSlide {
                            enabled: Appearance.animationsEnabled
                            animation: NumberAnimation {
                                duration: dockRoot._revealDurationMs
                                easing.type: Appearance.animation.elementMoveEnter.type
                            }
                        }

                        property real hiddenOffset: dockRoot.reveal
                            ? 0 : dockRoot.hiddenSlideDelta
                        Behavior on hiddenOffset {
                            enabled: Appearance.animationsEnabled
                            animation: NumberAnimation {
                                duration: Appearance.animation.elementMoveEnter.duration
                                easing.type: Appearance.animation.elementMoveEnter.type
                            }
                        }

                        property real hideOffset: hiddenOffset + launchSlide
                        property real hideOffsetV: hiddenOffset + launchSlide

                        // Drive the slide animation with negative margins on the fixed edge
                        anchors.leftMargin: root.isLeft ? -hideOffsetV : 0
                        anchors.rightMargin: root.position === "right" ? -hideOffsetV : 0
                        anchors.topMargin: root.isTop ? -hideOffset : 0
                        anchors.bottomMargin: root.position === "bottom" ? -hideOffset : 0


                        // ─── Painted background ──────────────────────────
                        // This single item IS the OSD: the dock background
                        // itself, widened by whichever end the volume or
                        // brightness OSD is currently driving. At grow 0 its
                        // x/width are exactly panelOffsetX/panelW, so the
                        // resting dock is pixel-identical to before.
                        //
                        // Declared BEFORE dockBackground so it paints BEHIND
                        // the icons. Its own geometry is the single source of
                        // truth shared with BackgroundEffect.blurRegion
                        // (_bgX / _bgW).
                        Item {
                            id: dockVisualRoot
                            x: dockRoot._bgX
                            y: dockRoot.panelOffsetY
                            width: dockRoot._bgW
                            height: dockRoot.panelH

                            StyledRectangularShadow {
                                target: dockVisualBackground
                                direction: dockRoot.shadowEnabled ? (dockRoot.cfg?.shadowDirection ?? "down") : ""
                                alpha: dockRoot.shadowRenderAlpha

                                    // The shadow's interior is solid, intended to sit
                                    // behind an opaque panel. Hide it when the background is made
                                    // translucent so opacity reveals the desktop instead of the shadow.
                                visible: dockRoot.shadowEnabled
                            }

                            RoundedRectShape {
                                id: dockVisualBackground
                                readonly property bool gameModeMinimal: Appearance.gameModeMinimal

                                anchors.fill: parent

                                // width is _bgW >= panelW, so this is never a
                                // zero-width shape; the explicit guard is only
                                // here so a degenerate width can never paint a
                                // stray border line from borderWidth > 0.
                                visible: width > 0
                                    && (Config.options?.dock?.showBackground ?? true) && !gameModeMinimal
                                // The resting colour, with the current OSD band
                                // colour blended over it by the grow driver.
                                // The base expression itself is unchanged and is
                                // still evaluated in exactly one place; only the
                                // tint wrapper around it is new. Nothing else
                                // here changes: the shape keeps its constant
                                // radii and its constant concave corners at
                                // every tint strength. At rest the blend
                                // returns this expression's own value
                                // unchanged — see root._osdBlendTint for the
                                // source-over rule, the alpha handling and
                                // that guarantee.
                                color: root._osdBlendTint(
                                    ColorUtils.applyAlpha(
                                        (Config.options?.dock?.backgroundColor ?? "").length > 0
                                            ? Config.options.dock.backgroundColor
                                            : Appearance.colors.colLayer1,
                                        root._effectiveBgOpacity),
                                    root._osdBandTint, root._osdTintStrength)
                                borderWidth: Config.options?.dock?.borderWidth ?? 1
                                borderColor: (Config.options?.dock?.borderColor ?? "").length > 0
                                    ? Config.options.dock.borderColor
                                    : Appearance.colors.colLayer0Border
                                // Per-corner radii — RoundedRectShape renders an arc per
                                // corner (Rectangle only supports a uniform radius).
                                //
                                // Bound directly to the dock's own radii, with NO
                                // growth term: the background has the SAME
                                // rounding at rest and while fully expanded. The
                                // OSD widens this shape; it never re-shapes it.
                                topLeftRadius: dockRoot.rTL
                                topRightRadius: dockRoot.rTR
                                bottomLeftRadius: dockRoot.rBL
                                bottomRightRadius: dockRoot.rBR
                                // Concave carve on the corners facing the screen edge
                                // (mock: dockConcaveShape). Constant too.
                                topLeftConcave: dockRoot.concaveTL
                                topRightConcave: dockRoot.concaveTR
                                bottomLeftConcave: dockRoot.concaveBL
                                bottomRightConcave: dockRoot.concaveBR
                            }

                            // ─── OSD end glyphs ───────────────────────────
                            // The volume and brightness glyphs the OSD shows.
                            //
                            // END-ANCHORED BY DESIGN. Each glyph is pinned to
                            // ONE end of the grown pill with anchors.left /
                            // anchors.right and is NEVER positioned with
                            // anchors.centerIn, anchors.horizontalCenter or any
                            // expression derived from the dock's centre. This is
                            // the user's explicit requirement: these two
                            // indicators belong at the dock's two ends, not
                            // stacked across its middle. If a future edit makes
                            // either glyph track the centre, that is a
                            // regression — put it back on its end.
                            //
                            // WHY THEY LIVE IN dockVisualRoot AND NOT
                            // dockBackground: dockVisualRoot IS the painted pill,
                            // and it is the item whose x/width the OSD already
                            // drives (_bgX / _bgW). Anchoring to it puts the
                            // volume glyph on the leading tip of the bar the
                            // volume has grown and the brightness glyph on the
                            // trailing tip of the bar the brightness has grown,
                            // so the glyph and the length it labels stay
                            // together at the same end. They must NOT move into
                            // dockBackground: that item keeps the fixed
                            // functional rect (panelOffsetX / panelW, neither of
                            // which carries a growth term), so anchoring there
                            // would strand the glyphs at the RESTING pill ends
                            // and leave them detached from the growing bar.
                            //
                            // They are plain children of a non-interactive
                            // item, so they add nothing to the dock's clickable
                            // area: the input mask targets dockBackground
                            // (Dock.qml:1313), which they are not inside.
                            //
                            // TIMING: opacity is bound straight to the same
                            // _osdVolumeGrow / _osdBrightnessGrow drivers the pill
                            // geometry and the band tint read, so the glyphs
                            // appear, hold and fade on precisely the existing OSD
                            // timing (show ease, osdVolumeHold/osdBrightnessHold at
                            // dock.osd.holdMs, hide ease). No second timer is
                            // introduced and none can drift out of step with the
                            // bar.
                            readonly property real _osdGlyphSize: Math.max(
                                Appearance.font.pixelSize.normal,
                                Math.min(40, dockRoot.iconSize * 0.5))
                            readonly property real _osdGlyphPad: 14

                            // Volume: leading (left) end, the end volume grows.
                            MaterialSymbol {
                                id: osdVolumeGlyph
                                anchors.left: parent.left
                                anchors.leftMargin: dockVisualRoot._osdGlyphPad
                                anchors.verticalCenter: parent.verticalCenter
                                width: dockVisualRoot._osdGlyphSize
                                height: dockVisualRoot._osdGlyphSize
                                iconSize: dockVisualRoot._osdGlyphSize
                                text: root._osdMuted ? "volume_off" : "volume_up"
                                color: Appearance.colors.colOnLayer0
                                opacity: root._osdVolumeGrow
                                visible: opacity > 0.001
                                    && (Config.options?.dock?.showBackground ?? true)
                            }

                            // Brightness: trailing (right) end, the end
                            // brightness grows.
                            MaterialSymbol {
                                id: osdBrightnessGlyph
                                anchors.right: parent.right
                                anchors.rightMargin: dockVisualRoot._osdGlyphPad
                                anchors.verticalCenter: parent.verticalCenter
                                width: dockVisualRoot._osdGlyphSize
                                height: dockVisualRoot._osdGlyphSize
                                iconSize: dockVisualRoot._osdGlyphSize
                                text: "brightness_medium"
                                color: Appearance.colors.colOnLayer0
                                opacity: root._osdBrightnessGrow
                                visible: opacity > 0.001
                                    && (Config.options?.dock?.showBackground ?? true)
                            }
                        }

                        // ─── Input mask + icon layout ─────────────────────
                        // This item is the PanelWindow's input `mask` target,
                        // so it deliberately keeps the FUNCTIONAL pill rect
                        // (panelOffsetX / panelW) and never grows: the
                        // clickable region of the dock is unchanged by the OSD,
                        // while the painted background behind it does grow.
                        //
                        // Because the icons are centred in THIS fixed rect
                        // rather than in the grown painted shape, widening the
                        // background cannot re-centre or slide them — dockRow.x
                        // and dockRow.width are independent of _osdGrowL/_osdGrowR.
                        //
                        // This item must NOT clip. Magnified icons deliberately
                        // overhang the pill on every side — that is the point
                        // of hover magnification and activeScale. The surface
                        // reserves that room as zoomMainPad / zoomCrossPad
                        // around this rect (see surfaceW/surfaceH), which is
                        // exactly why the icons are allowed to overflow here.
                        // Before the OSD refactor, `clip` lived on the painted
                        // shape while dockRow was its SIBLING, so it never
                        // applied to the icons at all; moving the icons into
                        // this rect made the same `clip` bind them for the
                        // first time and cut the overhang off.
                        Item {
                            id: dockBackground

                            // Panel rect inside the surface: bleed + concave
                            // inset + marginEnds from the leading edge.
                            x: dockRoot.panelOffsetX
                            y: dockRoot.panelOffsetY
                            width: dockRoot.panelW
                            height: dockRoot.panelH

                            RowLayout {
                                id: dockRow
                                visible: !root.isVertical
                                anchors.centerIn: parent
                                spacing: dockRoot.itemSpacing
                                property real padding: dockRoot.mainAxisPadding

                                DockApps {
                                    id: dockApps
                                    buttonPadding: dockRow.padding
                                    pageWidth: _pageWidth
                                    pageHeight: _pageHeight
                                    vertical: false
                                    dockPosition: root.position
                                    parentWindow: dockRoot
                                }
                            }

                              ColumnLayout {
                                  id: dockColumn
                                  visible: root.isVertical
                                  anchors.centerIn: parent
                                spacing: dockRoot.itemSpacing
                                property real padding: dockRoot.mainAxisPadding

                                DockApps {
                                    id: dockAppsVertical
                                    buttonPadding: dockColumn.padding
                                    pageWidth: _pageWidth
                                    pageHeight: _pageHeight
                                    vertical: true
                                    dockPosition: root.position
                                    parentWindow: dockRoot
                                }
                            }
                        }
                    }
                }
                }
            }
        }
    }

    // ─── Exclusive-zone spacer ────────────────────────────────────────
    // Invisible surface that reserves screen edge space. Niri requires
    // full-span anchoring (3 edges) for exclusive zone to work, which
    // conflicts with the floating blur surface. This separate surface
    // handles the reservation while the dock stays content-sized.
    Loader {
        active: (root._useExclusive || (Config.options?.dock?.reserveSpace ?? false))
            && root._enabled
            && Quickshell.screens.length > 0
        sourceComponent: PanelWindow {
            readonly property var cfg: Config.dockConfigForScreen(Quickshell.screens[0])
            screen: Quickshell.screens[0]
            visible: !GlobalStates.screenLocked && !GameMode.shouldHidePanels && !GlobalStates.widgetEditMode
            WlrLayershell.namespace: "quickshell:dock-exclusive"
            WlrLayershell.layer: (cfg?.layer ?? "top") === "overlay" ? WlrLayer.Overlay : WlrLayer.Top
            color: "transparent"

            anchors {
                top: root.isTop || root.isVertical
                bottom: root.position === "bottom" || root.isVertical
                left: root.isLeft || !root.isVertical
                right: root.position === "right" || !root.isVertical
            }

            // reserveSpace follows the mock formula; the legacy exclusiveZone
            // key, when set, still wins so existing configs keep working.
            exclusiveZone: (Config.options?.dock?.exclusiveZone ?? 0) > 0
                ? (Config.options.dock.exclusiveZone ?? 0)
                : root._exclusiveZoneFor(cfg, root.position)
            implicitWidth: 1
            implicitHeight: 1

            Item { id: spacerEmpty; width: 0; height: 0 }
            mask: Region { item: spacerEmpty }
        }
    }
}