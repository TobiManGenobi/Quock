import qs.services.Desktop
import qs.services.Apps
import qs.services.Common
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import QtQuick
import QtQuick.Layouts

DockButton {
    id: root
    property var appToplevel
    property var appListRoot
    property int listIndex: -1       // set by the DockApps delegate (required property int index)
    property int lastFocused: -1
    property real iconSize: Config.options?.dock?.iconSize ?? 35
    property real countDotWidth: Config.options?.dock?.indicatorWidth ?? 10
    property real countDotHeight: Config.options?.dock?.indicatorHeight ?? 4
    // Toplevels come from the dock-wide reactive map so window-list
    // updates (focus reorder, new/closed windows of an existing app)
    // refresh without forcing a ScriptModel rebuild and spurious
    // ListView add/remove/move animations. Fallback to modelData for
    // the brief window before the map is populated.
    readonly property var toplevels: (appListRoot?.toplevelsByUniqueId?.[appToplevel?.uniqueId] ?? appToplevel?.toplevels ?? [])
    readonly property string activeWindowKey: CompositorService.activeToplevelKey
    function _toplevelKey(toplevel) {
        if (!toplevel)
            return ""
        // Enriched snapshots store the live QObject's pointer string as _sourceKey.
        // Use it directly — don't recompute from stale title/appId, which would
        // break when the window title changes (e.g. nautilus "Loading…" → "Home").
        if (toplevel._sourceKey !== undefined && toplevel._sourceKey !== null && toplevel._sourceKey !== "")
            return String(toplevel._sourceKey)
        return ""
    }
    property bool appIsActive: {
        if (!CompositorService.hasActiveActivatedToplevel) return false
        const activeKey = CompositorService.activeToplevelKey
        if (activeKey.length === 0) return false
        for (let i = 0; i < toplevels.length; i++) {
            const toplevel = toplevels[i]
            if (!toplevel)
                continue
            if (_toplevelKey(toplevel) === activeKey)
                return true
        }
        return false
    }
    property bool hasWindows: toplevels.length > 0

    // ─── Launch bounce (mock port) ─────────────────────────────────────
    // The mock never lets the bounce write the icon's magnification scale. It
    // owns a cross-axis offset plus a scale *addend* (a ratio of |offset| to the
    // arc peak) that gets multiplied into whatever scale the magnify frame loop
    // computed this frame. Same split here, so the two compose.
    property real _bounceOffset: 0
    // |offset| at the apex of the arc the currently running leg belongs to.
    property real _bounceArcPeak: 0
    readonly property real _bounceScaleDelta: root._bounceArcPeak !== 0
        ? 0.14 * Math.abs(root._bounceOffset / root._bounceArcPeak)
        : 0

    readonly property real _bounceTarget: Math.max(0, Config.options?.dock?.bounceDistance ?? 14)
    readonly property string _bounceStyle: Config.options?.dock?.bounceStyle ?? "doubleHop"
    readonly property int _bounceDurationMs: Config.options?.dock?.bounceDurationMs ?? 600

    // kBounceAmplitudeRatio: the arc amplitude is a fraction of iconSize so
    // the bounce reads the same at any icon size.
    //
    // This is ALWAYS POSITIVE on purpose. `_bounceOffset` is a *magnitude*;
    // the direction lives in exactly one place — the Translate at the bottom
    // of this file, which already points the offset at the screen interior
    // (bottom dock -> -y/up, top -> +y/down, left -> +x/right, right ->
    // -x/left). Folding a second, opposite sign into the peak cancelled that
    // one and sent the icon straight out through the dock's own screen edge:
    // for a bottom dock the peak was negative, so `-_bounceOffset` was
    // positive and the icon bounced DOWN, off the bottom of the screen. Keeping
    // the amplitude unsigned means a new edge only ever has to be handled in
    // the Translate, and `_bounceScaleDelta` (which takes Math.abs) keeps
    // reading the apex correctly.
    readonly property real _bouncePeak: root.iconSize * 0.34

    property var _bounceLegs: []
    property var _bounceAnim: null
    property int _bounceLegIndex: 0

    // Mock: buildDockBounceLegs. Every arc is a rise leg 0 -> peak over 40% of
    // the arc (EaseOutQuad — the rise is quicker than the gravity fall) plus a
    // fall leg peak -> 0 over the remaining 60% with the style's easing.
    function _buildBounceLegs(style, totalMs, peak): var {
        const legs = []
        const appendArc = (arcPeak, arcMs, fallEase) => {
            const riseMs = arcMs * 0.4
            const fallMs = arcMs - riseMs
            if (arcPeak === 0 || riseMs <= 0 || fallMs <= 0) return
            legs.push({ from: 0, to: arcPeak, dur: riseMs, ease: Easing.OutQuad, peak: arcPeak })
            legs.push({ from: arcPeak, to: 0, dur: fallMs, ease: fallEase, peak: arcPeak })
        }
        if (style === "overshoot") {
            // One arc; EaseOutBack on the fall carries the icon slightly past
            // rest before it settles.
            appendArc(peak, totalMs, Easing.OutBack)
        } else {
            // doubleHop: a fast, tall first hop then a short, drawn-out settle.
            // The two arcs still sum to the configured total duration.
            appendArc(peak, totalMs * 0.4, Easing.InQuad)
            appendArc(peak * 0.45, totalMs * 0.6, Easing.InQuad)
        }
        return legs
    }

    function _runBounceLeg(legIndex: int): void {
        if (root._bounceAnim) {
            root._bounceAnim.destroy()
            root._bounceAnim = null
        }
        if (legIndex >= root._bounceLegs.length) {
            // The last leg ends on exactly 0. Reset anyway so a completed,
            // cancelled or rebuilt item is always at rest.
            root._bounceOffset = 0
            root._bounceArcPeak = 0
            return
        }
        const leg = root._bounceLegs[legIndex]
        root._bounceLegIndex = legIndex
        root._bounceArcPeak = Math.abs(leg.peak)
        root._bounceOffset = leg.from
        const anim = bounceLegComponent.createObject(root, {
            from: leg.from,
            to: leg.to,
            duration: leg.dur
        })
        // Qt's OutBack is the standard c1 = 1.70158 curve the mock uses.
        anim.easing.type = leg.ease
        root._bounceAnim = anim
        anim.start()
    }

    function bounce(): void {
        if (root.isSeparator) return
        if (Config.options?.dock?.bounceOnClick === false) return
        if (root._bounceTarget <= 0) return
        if (Config.options?.dock?.bounceOnLaunch === false) return
        if (root._bounceStyle === "none") return
        // A non-positive duration disables the bounce; the clamp matches the
        // config schema band and keeps a bogus value from looping forever.
        if (root._bounceDurationMs <= 0) return
        root.stopBounce()
        const totalMs = Math.max(100, Math.min(3000, root._bounceDurationMs))
        root._bounceLegs = root._buildBounceLegs(root._bounceStyle, totalMs, root._bouncePeak)
        if (root._bounceLegs.length === 0) return
        root._runBounceLeg(0)
        bounceTimeout.restart()
    }

    function stopBounce(): void {
        if (root._bounceAnim) {
            root._bounceAnim.destroy()
            root._bounceAnim = null
        }
        root._bounceLegs = []
        root._bounceOffset = 0
        root._bounceArcPeak = 0
        bounceTimeout.stop()
    }

    // One leg of one bounce arc. Chained through _runBounceLeg so the next leg
    // starts only after this one has dropped its finished entry.
    Component {
        id: bounceLegComponent
        NumberAnimation {
            target: root
            property: "_bounceOffset"
            onFinished: root._runBounceLeg(root._bounceLegIndex + 1)
        }
    }

    // Safety: stop if the app never opens a window (e.g. launch failed).
    Timer {
        id: bounceTimeout
        interval: 15000
        onTriggered: root.stopBounce()
    }

    // ─── Pending launch focus (mock port) ─────────────────────────────
    // Mock: when a click finds zero open windows it records a PendingLaunchFocus
    // {idLower, wmClassLower, outputFilter, targetOutput, deadline = now + 8s}
    // and every later toplevel change runs tryFulfillPendingLaunchFocus
    // (dock.cpp:1203-1209, 1148-1184). The window eventually shows up, gets
    // focused, and the entry is cleared. Without this a slow-starting app is
    // left unfocused.
    //
    // QML has no output identity on its snapshots, so the mock's outputFilter /
    // targetOutput narrowing collapses to one step: look at *this* app's
    // reactive toplevel list and take the newest activatable window. That list is
    // already per-app and per-output-aware by construction.
    // Stored on the dock root, NOT here: a pinned app's delegate is destroyed
    // and rebuilt (uniqueId pinned-<id> -> app-<id>) the moment its first
    // window appears, so per-delegate state dies before the retry can fire.
    readonly property var _pendingLaunchHost: root.appListRoot
    readonly property var _pendingLaunch: root._pendingLaunchHost ? root._pendingLaunchHost._pendingLaunch : null
    readonly property bool _pendingLaunchActive: root._pendingLaunch !== null

    function _canActivateWindow(toplevel): bool {
        if (!toplevel) return false
        if (toplevel.niriWindowId) return true
        return root._toplevelKey(toplevel).length > 0
    }

    function _activateToplevel(toplevel): void {
        if (!toplevel) return
        if (CompositorService.isNiri) {
            if (toplevel.niriWindowId) {
                NiriService.focusWindow(toplevel.niriWindowId)
            } else if (toplevel.activate) {
                toplevel.activate()
            }
        } else {
            toplevel.activate()
        }
    }

    function _newestActivatableWindow(list): var {
        if (!list) return null
        // Mock keeps overwriting the candidate so the newest activatable wins.
        for (let i = 0; i < list.length; i++) {
            if (root._canActivateWindow(list[i]))
                return list[i]
        }
        return null
    }

    function _setPendingLaunchFocus(value): void {
        if (root._pendingLaunchHost) root._pendingLaunchHost._pendingLaunch = value
    }

    function _startPendingLaunchFocus(): void {
        root._setPendingLaunchFocus({
            id: root.appToplevel?.originalAppId ?? root.appToplevel?.appId,
            deadline: Date.now() + 8000
        })
        pendingLaunchTimer.restart()
    }

    function _clearPendingLaunchFocus(): void {
        root._setPendingLaunchFocus(null)
        pendingLaunchTimer.stop()
    }

    function _tryFulfillPendingLaunchFocus(): void {
        const pending = root._pendingLaunch
        if (!pending) return
        // Expired entries can linger when no delegate existed to run the timer
        // (the launching delegate was rebuilt), so re-check on every touch.
        if (Date.now() > pending.deadline) {
            root._clearPendingLaunchFocus()
            return
        }
        // Only the delegate for the app that was launched fulfils it; every
        // other delegate shares this root-level entry and must ignore it.
        const myId = root.appToplevel?.originalAppId ?? root.appToplevel?.appId
        if (pending.id && myId && pending.id !== myId) return
        const window = root._newestActivatableWindow(root.toplevels)
        if (!window) return
        root._clearPendingLaunchFocus()
        root._activateToplevel(window)
    }

    Timer {
        id: pendingLaunchTimer
        interval: 300
        repeat: true
        onTriggered: root._tryFulfillPendingLaunchFocus()
    }


    // Event-driven half of the retry (mock: every toplevel change calls
    // tryFulfillPendingLaunchFocus). The timer covers the case where the
    // window appears without the list object identity changing.
    Connections {
        target: root
        function onToplevelsChanged() {
            if (root._pendingLaunchActive)
                root._tryFulfillPendingLaunchFocus()
        }
    }

    // A rebuilt delegate inherits the pending entry from the dock root, so the
    // retry resumes instead of lapsing when uniqueId flips pinned-<id> ->
    // app-<id> the moment the launched window appears.
    Component.onCompleted: {
        if (root._pendingLaunchActive)
            pendingLaunchTimer.restart()
        IconThemeService.requestRaster(root._resolvedIconSource, root._rasterPx)

        if (root._needsIcon)
            root.appListRoot?.registerIconPending(root._iconKey)

        // Start the desktop-entry inventory that "Change icon" reads. It is
        // idempotent and guarded inside the singleton, so calling it from
        // every delegate costs one boolean check — and it is called from an
        // Item's onCompleted rather than the singleton's own timer, because a
        // timer inside a singleton created during engine setup does not get
        // to run its first tick in this build.
        IconOverride.ensureReady()
    }

    // ─── Icon readiness ─────────────────────────────────────────────────
    // The one signal that actually means "this icon is on screen".
    //
    // WHY NOT THE EARLIER STAGES. Two things have to happen before an icon can
    // paint, and both are asynchronous:
    //   1. IconThemeService builds its theme index (_indexReady). Until then
    //      pathFor() returns "" and resolveIconUrl() has nothing real to hand
    //      back, so every source is still a guess.
    //   2. The IconImage must then actually decode. `status` is the only
    //      property that reports this; a non-empty `source` says nothing about
    //      whether the pixmap exists yet.
    // Gating on stage 1 alone is what let icons pop in: the source became a
    // valid file:// URL well before the image finished loading.
    //
    // An EMPTY source is treated as ready on purpose. It is not a slow load, it
    // is the resolver finding nothing at all — resolveIconUrl() fell through
    // every theme and every generic glyph. Nothing will ever arrive, so waiting
    // would only park the dock on its fallback timeout with the same result.
    readonly property bool _needsIcon: !root.isSeparator && !root.isClock

    // Stable identity for this delegate's icon within DockApps' pending set.
    // uniqueId flips pinned-<id> -> app-<id> when the app's first window opens,
    // so the model key is NOT stable enough to dedupe on; the item's own
    // originalAppId is, and listIndex breaks a tie between two entries for the
    // same app (pinned + running as separate rows).
    readonly property string _iconKey:
        (root.appToplevel?.originalAppId ?? root.appToplevel?.appId ?? "")
        + "#" + root.listIndex

    // True once this delegate has something real to draw — a decoded pixmap, or
    // proof that nothing will ever arrive.
    //
    // An EMPTY source counts as ready on purpose. It is not a slow load, it is
    // the resolver falling through every theme and every generic glyph: no
    // image will ever exist, so waiting would only park the dock on its
    // fallback timeout and produce the same picture.
    //
    // WHY THE STATUS IS READ HERE AND NOT FROM A BINDING: `iconImageLoader`
    // is nested several levels down (iconBox → contentRoot), and an id from
    // that subtree is NOT visible in a property binding on this file's root
    // object — a binding naming it throws "ReferenceError:
    // iconImageLoader is not defined" on every evaluation and never yields a
    // value. Verified directly, not assumed. So the Loader's own scope (where
    // the id does resolve) pushes the status up through
    // _checkIconStatus() instead.
    property bool _iconReady: false

    // The clock participates in the dock's icon gate too, but through its own
    // signal rather than the app-icon path: DockClock does no
    // IconThemeService lookup (its background is a plain SVG path straight
    // from config), so it reports readiness itself. Without this the clock
    // would be invisible to the gate and the dock could reveal over a face
    // whose background has not painted yet.
    // It reuses _iconKey, which is unique for the clock entry because
    // originalAppId is "__clock__" and listIndex separates two such entries.
    function _checkClockFaceStatus(item): void {
        if (!root.isClock || !item) return
        if (item.backgroundSettled === true)
            root.appListRoot?.notifyIconReady(root._iconKey)
        else
            root.appListRoot?.registerIconPending(root._iconKey)
    }

    function _checkIconStatus(item): void {
        if (!root._needsIcon) return
        if (!item) return
        const src = String(item.source ?? "")
        const ready = root._iconSettled(item, src)
        root._iconReady = ready
        if (ready)
            root.appListRoot?.notifyIconReady(root._iconKey)
        else
            root.appListRoot?.registerIconPending(root._iconKey)
    }

    // "This icon will never change again" — the only thing the dock gate may
    // rely on. Three things must all have landed, and each one used to be
    // allowed to stand in for the others:
    //
    //   1. AppSearch.ready — until it is, _resolvedIconName is "" and the
    //      resolver hands back the GENERIC glyph. That is a real, decodable
    //      image, so a status check alone reported the icon ready and the dock
    //      opened over four identical placeholders that then swapped to the
    //      real artwork.
    //   2. IconThemeService._indexReady — same story one level down: before
    //      the index there is no real file, only a guess.
    //   3. The pixmap actually decoded. rasterOrBlank() returns "" while an
    //      SVG's raster is being converted, so a non-empty source can still
    //      change; and an empty source is no longer proof that nothing will
    //      ever arrive, because it is exactly what a queued conversion looks
    //      like. rasterPending() is what separates the two.
    function _iconSettled(item, src): bool {
        if (!AppSearch.ready) return false
        if (!IconThemeService._indexReady) return false
        if (IconThemeService.rasterPending(root._resolvedIconSource, root._rasterPx))
            return false
        if (src === "")
            return true
        return item.status === Image.Ready
    }

    // Magnify works when the standalone `dock.magnify` toggle is enabled.
    readonly property bool _magnifyEnabled: Config.options?.dock?.magnify ?? false
    // The mock computes magnification from the pointer's position along the
    // dock's main axis (cos^2 falloff) and hands every item a plain scale
    // multiplier plus a main-axis displacement. DockApps runs that frame loop
    // once for the whole row; the multiplier arrives here already lerped.
    readonly property real _magnifyMultiplier: root._magnifyEnabled
        ? (appListRoot?.magnifyScaleAt ? appListRoot.magnifyScaleAt(root.listIndex) : 1.0)
        : 1.0

    // Mock gates. The badge/dots are separate visual systems from the existing
    // smartIndicator dots below — both can be active at once.
    readonly property bool _showDots: Config.options?.dock?.showDots ?? false
    readonly property bool _showInstanceCount: Config.options?.dock?.showInstanceCount ?? true

    // Hover preview signals
    signal hoverPreviewRequested()
    signal hoverPreviewDismissed()

    Timer {
        id: hoverDelayTimer
        interval: Config.options?.dock?.hoverPreviewDelay ?? 400
        onTriggered: {
            if (root.hasWindows && root.buttonHovered) {
                root.hoverPreviewRequested()
            }
        }
    }

    // Determine focused window index for smart indicator.
    // toplevels is already sorted by layout (thanks to CompositorService.sortedToplevels in DockApps)
    // so we just need to find the active toplevel index.
    property int focusedWindowIndex: {
        if (!root.appIsActive || toplevels.length <= 1)
            return 0;

        const activeKey = activeWindowKey;
        if (activeKey.length === 0) return 0;

        for (let i = 0; i < toplevels.length; i++) {
            const toplevel = toplevels[i]
            if (!toplevel)
                continue
            if (_toplevelKey(toplevel) === activeKey)
                return i
        }
        return 0;
    }

    // Base scale for the whole button (mock: iconScale = active ? activeScale
    // : inactiveScale). Magnification multiplies this on the icon itself.
    scale: appIsActive ? (Config.options?.dock?.activeScale ?? 1.0) : (Config.options?.dock?.inactiveScale ?? 0.85)
    Behavior on scale {
        enabled: Appearance.animationsEnabled
        animation: NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
    }

    // mock: `area->setZIndex(lround(paintScale * 100))` (dock_items.cpp:267-274).
    // The enlarged icon must stack ABOVE its row siblings, otherwise the
    // neighbouring delegates paint over the overlap and the active icon reads
    // as a plain zoom rather than one that grows past its neighbours. With
    // itemSpacing 0 the enlarged icon visibly encroaches on adjacent cells, so
    // paint order is what makes that legible.
    z: Math.round((appIsActive ? (Config.options?.dock?.activeScale ?? 1.0) : (Config.options?.dock?.inactiveScale ?? 0.85))
                 * (root._magnifyMultiplier || 1) * 100)

    // Lift applied to the FOCUSED window's icon, in px, along the axis pointing
    // AWAY from the screen edge (up for a bottom dock, down for top, right for
    // left, left for right).
    //
    // DEVIATION FROM THE MOCK, deliberately: the C++ dock never repositions the
    // active icon. Its item layer holds items at restMainPos (updateVisuals
    // :1058-1059), syncDockItemRestPositions is a pure read (:1387-1394), and
    // applyHoverIconVisual pins the icon's centre (:114-127) — which we already
    // reproduce via transformOrigin: Center. The only translation the mock
    // applies is the neighbour spread, gated on pointerActive (updateHoverZoom
    // :1325-1339, zeroed at :1342).
    //
    // Set dock.activeIconShift to 0 in config.json for strict mock behaviour.
    readonly property real _activeShiftPx: Config.options?.dock?.activeIconShift ?? 10
    // A binding, so it tracks focus changes AND live config edits; the Behavior
    // animates whichever moves instead of popping 10px instantly.
    property real _activeShift: root.appIsActive ? root._activeShiftPx : 0
    Behavior on _activeShift {
        enabled: Appearance.animationsEnabled
        animation: NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
    }


    property bool isSeparator: appToplevel.appId === "SEPARATOR"
    // The clock rides the normal dock model as a `clockEntry: true` entry, so it
    // reuses DockAppButton and the existing drag-reorder machinery applies. It
    // has no app semantics (no launch, no windows, no context menu).
    // Such an entry exists only when dock.clock.enabled is true; the
    // "__clock__" string in pinnedApps, if present, merely positions it.
    readonly property bool isClock: appToplevel?.clockEntry === true
    // Use originalAppId (preserves case) for desktop entry lookup, fallback to appId for backwards compat
    // AppSearch.lookupDesktopEntry adds StartupWMClass, exec-basename, and desktop-id-stem matching
    // which covers AppImages and other apps where heuristicLookup alone fails.
    property var desktopEntry: !root.isClock && AppSearch.ready
        ? AppSearch.lookupDesktopEntry(appToplevel.originalAppId ?? appToplevel.appId)
        : null
    // The icon NAME this app resolves to, before it becomes a URL.
    readonly property string _resolvedIconName: {
        if (!AppSearch.ready) return ""
        const appId = appToplevel.originalAppId ?? appToplevel.appId
        let icon = ""
        if (appId === "spotify" || appId === "spotify-launcher") {
            icon = "spotify"
        } else {
            icon = root.desktopEntry?.icon || AppSearch.guessIcon(appId)
        }
        return IconThemeService.smartIconName(icon, appId)
    }
    // Resolved, loadable icon URL (file://). Held until AppSearch.ready to avoid
    // the startup race that logged "Could not load icon <name>".
    readonly property string _resolvedIconSource:
        IconThemeService.resolveIconUrl(root._resolvedIconName)
    enabled: !isSeparator

    readonly property real dockHeight: Config.options?.dock?.height ?? 70
    readonly property real _buttonSize: root.iconSize + 12
    // Pixel size SVGs are rasterised at — generously, so magnified icons stay
    // crisp (roughly 3x the dock's logical icon size).
    readonly property int _rasterPx: Math.max(256, Math.round(root.iconSize * 3))
    // Queue outside any binding: property writes during binding evaluation are
    // discarded by QML, which is why doing this in `source:` silently did
    // nothing.
    on_ResolvedIconSourceChanged: IconThemeService.requestRaster(root._resolvedIconSource, root._rasterPx)
    readonly property real separatorSize: Math.max(1, dockHeight - _buttonSize)


    implicitWidth: isSeparator ? (vertical ? separatorSize : 8) : (vertical ? root._buttonSize : (root._buttonSize - topInset - bottomInset))
    implicitHeight: isSeparator ? (vertical ? 8 : separatorSize) : root._buttonSize
    Behavior on implicitWidth {
        enabled: Appearance.animationsEnabled
        animation: NumberAnimation {
            duration: Appearance.animation.elementResize.duration
            easing.type: Appearance.animation.elementResize.type
        }
    }
    Behavior on implicitHeight {
        enabled: Appearance.animationsEnabled
        animation: NumberAnimation {
            duration: Appearance.animation.elementResize.duration
            easing.type: Appearance.animation.elementResize.type
        }
    }

    background.visible: !isSeparator
    background.implicitHeight: root._buttonSize
    background.implicitWidth: root._buttonSize
    rippleEnabled: !(Config.options?.dock?.disableRipple ?? false)

    // Hover background — bypasses RippleButton's background.color chain (broken via
    // DockButton inheritance). Renders as a sibling z:-1 Rectangle behind content.
    Rectangle {
        id: hoverOverlay
        anchors.fill: parent
        visible: root.buttonHovered && !root.isSeparator
        color: (Config.options?.dock?.hoverBackgroundColor ?? "").length > 0
            ? Config.options.dock.hoverBackgroundColor
            : Appearance.colors.colLayer0Hover
        radius: root.buttonEffectiveRadius
        z: -1
    }

    // Suppress ripple/hover bg — hoverOverlay Rectangle provides the hover visual.
    colBackgroundHover: "transparent"
    colRipple: Appearance.colors.colLayer0Active

    // Hover shadow
    StyledRectangularShadow {
        target: root.background
        opacity: root.buttonHovered && !root.isSeparator
            ? (Appearance.m3colors.darkmode ? 0.18 : 0.35) : 0
        spread: 0
        Behavior on opacity {
            enabled: Appearance.animationsEnabled
            animation: NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
        }
    }

    Loader {
        active: isSeparator
        anchors.centerIn: parent
        sourceComponent: Rectangle {
            width: root.vertical ? root.separatorSize : 1
            height: root.vertical ? 1 : root.separatorSize
            color: Appearance.colors.colOutlineVariant
        }
    }

    // Use RippleButton's built-in buttonHovered instead of separate MouseArea
    onButtonHoveredChanged: {
        if (toplevels.length > 0) {
            if (buttonHovered) {
                appListRoot.lastHoveredButton = root
                appListRoot.buttonHovered = true
            // Start hover timer for preview — suppress during page swipe
            if (Config.options?.dock?.hoverPreview !== false && !appListRoot._gestureActive) {
                hoverDelayTimer.restart()
            }
            } else {
                if (appListRoot.lastHoveredButton === root) {
                    appListRoot.buttonHovered = false
                }
                hoverDelayTimer.stop()
                // Don't dismiss preview here - let the popup's timer handle it
                // This allows mouse to move from button to popup without closing
            }
        } else {
            hoverDelayTimer.stop()
        }
    }

    function launchFromDesktopEntry(): bool {
        if (root.isClock) return false
        var id = appToplevel.originalAppId ?? appToplevel.appId;
        if (id === "com.github.th_ch.youtube_music") {
            id = "youtube-music";
        }
        if (id === "spotify" || id === "spotify-launcher") {
            id = "spotify-launcher";
        }
        if (id && id !== "" && id !== "SEPARATOR") {
            const entry = AppSearch.lookupDesktopEntry(id);
            // Exec= carries freedesktop field codes (`nautilus --new-window %U`).
            // Passing the raw line through made Nautilus treat the literal
            // "%U" as a path and pop "Unable to find .../%U". AppSearch._execArgv
            // tokenizes the line and resolves every code away, so a
            // no-argument launch yields a bare `nautilus --new-window`.
            const argv = AppSearch._execArgv(entry?.exec || id);
            if (argv.length === 0) return false;
            // execDetached takes argv directly, so no shell quoting is
            // involved and no field code can be re-interpreted downstream.
            Quickshell.execDetached(argv);
            return true;
        }
        return false;
    }

    onClicked: {
        // Suppress the click that RippleButton fires after a drag-release
        if (appListRoot?._suppressNextClick) {
            appListRoot._suppressNextClick = false
            return
        }
        // The clock has no launch/window semantics — clicks do nothing, and the
        // mock never bounces the clock entry or the launcher (dock_items.h:99-101).
        if (root.isClock) return

        // A fresh click supersedes any retry still in flight.
        root._clearPendingLaunchFocus()

        // No windows: launch and arm the 8s focus retry.
        if (toplevels.length === 0) {
            // Only the launch bounces. A click that merely raises an existing
            // window (or cycles between several) leaves the icon at rest, so the
            // animation reads as "this app was just started", not "you clicked".
            root.bounce()
            if (launchFromDesktopEntry())
                root._startPendingLaunchFocus()
            return
        }

        // Exactly one window: raise it (mock: activateToplevelInfo(windows[0])).
        if (toplevels.length === 1) {
            root._activateToplevel(toplevels[0])
            return
        }

        // Mock nextActivatableWindow: advance cyclically from the *currently
        // focused* window, so clicking a running app cycles away from the one you
        // are looking at. activeWindowKey is CompositorService's snapshot of
        // ToplevelManager.activeToplevel, which is populated under niri.
        const total = toplevels.length
        let seed = -1
        if (CompositorService.hasActiveActivatedToplevel && root.activeWindowKey.length > 0) {
            for (let i = 0; i < total; i++) {
                if (root._toplevelKey(toplevels[i]) === root.activeWindowKey) {
                    seed = i
                    break
                }
            }
        }
        const nextIndex = seed >= 0 ? (seed + 1) % total : (lastFocused + 1) % total
        lastFocused = nextIndex
        const target = toplevels[nextIndex]
        if (root._canActivateWindow(target)) {
            root._activateToplevel(target)
            return
        }
        // Mock falls back to the first activatable window.
        for (let i = 0; i < total; i++) {
            if (root._canActivateWindow(toplevels[i])) {
                lastFocused = i
                root._activateToplevel(toplevels[i])
                return
            }
        }
    }

    middleClickAction: () => {
        launchFromDesktopEntry();
    }

    altAction: () => {
        showContextMenu()
    }

    function showContextMenu(): void {
        // An empty menu never opens (mock: the popup is only created when the
        // row list is non-empty).
        if (root.menuModel.length === 0) return
        root.appListRoot.closeAllContextMenus()
        root.appListRoot.contextMenuOpen = true
        root.hoverPreviewDismissed()
        hoverDelayTimer.stop()
        // open() rather than `active = true`: closeAllContextMenus() only
        // starts the previous menu's close *animation*, so `active` is still
        // true for a moment. Right-clicking this same icon again inside that
        // window left `active = true` a no-op (no popup created) and the
        // stale close animation then shut the menu again.
        contextMenu.open()
    }

    // Set when this button's menu was closed because another button is taking
    // over. Its close animation finishes after the new menu has opened, and
    // without this flag its onActiveChanged would clear the shared
    // contextMenuOpen flag — hiding the dock (requestDockShow goes false)
    // while the new menu is still up, leaving a popup floating over a
    // disappearing dock.
    property bool contextMenuHandoff: false

    Connections {
        target: root.appListRoot
        function onCloseAllContextMenus() {
            // Only the menu that is actually open can hand over.
            if (contextMenu.active) contextMenuHandoff = true
            contextMenu.close()
        }
    }

    DockContextMenu {
        id: contextMenu
        anchorItem: root
        anchorHovered: root.buttonHovered

        onActiveChanged: {
            if (active) {
                // Newest opener clears its own pending handoff flag.
                contextMenuHandoff = false
                return
            }
            if (contextMenuHandoff || !root.appListRoot) return
            root.appListRoot.contextMenuOpen = false
        }

        model: root.menuModel

        // Chrome note: the mock uses 6px outer padding, a 9px card radius and a
        // [240, 420] px width clamp. Rows are already 32px in the shared widget;
        // padding (4), radius (Appearance.rounding.normal = 12) and the width
        // clamp are shared with every other menu consumer, so they are left as
        // they are rather than changed globally here.
    }

    // ─── Context menu (mock: dock_context_menu.cpp) ─────────────────────
    // Exact row order: Pin/Unpin, [sep], one row per window, [sep], desktop
    // actions, [sep], Close / Close All. Separators only appear between
    // non-empty groups.
    readonly property var _desktopActions: (root.isClock || !root.desktopEntry)
        ? []
        : (root.desktopEntry.actions ?? []).map(action => ({
            iconName: action.icon ?? "",
            text: action.name,
            action: () => action.execute()
        }))

    // One flat row per window, in window order. Label = window title, falling
    // back to the app name; no per-row close button.
    readonly property var _windowRows: root.toplevels.map(toplevel => ({
        iconName: root._resolvedIconSource,
        text: (toplevel?.title?.trim().length > 0)
            ? toplevel.title
            : (root.desktopEntry?.name ?? StringUtils.toTitleCase(appToplevel?.originalAppId ?? appToplevel?.appId ?? "")),
        monochromeIcon: false,
        action: () => {
            if (CompositorService.isNiri && toplevel?.niriWindowId) {
                NiriService.focusWindow(toplevel.niriWindowId)
            } else if (toplevel?.activate) {
                toplevel.activate()
            }
        }
    }))

    readonly property var menuModel: {
        if (root.isClock) return []

        const rows = []
        // 1. Pin/Unpin — always first.
        rows.push({
            iconName: appToplevel?.pinned ? "keep_off" : "keep",
            text: Translation.tr(appToplevel?.pinned ? "Unpin" : "Pin"),
            monochromeIcon: true,
            action: () => {
                const appId = appToplevel?.originalAppId ?? appToplevel?.appId
                const pinned = Config.options?.dock?.pinnedApps ?? []
                if (pinned.indexOf(appId) !== -1) {
                    Config.setNestedValue("dock.pinnedApps", pinned.filter(id => id !== appId))
                } else {
                    Config.setNestedValue("dock.pinnedApps", pinned.concat([appId]))
                }
            }
        })

        // 2. Change icon / Reset icon — an app-level group, so it sits
        // between the pin row and the per-window rows. The rows are built by
        // _iconRows, which yields nothing for the clock, the separator, a
        // window that matches no desktop entry, and whenever
        // dock.behavior.changeIconEnabled is false.
        if (root._iconRows.length > 0) {
            rows.push(...root._iconRows)
        }

        // Body between the pin row and the close group.
        const body = [].concat(root._windowRows, root._desktopActions)
        if (body.length > 0) {
            rows.push(...root._windowRows)
            rows.push(...root._desktopActions)
        }

        // Close / Close All — omitted entirely when nothing is closable.
        const closable = root.toplevels.filter(t => t && t.close)
        if (closable.length > 0) {
            rows.push({
                iconName: "close",
                text: closable.length > 1 ? Translation.tr("Close All") : Translation.tr("Close"),
                monochromeIcon: true,
                action: () => {
                    for (const toplevel of closable)
                        toplevel.close()
                }
            })
        }
        return rows
    }

    // ─── Change icon (systemwide) ─────────────────────────────────────
    // Rewrites the app's own `Icon=` through IconOverride, which writes ONLY
    // ~/.local/share/applications/<id>.desktop — a user-level copy that
    // shadows the packaged entry of the same name, so the new icon applies to
    // the panel launcher and menu launchers too, with no root and nothing in a
    // system directory touched. See services/Apps/IconOverride.qml for the
    // backup and reset rules.
    //
    // Gated on a resolvable desktop entry, so the rows simply do not exist for
    // the clock (no app, no entry), for the separator (no app at all) and for
    // any window that matches no entry — there would be nothing to rewrite.
    readonly property string _desktopId: root.desktopEntry
        ? AppSearch.desktopIdForWindow(appToplevel?.originalAppId ?? appToplevel?.appId)
        : ""
    readonly property bool _changeIconAvailable: (Config.options?.dock?.changeIconEnabled ?? true)
        && !root.isClock && !root.isSeparator && root._desktopId !== ""

    readonly property var _iconRows: {
        if (!root._changeIconAvailable) return []
        const rows = [{
            iconName: "image",
            text: Translation.tr("Change icon…"),
            monochromeIcon: true,
            action: () => root.startChangeIcon()
        }]
        // Only meaningful once something has actually been overridden.
        if (IconOverride.hasUserOverride(root._desktopId)) {
            rows.push({
                iconName: "restore",
                text: Translation.tr("Reset icon to default"),
                monochromeIcon: true,
                action: () => root.startResetIcon()
            })
        }
        return rows
    }

    readonly property string _appLabel: root.desktopEntry?.name
        ?? StringUtils.toTitleCase(appToplevel?.originalAppId ?? appToplevel?.appId ?? "")

    // Opening the picker is all this does: nothing is written until the
    // confirmation below is accepted, and a cancelled picker writes nothing at
    // all.
    //
    // Never silent. Every route out of here other than "the picker opened"
    // puts a message on screen; a menu row that does nothing is the bug this
    // guards against.
    function startChangeIcon(): void {
        if (IconOverride.busy) {
            _reportIconProblem(
                Translation.tr("Icon change already running"),
                [Translation.tr("Wait for the current icon change to finish first.")])
            return
        }
        // Idempotent: makes sure the entry inventory has been (re)listed even
        // if this is the very first interaction of the session.
        IconOverride.ensureReady()
        if (IconOverride.locate(root._desktopId) === null) {
            // The inventory may simply not have landed yet — the listing is a
            // Process, and on the very first interaction of a session
            // _entriesByDir is still empty. Retry when it lands instead of
            // returning, which is what made this row a silent no-op. If it is
            // genuinely absent, say so on screen.
            if (!IconOverride.inventoryReady) {
                _awaitInventoryThenStart()
                return
            }
            _reportIconProblem(
                Translation.tr("Cannot change icon"),
                [Translation.tr("No desktop entry was found for") + " " + root._appLabel,
                Translation.tr("Nothing was changed.")])
            return
        }
        iconPicker.title = Translation.tr("Choose an icon for ") + root._appLabel
        // Quickshell's Process has NEITHER open() NOR start(): its only spawn
        // API is the `running` property (quickshell-io.qmltypes, Component
        // "Process" — Property { name: "running"; write: "setRunning" }).
        // Assigning it starts the process, and Process resets it to false when
        // the process exits, so this object can be spawned again next time.
        iconPicker.running = true
    }

    // Retried from a Connections handler once the inventory lands, and once
    // more on a short timer so a failed listing does not leave the row dead
    // for the rest of the session.
    property bool _waitingForInventory: false

    function _awaitInventoryThenStart(): void {
        if (root._waitingForInventory) return
        root._waitingForInventory = true
        _inventoryWatch.start()
    }

    function _resumeChangeIcon(): void {
        if (!root._waitingForInventory) return
        _inventoryWatch.stop()
        root._waitingForInventory = false
        root.startChangeIcon()
    }

    Timer {
        id: _inventoryWatch
        interval: 150
        repeat: true
        onTriggered: root._resumeChangeIcon()
    }

    Connections {
        target: IconOverride
        function onInventoryReadyChanged(): void {
            root._resumeChangeIcon()
        }
    }

    // Visible failure feedback for the icon flow, reusing the confirmation
    // dialog with its confirm button relabelled "Close": _pendingAction stays
    // empty, so neither button can start a write.
    function _reportIconProblem(title, lines): void {
        console.warn("dock change-icon:", title, (lines || []).join(" "))
        confirmDialog.titleText = title
        confirmDialog.bodyLines = lines
        confirmDialog.confirmText = Translation.tr("Close")
        confirmDialog.cancelText = Translation.tr("Close")
        confirmDialog.destructive = false
        root._pendingAction = ""
        root._chosenIcon = ""
        confirmDialog.open()
    }

    function startResetIcon(): void {
        if (IconOverride.busy) {
            _reportIconProblem(
                Translation.tr("Icon change already running"),
                [Translation.tr("Wait for the current icon change to finish first.")])
            return
        }
        IconOverride.ensureReady()
        const plan = IconOverride.locate(root._desktopId)
        if (!plan || !plan.userExists || plan.systemPath === "") {
            _reportIconProblem(
                Translation.tr("Cannot reset icon"),
                [Translation.tr("There is no icon override to restore for") + " " + root._appLabel,
                Translation.tr("Nothing was changed.")])
            return
        }
        confirmDialog.titleText = Translation.tr("Reset icon for ") + root._appLabel
        confirmDialog.bodyLines = [
            Translation.tr("Restores the packaged entry's own Icon= value:"),
            plan.systemPath,
            Translation.tr("Your current override is kept in:")
                + " ~/.local/state/quickshell-dock-backup/desktop-entries"
        ]
        confirmDialog.confirmText = Translation.tr("Reset")
        confirmDialog.destructive = false
        _pendingAction = "reset"
        confirmDialog.open()
    }

    // "change" | "reset" — which flow the open dialog would commit.
    property string _pendingAction: ""
    property string _chosenIcon: ""

    function _confirmChange(path): void {
        const plan = IconOverride.locate(root._desktopId)
        if (!plan) {
            _reportIconProblem(
                Translation.tr("Cannot change icon"),
                [Translation.tr("No desktop entry was found for") + " " + root._appLabel,
                Translation.tr("Nothing was changed.")])
            return
        }
        confirmDialog.titleText = Translation.tr("Change icon for ") + root._appLabel
        confirmDialog.bodyLines = [
            Translation.tr("New icon: ") + path,
            (plan.copy ? Translation.tr("Will write (a copy of ") : Translation.tr("Will update ")) + plan.userPath,
            plan.copy ? Translation.tr("Copied from: ") + plan.systemPath
                      : Translation.tr("The previous file is backed up first."),
            Translation.tr("Only the Icon= line changes. This applies systemwide.")
        ]
        confirmDialog.confirmText = Translation.tr("Change icon")
        confirmDialog.destructive = false
        _chosenIcon = path
        _pendingAction = "change"
        confirmDialog.open()
    }

    DockConfirmDialog {
        id: confirmDialog
        anchorItem: root
        onConfirmed: {
            if (root._pendingAction === "reset")
                IconOverride.reset(root._desktopId)
            else if (root._pendingAction === "change")
                IconOverride.apply(root._desktopId, root._chosenIcon)
            root._pendingAction = ""
            root._chosenIcon = ""
        }
        onRejected: {
            // Cancel writes nothing at all.
            root._pendingAction = ""
            root._chosenIcon = ""
        }
    }

    // File picker.
    //
    // zenity, spawned as an argv array (never through a shell, so no path can
    // be reinterpreted as syntax) rather than a QtQuick.Dialogs FileDialog.
    // The native dialog is the nicer option in principle, but Qt's FileDialog
    // needs a QQuickWindow parent and cannot be raised reliably from a
    // layer-shell popup, which is exactly where this dock's menus live;
    // zenity opens its own top-level window and always works. A Process (not
    // execDetached) is used so the chosen path can be read back from stdout
    // and the exit code can distinguish "cancelled" from "chosen".
    Process {
        id: iconPicker
        property string title: ""
        running: false
        command: ["/usr/bin/zenity", "--file-selection", "--title=" + iconPicker.title,
            "--file-filter=" + Translation.tr("Images")
                + " | *.png *.svg *.jpg *.jpeg *.webp *.xpm",
            "--filename=" + root._pickerStartDir]
        stdout: StdioCollector {
            id: iconPickerOut
            onStreamFinished: {
                const chosen = (iconPickerOut.text || "").trim()
                // Empty output means the user dismissed the dialog.
                if (chosen === "") return
                root._confirmChange(chosen)
            }
        }
        onExited: (code, status) => {
            // 0 = a file was chosen, 1 = cancelled by the user. Anything else
            // is a failure to run the picker at all (zenity missing, no
            // display, exec refused). Nothing is written in any case, but the
            // user is told rather than left staring at a menu that closed.
            if (code !== 0 && code !== 1) {
                root._reportIconProblem(
                    Translation.tr("Icon picker failed"),
                    [Translation.tr("The file picker could not be opened (exit code")
                        + " " + code + ").",
                    Translation.tr("Nothing was changed.")])
            }
        }
    }

    // Start directory for the picker. Resolved once in IconOverride (a
    // singleton) rather than per delegate, so a dock with fifteen icons does
    // not run fifteen probes.
    readonly property string _pickerStartDir: IconOverride.pickerStartDir

    // The menu anchors to the icon's scaled rect, so keep it in sync while
    // the magnify/bounce frame loop moves the icon.
    onMenuModelChanged: contextMenu.updateAnchor()

      contentItem: Loader {
          active: !isSeparator
          sourceComponent: Item {
              id: contentRoot
              anchors.centerIn: parent

              // Focused vs unfocused opacity (mock: activeOpacity /
              // inactiveOpacity), animated over 200ms EaseOutCubic. A Behavior
              // only fires on an actual change, which is the mock's > 0.001 guard.
              // The delegate's own opacity (drag dim / list add transition) is a
              // separate, outer value and still multiplies into this.
              opacity: root.appIsActive
                  ? (Config.options?.dock?.activeOpacity ?? 1.0)
                  : (Config.options?.dock?.inactiveOpacity ?? 0.85)
              Behavior on opacity {
                  enabled: Appearance.animationsEnabled
                  NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
              }

              // Running-window dots (mock: showDots). Placed outside iconBox so
              // they keep their own size while the icon magnifies — the mock
              // parents the dots to the cell, not the scaled icon.
              // Distinct from the smartIndicator dots below, which are a
              // separate visual system; both can be active at once.
              Item {
                  id: runningDots
                  width: root._buttonSize
                  height: root._buttonSize
                  x: -root._buttonSize / 2
                  y: -root._buttonSize / 2
                  readonly property int dotCount: root.hasWindows ? Math.min(root.toplevels.length, 3) : 0
                  readonly property real dot: Math.max(4, Math.round(root.iconSize * 0.09))
                  readonly property real groupLength: dotCount === 0
                      ? dot
                      : dot * dotCount + 3 * (dotCount - 1)
                  readonly property real groupStart: Math.round((root._buttonSize - groupLength) * 0.5)
                  visible: root._showDots && !root.isClock && dotCount > 0

                  Repeater {
                      model: runningDots.dotCount
                      delegate: Rectangle {
                          required property int index
                          width: runningDots.dot
                          height: runningDots.dot
                          radius: runningDots.dot * 0.5
                          color: root.appIsActive ? Appearance.colors.colPrimary : Appearance.colors.colSecondary
                          // Hugs the screen edge by 1px; the group is centred on
                          // the cell's main axis.
                          x: root.vertical
                              ? (root.dockPosition === "left"
                                  ? 1
                                  : Math.round(root._buttonSize - runningDots.dot - 1))
                              : runningDots.groupStart + index * (runningDots.dot + 3)
                          y: root.vertical
                              ? runningDots.groupStart + index * (runningDots.dot + 3)
                              : (root.dockPosition === "top"
                                  ? 1
                                  : Math.round(root._buttonSize - runningDots.dot - 1))
                      }
                  }
              }

              // Icon container. Owns the magnification multiplier and folds the
              // bounce's scale addend in multiplicatively — the bounce never
              // overwrites the magnification scale (mock: scaledByBump).
              Item {
                  id: iconBox
                  width: root.iconSize
                  height: root.iconSize
                  anchors.centerIn: parent

                  Behavior on width {
                      enabled: Appearance.animationsEnabled
                      animation: NumberAnimation {
                          duration: Appearance.animation.elementResize.duration
                          easing.type: Appearance.animation.elementResize.type
                      }
                  }
                  Behavior on height {
                      enabled: Appearance.animationsEnabled
                      animation: NumberAnimation {
                          duration: Appearance.animation.elementResize.duration
                          easing.type: Appearance.animation.elementResize.type
                      }
                  }

                  // Launch bounce: translate the icon away from the dock edge,
                  // composed with the focused-window lift (_activeShift). See
                  // the _activeShiftPx note above — a deliberate deviation from
                  // the mock, not parity.
                  // The single place the bounce's SIGN is decided (see
                  // _bouncePeak: _bounceOffset is an unsigned magnitude, so
                  // this negation IS the direction). Every branch moves the
                  // icon toward the screen interior and never past the edge
                  // the dock is anchored to — hence a vertical dock bounces
                  // horizontally and a horizontal dock bounces vertically.
                  transform: Translate {
                      x: root.dockPosition === "left" ? root._bounceOffset + root._activeShift
                         : (root.dockPosition === "right" ? -root._bounceOffset - root._activeShift : 0)
                      y: root.dockPosition === "top" ? root._bounceOffset + root._activeShift
                         : (root.dockPosition === "bottom" ? -root._bounceOffset - root._activeShift : 0)
                  }

                  scale: root._magnifyMultiplier * (1 + root._bounceScaleDelta)
                  // mock applyHoverIconVisual: the icon is drawn at (6,6) and
                  // shifted along the dock edge by iconSize*(1-scale)*0.5 so the
                  // icon's CENTRE stays put. Scaling about the item's centre
                  // reproduces that exactly: the centre does not move, while
                  // the icon grows away from the screen edge.
                  transformOrigin: Item.Center

                  // Clock entry: render the live clock face instead of an app icon.
                  Loader {
                      id: clockFaceLoader
                      anchors.centerIn: parent
                      active: root.isClock
                      sourceComponent: DockClock {
                          vertical: root.vertical
                          dockPosition: root.dockPosition
                          iconSize: root.iconSize
                      }
                      // Same reasoning as the app-icon Loader below: this id
                      // is not reachable from a binding on this file's root, so
                      // readiness is pushed up from inside the Loader's scope.
                      // onLoaded covers the first evaluation; onStatusChanged
                      // covers every later load, including the swap between
                      // the analog and digital background.
                      onLoaded: root._checkClockFaceStatus(clockFaceLoader.item)
                      onStatusChanged: root._checkClockFaceStatus(clockFaceLoader.item)
                  }

                  // The clock face flips its own settledness when its SVG
                  // finishes decoding (or fails to); the gate must be told.
                  Connections {
                      target: clockFaceLoader.item
                      function onBackgroundSettledChanged() {
                          root._checkClockFaceStatus(clockFaceLoader.item)
                      }
                  }

                  Loader {
                      id: iconImageLoader
                      anchors.fill: parent
                      active: !root.isSeparator && !root.isClock
                      sourceComponent: IconImage {
                          // The icon the app itself exposes: its .desktop
                          // `Icon=` value, resolved through
                          // IconThemeService → Quickshell's icon provider.
                          // IconImage exposes `source`, not `icon`.
                          //
                          // rasterOrBlank() NEVER hands back an SVG: it
                          // returns the rasterised PNG, or "" while the
                          // conversion is still queued. The old
                          // `rasterFor(...) || _resolvedIconSource` fallback
                          // handed Qt the raw SVG for exactly as long as the
                          // conversion took, which on a cold cache is the
                          // whole first second of the session — and that SVG
                          // is what libqsvg fails on ("Could not resolve
                          // property" at the closing </svg>). A blank for that
                          // moment is covered by _checkIconStatus(), which
                          // holds the dock closed while a raster is pending.
                          source: IconThemeService.rasterOrBlank(root._resolvedIconSource, root._rasterPx)
                          // Explicit fixed size: every icon renders in the same
                          // iconSize box regardless of the source's intrinsic
                          // dimensions, so a changed app icon can't resize the
                          // dock icon (artwork padding within the box is the
                          // icon's own design, like any standard dock).
                          width: root.iconSize
                          height: root.iconSize
                          // ── Resampling quality ────────────────────────
                          // MEASURED. Read this before changing any of it.
                          //
                          // THE BUG. IconImage.qml:64-65 binds the inner
                          // Image's sourceSize to
                          //   sourceSize.width:  root.actualSize
                          //   sourceSize.height: root.actualSize
                          // where actualSize = min(width, height). There is
                          // NO devicePixelRatio factor anywhere in that
                          // wrapper. So with iconSize 80 the 256px raster
                          // was DECODED straight down to an 80x80 texture
                          // inside QQuickPixmap::load, and that 80px texture
                          // was then magnified 1.8x by HiDPI into the 144
                          // device-px box — and a further 1.25x by the
                          // delegate-root scale at :444 whenever the app is
                          // the active one. Net: a 2.25x magnification of an
                          // 80px texture. That is the soft, crawly look.
                          //
                          // Qt's sourceSize IS the decode target, so zero
                          // means "no explicit source size" and Qt uploads
                          // the PNG at its natural 256x256. The only
                          // resampling left is Qt's single draw-time scale
                          // into the box, which is what we want.
                          //
                          // WHY THROUGH `backer` AND NOT `sourceSize`.
                          // IconImage is an Item. It exposes `source`,
                          // `asynchronous`, `status`, `mipmap`, `backer`,
                          // `implicitSize`, `actualSize` — and NO
                          // `sourceSize`. Writing `sourceSize:` on the
                          // instance is a hard "Cannot assign to
                          // non-existent property" that fails the whole
                          // config load. `backer` IS an alias onto the very
                          // same inner Image that lines 64-65 bind
                          // (IconImage.qml:47), so assigning through it
                          // replaces that internal binding. LAYOUT IS NOT
                          // AFFECTED: the wrapper's width/height are the
                          // explicit values just above, `actualSize` is only
                          // READ by lines 64-65 (nothing else consumes it),
                          // and the inner Image is `anchors.fill: parent`.
                          //
                          // MIPMAP REMOVED — it was a regression, not a fix.
                          // Measured on an 8-way side-by-side, over a fixed
                          // 110x110 device-px patch, as mean|Laplacian|
                          // normalised by patch std:
                          //   A src256, sourceSize unset, mipmap OFF  .1670
                          //   B src256, sourceSize unset, mipmap ON   .1212
                          //   C src256, sourceSize 256,   mipmap OFF  .1535
                          //   D src256, sourceSize 256,   mipmap ON   .1131
                          //   F IconImage as the dock used it        .0786
                          // Mipmap costs 25-30% on its own (A->B, C->D), and
                          // on a 256->80 reduction a mip chain softens it
                          // further. The dock's live hf was .0907 before this
                          // change; variant A is the target.
                          //
                          // `smooth` is NOT an alias on IconImage, so plain
                          // `smooth: true` would only set the wrapper Item's
                          // own unused flag — hence `backer.smooth`, which
                          // reaches the real Image. Keep it: correct and
                          // harmless.
                          backer.sourceSize.width: 0
                          backer.sourceSize.height: 0
                          backer.smooth: true
                      }
                      onLoaded: root._checkIconStatus(iconImageLoader.item)
                  }

                  // Readiness is driven from HERE, inside iconBox, because this
                  // is the scope in which `iconImageLoader` resolves. onLoaded
                  // covers the first evaluation (a Connections block would miss
                  // a status that had already settled before it attached);
                  // onStatusChanged covers every later load, the raster-for-PNG
                  // swap included.
                  Connections {
                      target: iconImageLoader.item
                      function onStatusChanged() {
                          root._checkIconStatus(iconImageLoader.item)
                      }
                  }

                  // Instance-count badge (mock: showInstanceCount). Hangs past
                  // the icon's top-right corner. It lives inside iconBox so it
                  // rides along with the magnification scale and the bounce for
                  // free — exactly how the mock parents the badge to the icon.
                  Rectangle {
                      id: instanceBadge
                      readonly property real diameter: Math.max(16, root.iconSize * 0.30)
                      visible: root._showInstanceCount && !root.isClock && root.toplevels.length >= 2
                      width: instanceBadge.diameter
                      height: instanceBadge.diameter
                      radius: instanceBadge.diameter * 0.5
                      color: Appearance.colors.colPrimary
                      // badgeX = cellPad + iconSize - bd*0.55, badgeY = cellPad - bd*0.45,
                      // converted to iconBox-local top-left (iconBox origin is the
                      // icon's top-left corner).
                      x: root.iconSize - instanceBadge.diameter * 0.55 - instanceBadge.diameter * 0.5
                      y: -instanceBadge.diameter * 0.45 - instanceBadge.diameter * 0.5

                      Text {
                          anchors.centerIn: parent
                          text: root.toplevels.length > 9 ? "9+" : String(root.toplevels.length)
                          color: Appearance.m3colors.m3onPrimary
                          font.family: Appearance.font.family.numbers
                          font.pixelSize: instanceBadge.diameter * 0.72
                          font.bold: true
                          horizontalAlignment: Text.AlignHCenter
                          verticalAlignment: Text.AlignVCenter
                      }
                  }
              }

              // Smart indicator: shows window count and which is focused
              // Hidden in macOS and pill modes — those render their own indicators
              Loader {
                  active: root.hasWindows && !root.isSeparator
                anchors {
                    top: iconBox.bottom
                    topMargin: 2
                    horizontalCenter: parent.horizontalCenter
                }

                // Config options
                property bool smartIndicator: Config.options?.dock?.smartIndicator !== false
                property bool showAllDots: Config.options?.dock?.showAllWindowDots !== false
                property int maxDots: Config.options?.dock?.maxIndicatorDots ?? 5

                sourceComponent: Row {
                    spacing: 3

                    Repeater {
                        // Show dots for all windows if enabled, otherwise just for active apps
                        model: {
                            const showAll = Config.options?.dock?.showAllWindowDots !== false;
                            const max = Config.options?.dock?.maxIndicatorDots ?? 5;
                            if (root.appIsActive || showAll) {
                                return Math.min(toplevels.length, max);
                            }
                            return 0;
                        }

                        delegate: Rectangle {
                            required property int index

                            property bool smartMode: Config.options?.dock?.smartIndicator !== false

                            // Determine if this indicator corresponds to the focused window
                            property bool isFocusedWindow: {
                                if (!root.appIsActive) return false;
                                if (!smartMode) return true; // All indicators same when smart mode off
                                if (toplevels.length <= 1) return true;
                                return index === root.focusedWindowIndex;
                            }

                            radius: Math.min(width, height) / 2
                            implicitWidth: isFocusedWindow ? root.countDotWidth : root.countDotHeight
                            implicitHeight: root.countDotHeight
                            color: isFocusedWindow
                                   ? ((Config.options?.dock?.indicatorColor ?? "").length > 0
                                        ? Config.options.dock.indicatorColor
                                        : Appearance.colors.colPrimary)
                                   : ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.5)

                            Behavior on implicitWidth {
                                enabled: Appearance.animationsEnabled
                                NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
                            }
                            Behavior on color {
                                enabled: Appearance.animationsEnabled
                                animation: ColorAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
                            }
                        }
                    }

                    // Fallback: single indicator when showAllDots is off and app is inactive
                    Rectangle {
                        opacity: (!root.appIsActive && root.hasWindows && Config.options?.dock?.showAllWindowDots === false) ? 1 : 0
                        visible: opacity > 0
                        width: root.countDotHeight
                        height: root.countDotHeight
                        radius: Math.min(width, height) / 2
                        color: ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.5)

                        Behavior on opacity {
                            enabled: Appearance.animationsEnabled
                            animation: NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
                        }
                    }
                }
            }
        }
    }
}
