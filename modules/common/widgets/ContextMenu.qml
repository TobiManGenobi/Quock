pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.services.Desktop
import qs.services.Apps
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

Loader {
    id: root

    property var model: []
    property Item anchorItem: parent
    property real padding: 4
    property bool noSmoothClosing: false
    property bool closeOnFocusLost: true
    property bool closeOnHoverLost: true
    property int closeOnHoverLostDelay: 500  // ms before closing when hover lost (waffle uses 500)
    property bool anchorHovered: false

    property real visualMargin: 8
    property bool popupAbove: true  // true = popup appears above anchor, false = below
    property int popupSide: 0  // For horizontal popup: Edges.Left or Edges.Right, 0 = vertical
    property real ambientShadowWidth: 1
    readonly property bool hasIcons: _menuSnapshot.some(item => item.iconName !== undefined && item.iconName !== "")
    // Surface colours are configurable via config.json (dock.appearance
    // .contextMenuBackgroundColor / .contextMenuBorderColor). An empty value
    // means "use the Appearance token" — the tokens are derived from the
    // accent + light/dark toggle (Appearance.qml:49-52), so hardcoding a hex
    // as the default would freeze the menu to today's dark-mode value and go
    // wrong the moment `theme.dark` flips. This mirrors how Dock.qml reads
    // dock.borderColor / dock.hoverBackgroundColor.
    //
    // FORMAT: `RRGGBB` / `RRGGBBAA`, `#` optional, plus `rgb()`/`rgba()`.
    // The `#` is optional because this config file is not internally
    // consistent — `theme.accent` is written `#RRGGBB` while
    // `dock.appearance.borderColor` is written bare `RRGGBBAA`
    // ("00000000"). Tolerating both is the whole point: a user copying the
    // neighbouring key's style must not silently get a black menu.
    //
    // Why this needs a parser at all: `property color x: "ffffff"` does NOT
    // fall back — QML coerces the invalid string to #000000 and keeps it.
    // Measured on this dock: with config.json holding the bare "ffffff" /
    // "000000", `_configuredBg` correctly read "ffffff" (so hydration and the
    // schema were never at fault) and resolvedBackgroundColor came out
    // #000000 — an opaque black menu that read as "the key does nothing",
    // because #000000 is also what an unconfigured-but-defaulted border looks
    // like on this dark theme. Hence: validate, then coerce.
    readonly property string _configuredBg: Config.options?.dock?.contextMenuBackgroundColor ?? ""
    readonly property string _configuredBorder: Config.options?.dock?.contextMenuBorderColor ?? ""
    readonly property color resolvedBackgroundColor: _parseColor(_configuredBg, Appearance.colors.colSurfaceContainer, "contextMenuBackgroundColor")
    readonly property color resolvedBorderColor: _parseColor(_configuredBorder, Appearance.colors.colSurfaceContainerHighest, "contextMenuBorderColor")

    // Keys already reported as unparseable, so a malformed value warns ONCE
    // per shell rather than on every re-evaluation of the binding.
    property var _warnedColors: []

    // THE accepted format is `RRGGBBAA` with an OPTIONAL leading `#`, in any of
    // the 3/4/6/8-digit hex spellings; `rgb()`/`rgba()` literals are also
    // accepted. That is deliberately NOT Qt's own default reading: Qt.color
    // parses an 8-digit `#RRGGBBAA` as `#AARRGGBB` (alpha FIRST), so the
    // hand-written "ff000080" resolves to #000080 — opaque navy, which is
    // how a correct-looking alpha value turns into a wrong colour with no
    // error at all. This config file already writes
    // `dock.appearance.borderColor` as bare `00000000`, i.e. author-expected
    // RRGGBBAA, so RRGGBBAA is what we accept here and the components are
    // reassembled explicitly instead of being handed to Qt.color whole.
    //
    // Everything else (empty, malformed, a 5- or 7-digit string, a name
    // spelled wrong) returns `fallback`: the function never throws and never
    // returns an invalid colour, so a typo degrades to the theme token
    // instead of blanking or blackening the menu.
    function _parseColor(raw: string, fallback: color, keyName: string): color {
        const text = String(raw ?? "").trim()
        if (text.length === 0) return fallback
        let hex = text
        if (hex[0] === "#") hex = hex.slice(1)

        // rgb(0,255,0) / rgba(0,255,0,0.5) — numeric components, optional
        // alpha 0..1, free whitespace. Validated component-wise so a typo
        // falls through to `fallback` rather than throwing.
        const fn = /^rgba?\s*\(([^)]*)\)$/i.exec(text)
        if (fn) {
            const parts = fn[1].split(",").map(s => s.trim())
            const nums = parts.map(parseFloat)
            const ok = nums.length === (parts.length === 4 ? 4 : 3)
                && parts.length >= 3 && parts.length <= 4
                && nums.every(n => !isNaN(n))
                && nums.slice(0, 3).every(n => n >= 0 && n <= 255)
                && (nums.length < 4 || (nums[3] >= 0 && nums[3] <= 1))
                && parts.every(s => s.length > 0)
            if (ok) {
                const a = nums.length === 4 ? nums[3] : 1
                // NOTE the /255: Qt.rgba() in this Qt build takes components
                // in 0..1 and CLAMPS anything above that. Passing the
                // already-0..255 components directly silently saturates
                // every channel below 255 to full — measured here:
                // Qt.rgba(255,204,0,1) → #ffff00 and Qt.rgba(10,20,30,1) →
                // #ffffff, so a user writing `ffcc00` got pure yellow.
                return Qt.rgba(nums[0] / 255, nums[1] / 255, nums[2] / 255, a)
            }
            return _colorFallback(keyName, text, fallback)
        }

        // Hex. Short forms are expanded first so only 6- and 8-digit values
        // reach the splitter, and both are read as RRGGBB[AA].
        if (/^[0-9a-fA-F]+$/.test(hex)) {
            if (hex.length === 3 || hex.length === 4) {
                hex = hex.split("").map(c => c + c).join("")
            }
            if (hex.length === 6 || hex.length === 8) {
                const r = parseInt(hex.slice(0, 2), 16)
                const g = parseInt(hex.slice(2, 4), 16)
                const b = parseInt(hex.slice(4, 6), 16)
                const a = hex.length === 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1
                // Same /255 normalisation as the rgb() branch above.
                return Qt.rgba(r / 255, g / 255, b / 255, a)
            }
            // 1, 2, 5 or 7 digits: no such hex form, so it cannot be a colour.
            return _colorFallback(keyName, text, fallback)
        }

        return _colorFallback(keyName, text, fallback)
    }

    // Warns ONCE per key per shell (bindings re-evaluate often) and yields
    // the theme token.
    //
    // The warn-once bookkeeping is DEFERRED. `_parseColor` is called from the
    // bindings of `resolvedBackgroundColor` / `resolvedBorderColor`, so
    // reading `_warnedColors` makes those bindings depend on the property —
    // and assigning to it from inside `_colorFallback` closed the loop. A
    // malformed value therefore logged "Binding loop detected for property
    // resolvedBackgroundColor" twice per re-evaluation, drowning the one
    // warning that actually tells the user their value is wrong. Writing from
    // a callLater keeps the read (and the dedupe) but moves the write outside
    // the binding evaluation.
    function _colorFallback(keyName: string, text: string, fallback: color): color {
        if (_warnedColors.indexOf(keyName) === -1) {
            Qt.callLater(() => {
                // Re-check inside the callback: more than one binding can
                // reach this before it runs.
                if (_warnedColors.indexOf(keyName) !== -1) return
                _warnedColors = _warnedColors.concat([keyName])
                console.warn("[ContextMenu] dock.appearance." + keyName
                    + " is not a valid colour (" + JSON.stringify(text)
                    + "); using the theme token instead. Expected #RRGGBB[AA].")
            })
        }
        return fallback
    }

    // ─── Text / separator tint ────────────────────────────────────────────
    // Companion to the card fill for use with a transparent background. Empty
    // = "keep the theme tokens exactly as they are today".
    //
    // WHY these are separate keys rather than a consequence of the card's
    // alpha: the fill and the text are independent surfaces. Fading the text
    // with the fill would make a translucent menu WORSE, not better — the
    // point of a transparent card is that the desktop shows through, and
    // dimming glyphs on top of a busy wallpaper is exactly the unreadable
    // combination. `m3onSurface` is already contrast-checked against the
    // light/dark tokens by Appearance, so it stays the default and the user
    // picks the text colour that reads against THEIR wallpaper. Text also
    // stays fully opaque by default even at alpha 0: a transparent card must
    // not silently produce an invisible menu.
    readonly property string _configuredText: _cfg("contextMenuTextColor")
    readonly property color resolvedTextColor: _parseColor(_configuredText, Appearance.m3colors.m3onSurface, "contextMenuTextColor")
    readonly property string _configuredSeparator: _cfg("contextMenuSeparatorColor")
    readonly property color resolvedSeparatorColor: _parseColor(_configuredSeparator, Appearance.colors.colOutlineVariant, "contextMenuSeparatorColor")

    // ─── Card corner radius ──────────────────────────────────────────────
    // Configurable via `dock.appearance.contextMenuBorderRadius`.
    //
    // SHAPE: the four corner radii are resolved ONCE here and bound to BOTH
    // the painted card and the blur `Region`, mirroring
    // modules/dock/Dock.qml, where `dockVisualBackground`'s four
    // topLeftRadius/topRightRadius/bottomLeftRadius/bottomRightRadius and
    // the `Region`'s four corner radii are the same `rTL`/`rTR`/`rBR`/`rBL`
    // values. That shared source is what keeps the blurred backdrop and the
    // painted card in agreement at the corners — the dock's own comment
    // (Dock.qml:1316-1321) calls this out as the reason there is "by
    // construction … no geometry gap". A radius set in only one of the two
    // places is exactly how a square blurred halo appears around round
    // corners.
    //
    // ONE key, four identical corners: unlike the dock's
    // borderRadius{TopLeft,TopRight,…} variants, a floating popup has no
    // screen-edge-facing corner (no `concaveEdgeCorners`), so it never draws
    // an asymmetric outline and per-corner keys would be dead weight. The
    // four properties still exist, because that is the shape the consumer
    // API (Region) wants.
    //
    // DEFAULT: Config.qml declares -1 = "not configured"; the fallback is
    // resolved HERE, exactly like Dock.qml's `_cornerRadius()` falls through
    // to `Appearance.rounding.normal`, rather than baked into the config
    // default. With the key absent this is `Appearance.rounding.normal` = 12,
    // which is what was hardcoded on the card before this key existed, so the
    // menu is pixel-identical to today until the user sets something.
    //
    // Coerced through Number() because _hydrate() copies the raw JSON value
    // straight across: a config file writing `"contextMenuBorderRadius": "16"`
    // as a string must still compare >= 0 and be rounded, not silently
    // become NaN (which Qt draws as "no rounding" and which would desync the
    // card from the region).
    readonly property var _cfgAppearance: Config.options?.dock
    readonly property real _configuredRadius: Number(_cfgAppearance?.contextMenuBorderRadius)
    readonly property bool _radiusConfigured: _cfgAppearance?.contextMenuBorderRadius !== undefined
        && _cfgAppearance?.contextMenuBorderRadius !== null
        && _configuredRadius >= 0 && !isNaN(_configuredRadius)
    readonly property real _uniformRadius: _radiusConfigured ? _configuredRadius : Appearance.rounding.normal

    readonly property real rTL: _uniformRadius
    readonly property real rTR: _uniformRadius
    readonly property real rBR: _uniformRadius
    readonly property real rBL: _uniformRadius

    // `Region`'s corner radii are `int`-typed (quickshell-core.qmltypes,
    // PendingRegion: `Property { name: "topLeftRadius"; type: "int"; … }`),
    // while the card's `radius` is `real`. Rounding here means a fractional
    // config value cannot leave the blurred backdrop half a pixel proud of
    // the card outline.
    readonly property int riTL: Math.max(0, Math.round(rTL))
    readonly property int riTR: Math.max(0, Math.round(rTR))
    readonly property int riBR: Math.max(0, Math.round(rBR))
    readonly property int riBL: Math.max(0, Math.round(rBL))
    // ─── Row / text sizing (configurable) ────────────────────────────────
    // Same contract as the radius keys above: -1 = "not configured", the
    // Appearance token is resolved HERE rather than baked into Config.qml,
    // so an absent key leaves the menu exactly as it is today.
    readonly property real _configuredItemHeight: Number(_cfgAppearance?.contextMenuItemHeight)
    readonly property real resolvedItemHeight: !isNaN(_configuredItemHeight) && _configuredItemHeight > 0
        ? _configuredItemHeight : 32

    readonly property real _configuredItemRadius: Number(_cfgAppearance?.contextMenuItemRadius)
    readonly property real resolvedItemRadius: !isNaN(_configuredItemRadius) && _configuredItemRadius >= 0
        ? _configuredItemRadius : Appearance.rounding.small

    readonly property real _configuredTextSize: Number(_cfgAppearance?.contextMenuTextSize)
    readonly property real resolvedTextSize: !isNaN(_configuredTextSize) && _configuredTextSize > 0
        ? _configuredTextSize : Appearance.font.pixelSize.small

    readonly property real _configuredIconSize: Number(_cfgAppearance?.contextMenuIconSize)
    readonly property real resolvedIconSize: !isNaN(_configuredIconSize) && _configuredIconSize > 0
        ? _configuredIconSize : Appearance.font.pixelSize.normal

    readonly property real _configuredMinWidth: Number(_cfgAppearance?.contextMenuMinWidth)
    readonly property real resolvedMinWidth: !isNaN(_configuredMinWidth) && _configuredMinWidth > 0
        ? _configuredMinWidth : 140

    readonly property real _configuredBorderWidth: Number(_cfgAppearance?.contextMenuBorderWidth)
    readonly property real resolvedBorderWidth: !isNaN(_configuredBorderWidth) && _configuredBorderWidth >= 0
        ? _configuredBorderWidth : 1

    // Row hover / ripple tint. Defaults reproduce the previous literals
    // (colPrimary at 85% / 70% transparency) so an absent key is a no-op.
    readonly property string _configuredHover: _cfg("contextMenuItemHoverColor")
    readonly property color resolvedItemHoverColor: _parseColor(_configuredHover,
        ColorUtils.transparentize(Appearance.colors.colPrimary, 0.85), "contextMenuItemHoverColor")
    readonly property string _configuredRipple: _cfg("contextMenuItemRippleColor")
    readonly property color resolvedItemRippleColor: _parseColor(_configuredRipple,
        ColorUtils.transparentize(Appearance.colors.colPrimary, 0.7), "contextMenuItemRippleColor")


    // The blur is requested from the CLIENT, on the PopupWindow, as a
    // `BackgroundEffect.blurRegion` — see the block next to the `anchor`
    // property below for the niri source evidence and the measured
    // `wl_region.add` values. Do NOT replace it with the assumption that
    // `~/.config/niri/config.kdl`'s `window-rule { popups { background-effect
    // { blur true } } }` already blurs this menu: that rule does not reach
    // this popup, because window rules are not applied to layer-shell
    // surfaces and the dock is one.

    // Single funnel for reading a `dock.*` string option. Exists so the
    // optional-chained access lives in exactly one place: `Config.options` is
    // a plain QtObject tree, so `?.dock?.<key> ?? ""` written out per property
    // repeats that chain (and the lint warning it raises) for every knob.
    // STRING-ONLY FUNNEL. Do not use it for a `bool`, `int` or `real` option:
    // the `: string` return type coerces the value, so comparing the result
    // with `===` against a non-string literal silently never matches
    // (`true === "true"` is false), and comparing it numerically yields NaN.
    // Such options must be read straight off `Config.options?.dock?.<key>`.
    // It IS correct for `property string` and `property var` options.
    function _cfg(key: string): string {
        return Config.options?.dock?.[key] ?? ""
    }


    // True for a `file://…/foo.svg` / `.svgz` URL. Kept as its own helper so
    // both the URL mapping and the rasteriser agree on what "an SVG" means —
    // they previously disagreed, which is how an unrasterised SVG reached
    // IconImage.
    function _isSvgIconUrl(u: string): bool {
        return typeof u === "string" && /\.svgz?$/i.test(u)
    }

    // PURE: maps a model's `iconName` to the URL the menu should resolve.
    // Must not mutate anything — it runs inside a binding (see the icon
    // Loader), so calling the state-mutating `IconThemeService.rasterOrBlank`
    // here is what produced "Binding loop detected for property source".
    function _iconUrlFor(n: string): string {
        if (!n) return ""
        // Absolute paths and file:// URLs skip iconPath(), which would fail on
        // a "file://…" string and log "Could not load icon".
        //
        // That bypass must NOT extend to SVG. Qt's SVG image handler cannot
        // resolve constructs like `bx:shape` / `gradientTransform` in themed
        // icon sets (Colloid), so a raw "file://…/foot.svg" reaching
        // IconImage logs, once per row per menu open:
        //   qt.svg: …/foot.svg:32:6: Could not resolve property:
        // Callers such as DockAppButton feed the menu `root._resolvedIconSource`,
        // which IS such an SVG URL — so the extension has to be checked here,
        // at the single point every menu icon passes through. Do not
        // "simplify" this back into a bare startsWith("/") early return.
        if (n.startsWith("/") || n.startsWith("file://"))
            return _isSvgIconUrl(n) ? n : (n.startsWith("file://") ? n : `file://${n}`)
        // Theme name: resolveIconUrl() prefers a real file from the icon
        // index; the SVG rasterisation happens in the Loader.
        return IconThemeService.resolveIconUrl(n)
    }
    function close(): void {
        // Nothing to animate when the popup does not exist yet — close() is
        // also called from closeAllContextMenus() on menus that never opened.
        if (item) item.close();
        else active = false;
    }
    // ─── Open/close bookkeeping ───────────────────────────────────────────
    // Generation counter that invalidates an in-flight close animation.
    // closeAnim only flips `active` back to false at the very END of the
    // animation (see ScriptAction below). Without a token, re-opening the
    // menu while that animation is still playing leaves `active` stuck at
    // true — the caller sets active = true, which is a no-op, so no popup is
    // created — and then the stale animation finishes and closes the menu
    // the user just re-opened. Bumping the token on every open/close makes
    // the trailing ScriptAction conditional, so only the animation that is
    // still current may actually close.
    property int _closeToken: 0

    // Snapshot of `model` taken at open time. The rows render from this copy
    // instead of the live array: a menu rebuilt while it is open (a window
    // opening/closing regenerates the dock's menuModel) used to destroy and
    // recreate the Repeater delegates under the pointer, which swallowed the
    // click the user was making.
    property var _menuSnapshot: []

    // Opens the menu. Kept alongside the `active` property so existing
    // consumers that assign `active = true` directly keep working; callers
    // that can hit the close animation (the dock does) call this instead.
    function open(): void {
        _closeToken++
        _menuSnapshot = Array.isArray(model) ? model.slice() : (model ?? [])
        active = true
        // The popup item only exists once the Loader has instantiated the
        // source component, so the open animation is (re)started from
        // onActiveChanged below rather than here.
    }

    onActiveChanged: {
        if (!active) return
        _menuSnapshot = Array.isArray(model) ? model.slice() : (model ?? [])
        // Re-opened while a close animation was still running: the popup is
        // still alive, so nothing instantiates and nothing would animate.
        // Cancel the pending close and play the open animation instead.
        if (item) {
            _closeToken++
            item.replayOpenAnimation()
            // Re-anchor through PopupAnchor, the only object here that
            // exposes a method for it. `reposition()` is NOT callable from
            // QML: quickshell-window.qmltypes lists
            // `Method { name: "reposition" }` for the ProxyPopupWindow
            // component, but the engine does not expose it — verified at
            // runtime, `typeof popupWindow.reposition === "undefined"`,
            // which is what threw the TypeError on every menu open.
            // PopupAnchor's `Method { name: "updateAnchor" }` IS callable
            // (same qmltypes component; `typeof anchor.updateAnchor ===
            // "function"`), so use the same helper the 32 ms timer uses.
            updateAnchor()
        }
    }

    // Re-anchors the popup to `anchorItem`. This is driven by the
    // `anchor { item: … }` binding on the popup plus PopupAnchor's own
    // `updateAnchor()`; there is no separate "reposition the window" call.
    function updateAnchor(): void {
        item?.anchor.updateAnchor();
    }


    active: false
    visible: active

    sourceComponent: PopupWindow {
        id: popupWindow
        visible: true

        Component.onCompleted: {
            openAnim.start();
            Qt.callLater(() => keyHandler.forceActiveFocus());
        }

        Item {
            id: keyHandler
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    root.close();
                    event.accepted = true;
                }
            }
        }

        anchor {
            adjustment: (root.popupSide !== 0) 
                ? (PopupAdjustment.ResizeX | PopupAdjustment.SlideY)
                : (PopupAdjustment.ResizeY | PopupAdjustment.SlideX)
            item: root.anchorItem
            gravity: root.popupSide !== 0 
                ? root.popupSide 
                : (root.popupAbove ? Edges.Top : Edges.Bottom)
            edges: root.popupSide !== 0 
                ? root.popupSide 
                : (root.popupAbove ? Edges.Top : Edges.Bottom)
        }

        // Typed handle on the card, for the blur region below. `realContent`
        // is an `id`; going through a declared property keeps the lookup
        // qualified. The blur Region takes its GEOMETRY from this item's
        // x/y/width/height, but spells them out explicitly rather than using
        // `item:` — the same shape modules/dock/Dock.qml:1407-1482 uses,
        // together with the four explicit corner radii. The card and the
        // region therefore read from one set of values (`rTL`/`rTR`/`rBR`/
        // `rBL`), which is what makes the blurred backdrop line up with the
        // painted card at every corner instead of leaving a square halo.
        readonly property Item cardItem: realContent

        // ─── Client blur region ───────────────────────────────────────────
        // THIS is what actually makes the menu blurred. The comment block
        // above it used to claim the compositor already did it; it did not,
        // and that false claim is why the menu stayed sharp for three
        // rounds of bug reports. Evidence, in niri's own source:
        //
        //  - Popup rules live on the LAYER surface's ResolvedLayerRules
        //    (niri/src/layer/mapped.rs `for_each_popup`: `PopupKind::Xdg(_)
        //    => self.rules.popups`). The `popups { … }` block in
        //    ~/.config/niri/config.kdl sits inside a `window-rule`, and
        //    window rules are not consulted for layer-shell surfaces — the
        //    dock is a layer surface (namespace "quickshell:dock"). So
        //    `self.rules.popups` stays `ResolvedPopupsRules::default()`
        //    (niri-config/src/window_rule.rs, `#[derive(Default)]`), whose
        //    `background_effect.blur` is `None`.
        //  - background_effect.rs:118-122 then evaluates
        //        let blur = if has_blur_region { effect.blur != Some(false) }
        //                   else                 { effect.blur == Some(true) };
        //    With no region and blur == None the else-branch is FALSE: niri
        //    renders no background effect at all for this popup.
        //
        // Committing a NON-EMPTY region flips the branch to
        // `None != Some(false)` → true, which is why this works without
        // touching the compositor config.
        //
        // Coordinate space: SURFACE-LOCAL. Verified on the wire, not
        // assumed — a probe PopupWindow 500x360 logical with a Region
        // mirroring an item at x=40,y=30,w=420,h=300 emitted exactly
        //   wl_region#56.add(40, 30, 420, 300)
        //   ext_background_effect_surface_v1#50.set_blur_region(wl_region#56)
        // i.e. item geometry in popup-surface pixels, with no transform.
        //
        // Explicit x/y/width/height and all FOUR corner radii, mirroring
        // modules/dock/Dock.qml:1407-1482, which is the arrangement that is
        // known to work in this codebase for a blurred + rounded surface. The
        // dock spells the corners out individually for the same reason this
        // does: `Region` and the painted card must be bound to the SAME
        // values, or the blurred backdrop keeps its own shape.
        //
        // The geometry still tracks the card through the open/close
        // `sourceEdgeMargin` animation and the 32 ms re-anchoring, because it
        // is bound to the card item's own x/y/width/height — only the
        // transport changed, not what is tracked.
        //
        // `Math.max(1, …)` on width/height is the dock's guard against a
        // degenerate (zero-extent) QRegion before the first polish, kept
        // because an empty region is what makes niri drop the effect entirely
        // (background_effect.rs: `if (region.isEmpty()) set_blur_region(nullptr)`).
        //
        // Attached to the CARD, not the whole popup surface, so the ambient
        // shadow margin outside the card stays unblurred.
        BackgroundEffect.blurRegion: Region {
            x: Math.round(popupWindow.cardItem.x)
            y: Math.round(popupWindow.cardItem.y)
            width: Math.max(1, Math.round(popupWindow.cardItem.width))
            height: Math.max(1, Math.round(popupWindow.cardItem.height))
            topLeftRadius: root.riTL
            topRightRadius: root.riTR
            bottomRightRadius: root.riBR
            bottomLeftRadius: root.riBL
        }

        // Hover-lost. The timer used to start the instant the popup opened,
        // because nothing distinguished "the pointer is on its way from the
        // icon to the menu" from "the pointer has left the menu for good".
        // Over a 500 ms delay and the gap between icon and popup that is easy
        // to lose, so the menu closed before the pointer arrived — and a
        // keyboard-opened menu (pointer not on the icon at all) closed
        // unconditionally 500 ms after opening. The first wait is therefore
        // longer; once the pointer has actually been on the icon or in the
        // menu, the shared closeOnHoverLostDelay applies exactly as before.
        Timer {
            id: hoverLostTimer
            interval: hoverSeen
                ? root.closeOnHoverLostDelay
                : root.closeOnHoverLostDelay * 3
            running: root.closeOnHoverLost && popupWindow.visible && !popupWindow.popupContainsMouse && !root.anchorHovered
            onTriggered: root.close()
        }

        // The pointer was on the icon or in the popup at least once; flips
        // hover-lost over to the short shared delay.
        property bool hoverSeen: false
        onPopupContainsMouseChanged: if (popupContainsMouse) hoverSeen = true
        Connections {
            target: root
            function onAnchorHoveredChanged() {
                if (root.anchorHovered) popupWindow.hoverSeen = true
            }
        }

        // Token of the close animation currently running (0 = none).
        property int _startToken: 0

        // Replays the open animation when the popup is reused without being
        // destroyed (menu re-opened mid close-animation).
        function replayOpenAnimation(): void {
            hoverSeen = false
            closeAnim.stop()
            openAnim.stop()
            openAnim.start()
        }

        function close(): void {
            // Stamp the token only when there is really something to close;
            // closeAllContextMenus() reaches every delegate, open or not.
            if (root.active) {
                root._closeToken++
                _startToken = root._closeToken
            }
            hoverLostTimer.stop()
            if (root.noSmoothClosing) root.active = false;
            else closeAnim.start();
        }

        implicitWidth: realContent.implicitWidth + (root.ambientShadowWidth * 2) + (root.visualMargin * 2)
        implicitHeight: realContent.implicitHeight + (root.ambientShadowWidth * 2) + (root.visualMargin * 2)

        property real sourceEdgeMargin: -implicitHeight
        readonly property bool isHorizontalPopup: root.popupSide !== 0
        readonly property bool isLeftSide: root.popupSide === Edges.Left
        
        PropertyAnimation {
            id: openAnim
            target: popupWindow
            property: "sourceEdgeMargin"
            to: (root.ambientShadowWidth + root.visualMargin)
            duration: Appearance.animation.elementMoveFast.duration
            easing.type: Appearance.animation.elementMoveFast.type
        }
        SequentialAnimation {
            id: closeAnim
            PropertyAnimation {
                target: popupWindow
                property: "sourceEdgeMargin"
                to: popupWindow.isHorizontalPopup ? -popupWindow.implicitWidth : -popupWindow.implicitHeight
                duration: Appearance.animation.elementMoveExit.duration
                easing.type: Appearance.animation.elementMoveExit.type
            }
            ScriptAction {
                // Only tear the menu down if this animation is still the
                // current close: a re-open during the animation bumps
                // _closeToken, and without this guard the stale ScriptAction
                // closes the menu that was just re-opened.
                script: if (root._closeToken === popupWindow._startToken) root.active = false
            }
        }

        // Keeps the popup glued to the anchor item while it is open. The
        // anchor block is a binding on `item`, but the dock applies a
        // per-frame bounce/magnify transform to every icon, so the item's
        // rect moves every frame and the popup used to lag behind (or detach
        // from) the bouncing icon. ~30 Hz is plenty for a menu and only runs
        // while exactly one menu is open.
        Timer {
            interval: 32
            running: root.active
            repeat: true
            onTriggered: root.updateAnchor()
        }

        color: "transparent"

        // Opacity-tracked to the card fill's alpha. The fill can now be made
        // genuinely transparent (`contextMenuBackgroundColor` as RRGGBBAA —
        // the alpha channel already flowed through _parseColor → Qt.rgba →
        // GlassBackground.fallbackColor, verified by pixel measurement), and
        // a dark blurred rect drawn *behind* an invisible card is not a
        // shadow any more: it is a solid black slab with a soft edge, which is
        // exactly what a fully transparent menu used to look like.
        //
        // Scaling proportionally (rather than a boolean cut-off) keeps this a
        // pure no-op at the default — the token colours are opaque, so alpha is
        // 1 and the shadow renders exactly as it did before. It also means a
        // half-transparent card gets a correspondingly half-transparent
        // shadow instead of snapping to on/off, and no colour, blur, spread or
        // radius value is touched — only the composite opacity of the effect.
        StyledRectangularShadow {
            target: realContent
            opacity: root.resolvedBackgroundColor.a
        }

        GlassBackground {
            id: realContent
            z: 1
            anchors {
                // Vertical popup (above/below)
                left: !popupWindow.isHorizontalPopup ? parent.left : (popupWindow.isLeftSide ? undefined : parent.left)
                right: !popupWindow.isHorizontalPopup ? parent.right : (popupWindow.isLeftSide ? parent.right : undefined)
                top: !popupWindow.isHorizontalPopup ? (root.popupAbove ? undefined : parent.top) : parent.top
                bottom: !popupWindow.isHorizontalPopup ? (root.popupAbove ? parent.bottom : undefined) : parent.bottom
                
                margins: root.ambientShadowWidth + root.visualMargin
                bottomMargin: !popupWindow.isHorizontalPopup && root.popupAbove ? popupWindow.sourceEdgeMargin : (root.ambientShadowWidth + root.visualMargin)
                topMargin: !popupWindow.isHorizontalPopup && !root.popupAbove ? popupWindow.sourceEdgeMargin : (root.ambientShadowWidth + root.visualMargin)
                leftMargin: popupWindow.isHorizontalPopup && !popupWindow.isLeftSide ? popupWindow.sourceEdgeMargin : (root.ambientShadowWidth + root.visualMargin)
                rightMargin: popupWindow.isHorizontalPopup && popupWindow.isLeftSide ? popupWindow.sourceEdgeMargin : (root.ambientShadowWidth + root.visualMargin)
            }
            fallbackColor: root.resolvedBackgroundColor
            // Was hardcoded to `Appearance.rounding.normal`. Now resolved from
            // `dock.appearance.contextMenuBorderRadius`, with that same token
            // as the fallback — so with the key absent this line evaluates to
            // exactly what it evaluated to before and the menu is unchanged
            // until the user sets a value.
            //
            // The value is SHARED with the blur Region above (same `rTL`), so
            // the painted card and the blurred backdrop it sits on can never
            // disagree about the corner shape. GlassBackground is a Rectangle,
            // so it exposes one `radius`; `rTL` is the uniform value all four
            // corners resolve to.
            radius: root.rTL
            border.width: root.resolvedBorderWidth
            border.color: root.resolvedBorderColor
            // Card fill + border only. The compositor backdrop blur is NOT
            // declared here: it lives on the PopupWindow as
            // `BackgroundEffect.blurRegion` (see above), because that is the
            // surface the effect is rendered for. Nothing here is gated
            // behind an opt-in — the blur is unconditional.
            implicitWidth: menuColumn.implicitWidth + (root.padding * 2)
            implicitHeight: menuColumn.implicitHeight + (root.padding * 2)

            ColumnLayout {
                id: menuColumn
                anchors.centerIn: parent
                spacing: 0

                Repeater {
                    // Snapshot taken at open time, not the live model: a menu
                    // model rebuilt while the popup is open would otherwise
                    // destroy the row under the pointer mid-interaction and
                    // swallow the click.
                    model: root._menuSnapshot
                    delegate: DelegateChooser {
                        role: "type"
                        DelegateChoice {
                            roleValue: undefined
                            RippleButton {
                                id: menuBtn
                                Layout.fillWidth: true

                                required property var modelData
                                enabled: modelData.enabled !== false
                                opacity: enabled ? 1 : 0.45

                                implicitWidth: Math.max(root.resolvedMinWidth, menuRow.implicitWidth + 20)
                                implicitHeight: root.resolvedItemHeight
                                buttonRadius: root.resolvedItemRadius
                                colBackground: "transparent"
                                colBackgroundHover: root.resolvedItemHoverColor
                                colRipple: root.resolvedItemRippleColor

                                onClicked: {
                                    if (!enabled) return;
                                    if (modelData.action) modelData.action();
                                    root.close();
                                }

                                contentItem: RowLayout {
                                    id: menuRow
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    spacing: 8

                                    Loader {
                                        id: iconLoader
                                        active: root.hasIcons
                                        visible: active
                                        Layout.alignment: Qt.AlignVCenter

                                        // ── Icon resolution: two steps, on purpose ────────
                                        // `rawIconUrl` is a PURE binding — it only maps the
                                        // model's `iconName` onto a URL and calls nothing
                                        // that mutates state.
                                        //
                                        // The rasterisation itself runs imperatively in
                                        // `_resolveIcon()`, because
                                        // `IconThemeService.rasterOrBlank()` writes
                                        // `_rasterPending` / `_rasterIndex` as a side
                                        // effect. Calling it from inside `source:` therefore
                                        // mutates properties that the very same binding
                                        // reads, which Qt reports as
                                        //   IconImage.qml[59:2]: Binding loop detected for
                                        //   property "source"
                                        // (reproduced in isolation; it also fires on the
                                        // pre-existing theme-name path). The defect is in
                                        // the service's API contract, but the call site is
                                        // here, so the call site is what must change.
                                        readonly property string rawIconUrl: root._iconUrlFor(menuBtn.modelData.iconName ?? "")

                                        // What IconImage actually loads. Starts EMPTY on
                                        // purpose: seeding it with `rawIconUrl` would let the
                                        // raw SVG reach IconImage for one frame, and a
                                        // single frame of `Image.source = <svg>` is enough
                                        // for Qt's SVG handler to log its parse warnings
                                        // (measured: 96 of them for an 8-row menu). So an
                                        // SVG is simply not shown until its PNG exists.
                                        property string resolvedIconUrl: ""

                                        // Bounded, so a missing or failing `rsvg-convert`
                                        // cannot leave an icon retrying forever.
                                        property int _rasterAttempts: 0
                                        readonly property int _maxRasterAttempts: 40

                                        function _resolveIcon(): void {
                                            const u = rawIconUrl
                                            // Not an SVG: nothing to rasterise.
                                            if (!root._isSvgIconUrl(u)) {
                                                resolvedIconUrl = u
                                                return
                                            }
                                            // "" means the PNG is not on disk yet; the
                                            // service converts asynchronously with
                                            // rsvg-convert, so poll for it rather than
                                            // showing the raw SVG straight away — showing it
                                            // is exactly what logs the parse warnings.
                                            const png = IconThemeService.rasterOrBlank(u, 128)
                                            if (png !== "") {
                                                resolvedIconUrl = png
                                                return
                                            }
                                            if (_rasterAttempts < _maxRasterAttempts) {
                                                rasterRetry.restart()
                                                return
                                            }
                                            // Out of attempts (no rsvg-convert, or the
                                            // conversion keeps failing). Showing the raw SVG
                                            // now brings the warnings back, but a
                                            // permanently blank icon is a worse failure for
                                            // the user than a noisy log. Not reached in
                                            // practice: IconThemeService pre-populates its
                                            // PNG cache, so the common case is a cache hit on
                                            // the very first call.
                                            resolvedIconUrl = u
                                            if (png === "" && _rasterAttempts < _maxRasterAttempts)
                                                rasterRetry.restart()
                                        }

                                        onRawIconUrlChanged: {
                                            _rasterAttempts = 0
                                            _resolveIcon()
                                        }
                                        Component.onCompleted: _resolveIcon()

                                        Timer {
                                            id: rasterRetry
                                            interval: 120
                                            onTriggered: {
                                                parent._rasterAttempts++
                                                parent._resolveIcon()
                                            }
                                        }

                                        sourceComponent: menuBtn.modelData.monochromeIcon === true ? materialIconComp : iconImageComp

                                        Component {
                                            id: materialIconComp
                                            MaterialSymbol {
                                                text: menuBtn.modelData.iconName ?? ""
                                                iconSize: root.resolvedIconSize
                                                color: root.resolvedTextColor
                                            }
                                        }

                                        Component {
                                            id: iconImageComp
                                            IconImage {
                                                source: iconLoader.resolvedIconUrl
                                                implicitSize: Appearance.font.pixelSize.normal
                                            }
                                        }
                                    }

                                    StyledText {
                                        text: menuBtn.modelData.text ?? ""
                                        color: root.resolvedTextColor
                                        font.pixelSize: root.resolvedTextSize
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        HoverHandler {
            id: popupHoverHandler
        }
        readonly property bool popupContainsMouse: popupHoverHandler.hovered

        PanelWindow {
            visible: popupWindow.visible && CompositorService.isNiri && root.closeOnFocusLost
            color: "transparent"
            exclusiveZone: 0
            // MUST stay below the popup. The popup is a layer-shell surface on
            // WlrLayer.Top; this backdrop was also on Top, and because it is
            // created *after* the popup (it is a child of it) the compositor
            // stacks it on top of it. The transparent full-screen window then
            // swallowed every hover and click aimed at the menu: rows could
            // not be hovered, `popupContainsMouse` never became true, and the
            // hover-lost timer closed the menu out from under the pointer
            // ~500 ms after it opened — the single most "buggy" symptom there
            // was. Bottom still covers the whole screen for click-to-dismiss.
            WlrLayershell.layer: WlrLayer.Bottom
            // Deliberately NOT "quickshell"-prefixed. niri's unanchored rule
            // `layer-rule { match namespace="quickshell"; background-effect {
            // blur true; xray false } }` matches on substring, and niri's
            // non-xray blur is gated only on `options.blur` — there is no
            // alpha/transparency check — so a full-screen *transparent*
            // backdrop still gets blurred, softening the entire desktop
            // whenever any context menu is open. This namespace matches
            // nothing in config.kdl, so the backdrop stays purely a
            // click-to-dismiss surface with no compositor effect.
            WlrLayershell.namespace: "qsDockContextMenuBackdrop"

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            MouseArea {
                anchors.fill: parent
                onClicked: {
                    root.close();
                }
            }
        }
    }
}
