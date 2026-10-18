pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Stand-alone configuration for the dock.
//
// Models only the `dock.*` keys the dock reads/writes (plus a tiny `theme`
// block consumed by Appearance). Options live in a reactive QtObject tree so
// that QML Connections (e.g. onPinnedAppsChanged) fire normally, and changes
// are persisted next to the shell that loaded them: `Quickshell.shellDir` is
// "the full path to the root directory of your shell ... the folder containing
// the entrypoint", so `qs -c dock` writes ~/.config/quickshell/dock/config.json
// while a copy launched via `qs -p /tmp/copy/shell.qml` reads and writes
// /tmp/copy/config.json instead of the live config.

Singleton {
    id: root

    signal configChanged

    readonly property string configDir: Quickshell.shellDir
    readonly property string filePath: configDir + "/config.json"

    property bool ready: false

    // The single object the dock addresses as `Config.options?.dock?.<key>`.
    property QtObject options: QtObject {
        id: opts

        property QtObject dock: QtObject {
            id: dockOpts
            property bool pinnedOnStartup: true
            property string position: "bottom"
            // Icon magnify — usable in any style.
            property bool magnify: false
            property bool magnifyActive: true    // whether the focused app's icon also magnifies
            property real magnifyScale: 1.28        // hovered icon scale
            property real magnifyNeighborScale: 1.15 // adjacent icons
            property int magnifyRadius: 2           // how many neighbors magnify
            property real height: 60
            property real iconSize: 35
            // Fixed background thickness (px). null = auto (icon + padding).
            // When set to a positive number the pill uses it verbatim, so
            // magnified icons may overhang it.
            property var backgroundHeight: null
            property real spacing: 2
            property real padding: 5
            property real margin: 8
            property string backgroundColor: ""
            property real backgroundOpacity: 1.0
            property bool blur: false
            property real borderWidth: 1
            property string borderColor: ""
            property var borderRadius: null
            // Per-corner overrides; null falls back to `borderRadius` (then to
            // the Appearance default). Mirrors Rectangle-style corner naming.
            property var borderRadiusTopLeft: null
            property var borderRadiusTopRight: null
            property var borderRadiusBottomLeft: null
            property var borderRadiusBottomRight: null
            property real indicatorWidth: 10
            property real indicatorHeight: 4
            property string indicatorColor: ""
            // Right-click context menu surface (modules/common/widgets
            // /ContextMenu.qml). Empty string = "use the Appearance token",
            // which is theme-dependent (accent + dark), so these must not
            // carry a hardcoded default.
            property string contextMenuBackgroundColor: ""
            property string contextMenuBorderColor: ""
            property string contextMenuTextColor: ""
            property string contextMenuSeparatorColor: ""
            // Corner radius (px) of the right-click menu card, in logical px.
            //
            // SINGLE radius, not four per-corner variants, unlike
            // `borderRadius*` above. The reason those exist on the dock is
            // that a layer-shell dock can round only the OUTER two corners
            // (`concaveEdgeCorners` hugs the screen edge). This menu is a
            // floating popup: all four corners are interior, and it has no
            // edge-concave mode to express, so per-corner keys would be four
            // knobs for a shape the widget never draws asymmetrically.
            //
            // DEFAULT -1 = "not configured", NOT "square". The fallback lives
            // at the use site (ContextMenu.qml) and resolves to
            // `Appearance.rounding.normal` (12), so an absent key keeps the
            // menu pixel-identical to today. Baking 12 in here instead would
            // work today but would silently decouple the menu from the token:
            // change `Appearance.rounding.normal` and the dock's other
            // surfaces would follow while this menu quietly kept 12.
            property int contextMenuBorderRadius: -1
            // ── Right-click menu: shape and rows ────────────────────────
            // Defaults are -1/"not configured" where the value is an
            // Appearance token or a previous literal, so an absent key keeps
            // the menu pixel-identical to the hardcoded version. The
            // fallbacks live at the use site (ContextMenu.qml).

            // Outline thickness (px) of the menu card. 0 = no outline.
            property real contextMenuBorderWidth: -1
            // Height (px) of each menu row.
            property real contextMenuItemHeight: -1
            // Corner radius (px) of a row's hover/ripple highlight.
            property real contextMenuItemRadius: -1
            // Minimum width (px) of the menu card, so short labels do not
            // produce a cramped popup.
            property real contextMenuMinWidth: -1
            // Label font size (px); -1 = Appearance.font.pixelSize.small.
            property real contextMenuTextSize: -1
            // Icon size (px); -1 = Appearance.font.pixelSize.normal.
            property real contextMenuIconSize: -1
            // Row hover / ripple tint. "" = the accent at 85% / 70%
            // transparency, as before these keys existed.
            property string contextMenuItemHoverColor: ""
            property string contextMenuItemRippleColor: ""
            // There is deliberately NO `contextMenuBackdropBlur` option, and
            // the reason is NOT "the compositor already blurs the popup".
            //
            // It used to claim exactly that, and it was false: it pointed at
            // `window-rule { popups { background-effect { blur true } } }` in
            // ~/.config/niri/config.kdl as if that rule covered this menu. It
            // does not. The menu is an xdg-popup OF A LAYER-SHELL SURFACE, and
            // niri never evaluates `window-rule` for a layer-shell surface —
            // a layer surface's rules come from `config.layer_rules` alone
            // (src/handlers/layer_shell.rs passes `&config.layer_rules` to
            // LayerRuleSet::compute; `config.window_rules` is read only on the
            // xdg/toplevel path). So the popup's rules stay
            // `ResolvedPopupsRules::default()`, whose
            // `background_effect.blur` is `None`.
            //
            // With no client region and blur `None`,
            // src/render_helpers/background_effect.rs:117-122 takes the
            // else-branch — `effect.blur == Some(true)` — which is FALSE, so
            // niri renders no background effect for the menu at all. That is
            // why the context menu stayed sharp for three rounds of reports.
            //
            // Committing a non-empty `BackgroundEffect.blurRegion` on the
            // PopupWindow flips that branch to `None != Some(false)` → true.
            // The client region is therefore what ENABLES the blur, not a
            // supplement to a rule that already did the work — and there is
            // nothing to configure about it: it is not on or off, and it is
            // not a visual preference. See
            // modules/common/widgets/ContextMenu.qml for the mechanism.
            property bool bounceOnClick: true
            property real bounceDistance: 14
            property var screenList: []
            property var pinnedApps: [
                "firefox",
                "org.wezfurlong.wezterm",
                "code",
                "thunar",
                "spotify"
            ]
            property bool separatePinnedFromRunning: true
            property bool showSeparator: true
            property var ignoredAppRegexes: []
            property bool hoverPreview: true
            property real hoverPreviewDelay: 400
            property bool hoverToReveal: true
            // Swipe-to-hide gesture tuning. Read by DockApps.qml, which falls
            // back to the same values when the keys are absent.
            property real swipeSensitivity: 1.0   // multiplier on drag distance
            property real swipeThreshold: 0.25    // fraction of the dock to cross
            property bool showOnDesktop: true
            property bool showBackground: true
            property bool enableDragReorder: true
            property bool smartIndicator: true
            property bool showAllWindowDots: false
            property int maxIndicatorDots: 5
            property bool keepPreviewOnClick: false
            property real exclusiveZone: 0
            property string hoverBackgroundColor: ""
            property bool disableRipple: false
            // Context menu → "Change icon…" rewrites the app's desktop entry
            // under ~/.local/share/applications so the new icon applies
            // systemwide (see services/Apps/IconOverride.qml). It writes to
            // the user directory only — never a system one, never root — but
            // it is still a system-modifying action, so it is switchable off.
            property bool changeIconEnabled: true
            property bool slideIn: true
            // Duration of the launch reveal, in ms. Drives BOTH the slide-in
            // of the panel and its cross-fade, so the two read as one motion.
            //
            // 520 is chosen against the tokens in Appearance.animation rather
            // than invented: every elementMove* token is 170-280 ms and
            // `dock.bounce.bounceDurationMs` is 600. Measured before this key
            // existed, a launch reveal took 273 ms of slide and 177 ms of
            // fade (elementMoveEnter / elementMoveFast), i.e. the fade was
            // finished at 62% of the slide and the dock had visibly "arrived"
            // while still moving — it read as a pop, not a reveal. 520 puts
            // the reveal at the same order as the dock's own slowest motion
            // (the bounce) while staying well inside the ~2 s the icon gate
            // already costs, so the reveal never feels like it is late.
            property int slideInDurationMs: 520
            property real maxDockHeight: 0
            // Bounded fallback for the icon-readiness gate: if the icons never
            // all resolve (an unresolvable icon leaves an Image at status Null,
            // the theme index fails to build), the dock reveals anyway after
            // this many ms rather than staying invisible forever. Set to 0 to
            // wait indefinitely.
            // 5000 is measured, not guessed. IconThemeService builds its theme
            // index by shelling out over every icon directory, and that harvest
            // alone measures ~2.0-2.8 s from panel creation on this machine
            // (four consecutive cold+warm starts revealed at 2513 / 2212 /
            // 2649 / 2076 ms). The fallback must clear that worst case or it
            // stops being a fallback and becomes the normal path — at 2500 ms
            // it fired BEFORE the real gate on one of those runs, defeating the
            // whole point. Roughly 2x the observed worst case.
            property int iconsReadyTimeoutMs: 5000
            // ── Ported from the C++ mock's DockConfig ──────────────────────
            // These mirror `struct DockConfig` in the mock's
            // src/config/config_types.h. Defaults are the mock's defaults.

            // Cross-axis inner padding (mock: cross_axis_padding, default 8).
            property real crossAxisPadding: 8
            // Inset from each end of the dock along its main axis
            // (mock: margin_ends, default 0).
            property real marginEnds: 0
            // Distance from the screen edge; > 0 floats the dock and disables
            // the concave edge corners (mock: margin_edge, default 0).
            property real marginEdge: 0

            // Carve concave corners on the side touching the screen edge
            // (mock: concave_edge_corners, default true).
            property bool concaveEdgeCorners: true

            // Focused vs unfocused icon scale. The mock defaults are 1.0/0.85.
            property real activeScale: 1.0
            property real inactiveScale: 0.85
            // Focused vs unfocused icon opacity (mock: 1.0/0.85).
            property real activeOpacity: 1.0
            property real inactiveOpacity: 0.85

            // Lift applied to the FOCUSED window's icon, in px, along the axis
            // pointing away from the screen edge (up for a bottom dock, down for
            // top, right for left, left for right).
            //
            // DEVIATION FROM THE MOCK — no mock key exists, because the C++ dock
            // never repositions the active icon. Its item layer holds items at
            // restMainPos (updateVisuals :1058-1059) and pins the icon's centre
            // (applyHoverIconVisual :114-127); the only translation it applies is
            // the neighbour spread, gated on pointerActive (updateHoverZoom
            // :1325-1339). Set to 0 for strict mock behaviour.
            property real activeIconShift: 10

            // Running-window dots below each icon (mock: show_dots, default
            // false). Distinct from showAllWindowDots/smartIndicator, which
            // colour and size the dots already present.
            property bool showDots: false
            // Count badge when an app has >1 window (mock: show_instance_count).
            property bool showInstanceCount: true
            // Also show running apps that are not pinned (mock: show_running).
            property bool showRunning: true

            // Master opt-in gate (mock: enabled). When false the dock does not
            // create any surface at all — distinct from pinnedOnStartup, which
            // only controls whether hover-to-reveal applies.
            // mock: `bool enabled = false; // opt-in; dock is hidden by default`
            // (config_types.h:155). Kept false for fidelity — this dock's own
            // config.json sets "enabled": true explicitly, and because Config
            // persists its snapshot that value survives reloads.
            property bool enabled: false

            // App-launcher button (mock: launcher_position).
            // "none" | "start" | "end"
            property string launcherPosition: "none"
            // Tabler glyph name, or an absolute image path to override it.
            property string launcherIcon: "grid-dots"
            property bool launcherCustomImageColorize: false

            // Launch bounce (mock: bounce_on_launch / bounce_style).
            // bounceStyle: "none" | "overshoot" | "doubleHop"
            property bool bounceOnLaunch: true
            property int bounceDurationMs: 600
            property string bounceStyle: "doubleHop"

            // Reserve compositor exclusive space (mock: reserve_space).
            // Independent of autoHide, as in the mock.
            property bool reserveSpace: false
            // Layer-shell layer for the dock surface (mock: layer, "top"|"overlay").
            property string layer: "top"

            // Render only on the active output (mock: active_monitor_only).
            property bool activeMonitorOnly: false
            // Hide while the active workspace has windows; show when empty
            // (mock: smart_auto_hide).
            property bool smartAutoHide: false

            // Global shadow (mock: shell.shadow.{direction,alpha}; direction
            // one of center|down|up|left|right|downLeft|downRight|upLeft|upRight).
            property string shadowDirection: "down"
            property real shadowAlpha: 0.55
            // Shadow on/off (mock: dock.shadow). Independent of the background's
            // own opacity — the mock's surface_shadow::enabled() consults only
            // this flag, while the rendered alpha separately multiplies in
            // backgroundOpacity.
            property bool shadow: true

            // Per-output overrides (mock: monitor_overrides). Each entry is
            // { match, ...overrides } and the first match wins, exactly as in
            // the mock's ConfigService::resolveForOutput. Only the keys below
            // are overridable per output.
            property var monitorOverrides: []

            // Per-line clock configuration. Sizes/offsets/spacing use null as
            // "auto" (derived from iconSize / font metrics); explicit values win.
            //
            // `enabled` is the clock's single master switch and the only thing
            // that decides whether a clock appears in the dock: when true the
            // clock is added as an ordinary dock item, when false it is not
            // added at all. It needs no entry in `pinnedApps` — the clock is a
            // dock feature, not an application. A legacy "__clock__" string in
            // pinnedApps is still honoured, but only as a POSITION anchor for
            // where the clock sits among the pinned apps; it cannot switch the
            // clock back on when `enabled` is false. Defaults to true, so a
            // config that predates this switch gets a clock on the dock.
            property QtObject clock: QtObject {
                id: clockOpts
                property bool enabled: true
                property string mode: "digital"     // "digital" | "analog"
                property string analogBackground: "" // SVG behind analog face; "" = digital background
                property string digitalBackground: "" // SVG behind digital clock; "" = none (glass shows through)
                property bool analogSeconds: false
                property string analogHandColor: ""
                property string analogSecondColor: "#ff5a5a"
                property bool showHour: true
                property bool showMinutes: true
                property var hourSize: null
                property var minuteSize: null
                property real hourStretch: 1.0
                property real minuteStretch: 1.0
                property real hourOffsetX: 0
                property var hourOffsetY: null
                property real minuteOffsetX: 0
                property real minuteOffsetY: 0
                property string hourColor: ""
                property string minuteColor: ""
                property string hourWeight: "DemiBold"
                property string minuteWeight: "DemiBold"
                property string hourAlign: "center"
                property string minuteAlign: "center"
                property var clockSpacing: null
            }
            // OSD-style volume / brightness feedback. Its own nested group
            // for the same reason `clock` is: a discrete feature rather than a
            // slice of the dock's own settings. Persisted to dock.osd.*.
            property QtObject osd: QtObject {
                id: osdOpts
                // Master switch. When false the dock reads neither service.
                property bool enabled: true
                // How long the dock background stays grown before easing back.
                property int holdMs: 1500
                // Duration of BOTH the grow and the shrink ease, in ms.
                property int durationMs: 260
                // How far the background extends past one end, in px, at full
                // growth. The dock surface is already held wider than the pill,
                // so this never resizes the layer-shell surface.
                //
                // 240 is sized against the real clamp budget on this machine
                // (_osdMaxGrowL/_osdMaxGrowR = 323.5 px per end): it uses 74%
                // of it and still leaves ~83 px, so a full-range bar cannot
                // be truncated. The previous 64 used only 20% of the same
                // budget, which is why steps read as too small.
                //
                // A volume step is typically 5%, so the travel per step is
                // growWidth * 5 / maxLevel = 240 * 5 / 150 = 8 px, versus
                // 64 * 5 / 100 = 3.2 px before — comfortably distinguishable.
                // Brightness spans 0..100, giving 12 px per 5% step.
                property real growWidth: 240

                // Global opacity multiplier for the OSD BACKGROUND TINT only,
                // 0..1. It scales the whole tint regardless of level, on top of
                // the per-band alpha byte in the colours below and on top of
                // the level-proportional grow driver — so it is the one knob
                // that dims (or fully removes, at 0) the tint WITHOUT editing
                // every band colour and WITHOUT touching the glyphs, which keep
                // their own level-driven fade.
                //
                // 1.0 (default) leaves the tint exactly as the band alpha and
                // the level alone produce it, i.e. the previous behaviour.
                property real tintOpacity: 1.0

                // ─── Band colours ────────────────────────────────────────
                // The colours the dock tints itself with while the OSD shows,
                // one per level band. Format is mako's `#rrggbbaa` (alpha byte
                // INCLUDED, in mako's byte order — Dock.qml reorders it for Qt
                // in `_makoColor`).
                //
                // These DEFAULTS are mirrored from `~/.config/mako/config`
                // (`[app-name=OSD category=volume-*]` / `brightness-*`, their
                // `progress-color` values) and from the band THRESHOLDS in
                // `~/.config/niri/scripts/volume-osd.sh` (~lines 298-314) and
                // `brightness-osd.sh`. The dock is tinted to match the mako
                // notification OSD, so editing a colour here — or in
                // config.json, into which these are materialised — on purpose
                // overrides the DOCK's OSD only; it will no longer agree with
                // what mako paints unless mako is changed to match.
                //
                // A band omitted from a map falls through to the per-band
                // fallback in Dock.qml's `_triggerOsd`, so a partial edit is
                // safe and a missing one is not fatal.
                property var volumeBands: ({
                    // progress-color, `[app-name=OSD category=volume-*]`
                    low:   "#4a90d950",   // blue
                    mid:   "#4eb35650",   // green
                    high:  "#e0683f50",   // green turning orange
                    max:   "#e04b4550",   // orange turning red
                    boost: "#e04b4580",   // >100%: same red, higher alpha
                    muted: "#00000050"    // black
                })
                property var brightnessBands: ({
                    // progress-color, `[app-name=OSD category=brightness-*]`
                    low:  "#f6c36d20",
                    mid:  "#f3c64140",
                    high: "#ebca0f60",
                    max:  "#dccf0e90"
                })
            }
        }

        property QtObject theme: QtObject {
            id: themeOpts
            property string accent: "#7c5cff"
            property bool dark: true
            // Master switches read by Appearance.animationsEnabled (39 call
            // sites) / Appearance.effectsEnabled (one, in
            // StyledRectangularShadow). Default true so behaviour is unchanged
            // unless the user opts out.
            property bool animations: true
            property bool effects: true
        }
    }

    // ── Persistence schema ──────────────────────────────────────────────
    // The single source of truth for how config.json is laid out. Each entry
    // maps one JSON group to the flat `Config.options.dock.<name>` properties
    // it persists; the QML property tree stays FLAT so every existing read
    // site (`Config.options?.dock?.iconSize`) keeps working untouched.
    //
    // Adding a key = adding its name to a group below. Defaults are NOT
    // duplicated here — they live on the QtObject declarations above, so this
    // list only answers "which keys serialize, and under which heading".
    // A null default means "auto".
    // NOTE: built by a function rather than written inline as
    // `property var x: { ... }` — QML parses a brace-initializer binding as an
    // object DECLARATION, so a second bare `key: [...]` line is a syntax error.
    // A function body is ordinary JS and accepts the map literal.
    readonly property var configSchema: _buildConfigSchema()

    // On-disk layout version, written as `version` on every save so a future
    // migration can recognise older files. _hydrate() still accepts the
    // pre-version flat layout regardless, so this is documentation, not a gate.
    readonly property int configVersion: 1

    // The clock's keys persist to `dock.clock` (its own nested group, since it
    // is a single widget rather than a slice of the dock's own settings).
    readonly property var clockKeys: [
        "enabled", "mode", "analogBackground", "digitalBackground",
        "analogSeconds", "analogHandColor", "analogSecondColor",
        "showHour", "showMinutes",
        "hourSize", "minuteSize", "hourStretch", "minuteStretch",
        "hourOffsetX", "hourOffsetY", "minuteOffsetX", "minuteOffsetY",
        "hourColor", "minuteColor", "hourWeight", "minuteWeight",
        "hourAlign", "minuteAlign", "clockSpacing"
    ]
    // The OSD's keys persist to `dock.osd`, its own nested group for the same
    // reason as `clock`.
    readonly property var osdKeys: [
        "enabled", "holdMs", "durationMs", "growWidth", "tintOpacity",
        "volumeBands", "brightnessBands"
    ]
    // The `theme` group is a top-level sibling of `dock`, not one of the
    // `dock.*` schema groups, so it is snapshotted explicitly below rather
    // than through configSchema. Listing its keys here follows the same
    // convention as clockKeys/osdKeys.
    readonly property var themeKeys: ["accent", "dark", "animations", "effects"]


    function _buildConfigSchema() {
        return {
            "layout": ["position", "height", "backgroundHeight", "iconSize", "spacing", "padding", "margin", "maxDockHeight", "crossAxisPadding", "marginEnds", "marginEdge", "exclusiveZone"],
            "appearance": ["backgroundColor", "backgroundOpacity", "blur", "showBackground", "borderWidth", "borderColor", "borderRadius", "borderRadiusTopLeft", "borderRadiusTopRight", "borderRadiusBottomLeft", "borderRadiusBottomRight", "hoverBackgroundColor", "disableRipple", "concaveEdgeCorners", "shadow", "shadowDirection", "shadowAlpha", "contextMenuBackgroundColor", "contextMenuBorderColor", "contextMenuTextColor", "contextMenuSeparatorColor", "contextMenuBorderRadius", "contextMenuBorderWidth", "contextMenuItemHeight", "contextMenuItemRadius", "contextMenuMinWidth", "contextMenuTextSize", "contextMenuIconSize", "contextMenuItemHoverColor", "contextMenuItemRippleColor"],
            "icons": ["activeScale", "inactiveScale", "activeOpacity", "inactiveOpacity", "activeIconShift", "magnify", "magnifyActive", "magnifyScale", "magnifyNeighborScale", "magnifyRadius"],
            "indicators": ["indicatorWidth", "indicatorHeight", "indicatorColor", "showDots", "showInstanceCount", "showAllWindowDots", "maxIndicatorDots", "smartIndicator"],
            "apps": ["pinnedApps", "separatePinnedFromRunning", "showSeparator", "ignoredAppRegexes", "showRunning", "enableDragReorder"],
            "interaction": ["hoverPreview", "hoverPreviewDelay", "hoverToReveal", "keepPreviewOnClick", "swipeSensitivity", "swipeThreshold"],
            "behavior": ["enabled", "pinnedOnStartup", "showOnDesktop", "smartAutoHide", "activeMonitorOnly", "reserveSpace", "layer", "slideIn", "slideInDurationMs", "iconsReadyTimeoutMs", "changeIconEnabled"],
            "launcher": ["launcherPosition", "launcherIcon", "launcherCustomImageColorize"],
            "bounce": ["bounceOnClick", "bounceDistance", "bounceOnLaunch", "bounceDurationMs", "bounceStyle"],
            "screens": ["screenList", "monitorOverrides"]
        }
    }

    // ── Per-output overrides (mock: ConfigService::resolveForOutput) ────────
    // The mock resolves an output's config by taking the FIRST override whose
    // `match` selector hits that output, else the base config. A selector is a
    // case-insensitive substring of the output's connector name, description,
    // make or model; an empty selector matches NOTHING, so a malformed entry
    // cannot silently apply everywhere. Quickshell's screen object exposes
    // `name` (the connector, e.g. "eDP-1") plus, where the compositor supplies
    // them, `description`/`manufacturer`/`model`, which we match the same way.
    function outputMatchesSelector(selector: string, screen: var): bool {
        if (!selector || selector.length === 0) return false
        const needle = String(selector).toLowerCase()
        const haystacks = [
            screen?.name,
            screen?.description,
            screen?.manufacturer,
            screen?.model
        ]
        for (const h of haystacks) {
            if (h === undefined || h === null) continue
            if (String(h).toLowerCase().indexOf(needle) !== -1) return true
        }
        return false
    }

    // Keys a per-output override is allowed to change. Anything else in an
    // override entry is ignored, matching the mock, where overrides are typed
    // structs rather than free-form maps.
    readonly property var overridableKeys: [
        "position", "height", "iconSize", "activeScale", "inactiveScale",
        "activeOpacity", "inactiveOpacity", "activeIconShift", "spacing", "padding",
        "crossAxisPadding", "margin", "marginEnds", "marginEdge",
        "backgroundColor", "backgroundOpacity", "blur", "borderWidth",
        "borderColor", "borderRadius", "borderRadiusTopLeft",
        "borderRadiusTopRight", "borderRadiusBottomLeft", "borderRadiusBottomRight",
        "concaveEdgeCorners", "magnify", "magnifyScale", "magnifyActive",
        "showDots", "showInstanceCount", "showAllWindowDots", "smartIndicator",
        "bounceOnLaunch", "bounceStyle", "bounceDurationMs", "reserveSpace",
        "layer", "activeMonitorOnly", "smartAutoHide", "hoverToReveal",
        "pinnedApps", "launcherPosition", "launcherIcon",
        "showRunning", "enabled", "shadow", "shadowDirection", "shadowAlpha",
        // Read via `cfg?.…` in Dock.qml; without these two entries the reads
        // were permanently undefined (showOnDesktop's `!== false` guard was a
        // tautology, and the maxDockHeight cap never applied on that path).
        "showOnDesktop", "maxDockHeight",
    ]

    // Effective dock options for one output. Returns a PLAIN object, not the
    // live config: applying an override must not write through to the shared
    // base. Callers re-evaluate on Config.configChanged.
    function dockConfigForScreen(screen: var): var {
        const base = opts.dock
        const resolved = {}
        for (const k of root.overridableKeys) resolved[k] = base[k]
        const list = base.monitorOverrides
        if (!Array.isArray(list) || list.length === 0) return resolved
        for (const ov of list) {
            if (!ov || typeof ov !== "object") continue
            if (!root.outputMatchesSelector(ov.match ?? "", screen)) continue
            // First match wins, exactly as in the mock.
            for (const k of root.overridableKeys) {
                if (ov[k] !== undefined && ov[k] !== null) resolved[k] = ov[k]
            }
            return resolved
        }
        return resolved
    }

    function _applyToPath(path, value): void {
        const parts = String(path ?? "").split(".").filter(p => p.length > 0)
        if (parts.length < 2) return
        let obj
        if (parts[0] === "dock") obj = opts.dock
        else if (parts[0] === "theme") obj = opts.theme
        else return
        for (let i = 1; i < parts.length - 1; i++) {
            obj = obj[parts[i]]
            if (!obj) return
        }
        obj[parts[parts.length - 1]] = value
    }

    function setNestedValue(path, value): void {
        _applyToPath(path, value)
        fileWriteTimer.restart()
        root.configChanged()
    }

    // Serializes the full config tree into the GROUPED on-disk layout described
    // by `configSchema`: dock.<group>.<key>, plus dock.clock.<key> and theme.
    // This is the only place the on-disk shape is defined, so the grouping
    // lives here and nowhere else.
    function _snapshot(): var {
        const d = {}
        for (const g in root.configSchema) {
            const bucket = {}
            for (const n of root.configSchema[g]) bucket[n] = opts.dock[n]
            d[g] = bucket
        }
        const c = {}
        for (const n of root.clockKeys) c[n] = opts.dock.clock[n]
        d.clock = c
        const o = {}
        for (const n of root.osdKeys) o[n] = opts.dock.osd[n]
        d.osd = o
        const th = {}
        for (const n of root.themeKeys) th[n] = opts.theme[n]
        return { version: root.configVersion, dock: d, theme: th }
    }
    // Loads persisted values from parsed JSON. A null entry means "auto" and is
    // left unset so the QML default (also null) governs the behavior. Theme is
    // handled independently below.
    //
    // Accepts the grouped layout (current) and the legacy FLAT layout, where
    // every dock key sat directly under `dock` with only `clock` nested. A file
    // containing none of the current group names is read as legacy-flat, so an
    // older config.json keeps working instead of silently resetting to
    // defaults.
    function _hydrate(json): void {
        const d = json?.dock
        if (!d) return
        // A grouped file names at least one group; a flat one names none of
        // them. That is what distinguishes the two layouts.
        let grouped = false
        for (const g in root.configSchema) {
            if (d[g] !== undefined) { grouped = true; break }
        }
        for (const g in root.configSchema) {
            const bucket = grouped ? d[g] : d
            if (!bucket || typeof bucket !== "object") continue
            for (const n of root.configSchema[g]) {
                const v = bucket[n]
                if (v === undefined || v === null) continue
                opts.dock[n] = v
            }
        }
        if (d.clock) {
            for (const n of root.clockKeys) {
                const v = d.clock[n]
                if (v === undefined || v === null) continue
                opts.dock.clock[n] = v
            }
        }
        if (d.osd) {
            for (const n of root.osdKeys) {
                const v = d.osd[n]
                if (v === undefined || v === null) continue
                opts.dock.osd[n] = v
            }
        }
        const t = json?.theme
        if (t) {
            if (t.accent !== undefined) opts.theme.accent = t.accent
            if (t.dark !== undefined) opts.theme.dark = t.dark
            if (t.animations !== undefined) opts.theme.animations = t.animations
            if (t.effects !== undefined) opts.theme.effects = t.effects
        }
    }


    // NOTE (deferred optimization): _snapshot() serializes the full config
    // tree on every change. The 150ms debounce below prevents excessive disk
    // writes, which is sufficient for the expected config size. A more
    // granular "only serialized changed properties" approach was considered
    // but deferred — revisit only if real UI lag or disk thrash is observed.

    Timer {
        id: fileWriteTimer
        interval: 150
        repeat: false
        onTriggered: {
            if (!root.ready) return
            const json = JSON.stringify(root._snapshot(), null, 4)
            try { cfgFile.setText(json) } catch (e) { /* dir may not exist yet */ }
        }
    }

    FileView {
        id: cfgFile
        path: root.filePath
        watchChanges: true

        onLoaded: {
            try {
                const text = cfgFile.text()
                if (text && text.length > 0) root._hydrate(JSON.parse(text))
            } catch (e) {
                console.warn("[dock Config] failed to parse", root.filePath, e)
            }
            root.ready = true
            // Consumers (Dock.qml clock recreation) rely on this to react to
            // external edits; plain bindings to nested config objects are not
            // reliably re-evaluated on hydrate.
            root.configChanged()
        }
        // Hot-reload external edits to config.json. reload() re-reads the file
        // and fires onLoaded, which hydrates with fresh content.
        onFileChanged: cfgFile.reload()
        onLoadFailed: error => {
            // Missing file on first run is fine — defaults are already applied.
            root.ready = true
            fileWriteTimer.restart()
        }
    }

    // Ensure the config directory exists so persistence writes succeed.
    Process {
        id: mkdirProc
        command: ["/usr/bin/env", "mkdir", "-p", root.configDir]
    }

    Component.onCompleted: mkdirProc.running = true
}
