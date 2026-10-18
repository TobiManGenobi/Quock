import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services.Desktop
import qs.services.Apps
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell

Item {
    id: root
    // NOT clipped: the mock paints magnified icons OUTSIDE the dock pill and
    // reserves that overhang in the surface (dockHoverZoomCrossPad). Clipping
    // here would shave the top of every magnified icon. The page-swipe bounds
    // are still enforced by pagesContainer below.
    clip: false

    // Debug logging gated behind QS_DEBUG env var (project convention)
    function _log(...args): void {
        if (Quickshell.env("QS_DEBUG") === "1") console.log("[DockDrag]", ...args);
    }

    property real buttonPadding: 5
    property bool vertical: false
    property string dockPosition: "bottom"
    property var parentWindow: null
    // Magnify neighbor tracking active when the standalone toggle is enabled.
    readonly property bool _magnifyActive: Config.options?.dock?.magnify ?? false

    // Propagated hovered index for neighbor magnify
    property int macHoveredIndex: -1

    // Deferred reset — avoids the race where buttonHovered=false of the old
    // item arrives after buttonHovered=true of the new item.
    Timer {
        id: macHoverResetTimer
        interval: 32   // one frame — enough for the new hover to fire first
        repeat: false
        onTriggered: root.macHoveredIndex = -1
    }
    Component.onDestruction: macHoverResetTimer.stop()
    // ─── Pointer-driven magnification (mock port) ───────────────────────
    // The mock computes magnification from the pointer's position along the
    // dock's main axis, not from which cell reports "hovered". These are the
    // QML equivalent: `pointerMain` is the cursor in listView coordinates and
    // `itemPitch` is the centre-to-centre distance between cells.
    property real pointerMain: 0
    property bool pointerValid: false

    // Base cell: row pitch follows the base icon size so magnified icons may
    // overhang the background.
    readonly property real _cellMain: root.effectiveIconSize + 12
    readonly property real itemPitch: root._cellMain + (Config.options?.dock?.spacing ?? 2)

    // ─── Launcher button (mock port) ────────────────────────────────────
    // createLauncherButton() in the mock returns a sibling of the item loop, not
    // a member of it: the button is inserted before the first item ("start") or
    // after the last one ("end") and is never part of the pinned/running model.
    // That is why it is a sibling of the ListView here rather than a delegate —
    // it stays out of dockItems, out of drag-reorder, out of the separator logic
    // and out of the magnify item list without touching any of them.
    readonly property string _launcherPosition: Config.options?.dock?.launcherPosition ?? "none"
    readonly property bool _launcherVisible: _launcherPosition === "start" || _launcherPosition === "end"
    readonly property bool _launcherAtStart: _launcherPosition === "start"
    // Space the launcher adds along the main axis: one cell plus the row's
    // spacing (no trailing gap when the row is empty, matching the mock's flex
    // row, which never emits a gap without a following item).
    readonly property real _launcherExtent: _launcherVisible
        ? (root._cellMain + (listView.count > 0 ? (Config.options?.dock?.spacing ?? 2) : 0))
        : 0

    // Per-item magnify state, recomputed in one place each frame so the scale
    // and the neighbour-displacement clamp always see the same numbers.
    property var magnifyScales: []   // current (lerped) icon scale multipliers
    property var magnifyOffsets: []  // current (lerped) main-axis displacement, px
    property int _magnifyLastStamp: 0

    HoverHandler {
        id: magnifyHover
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad | PointerDevice.Stylus
        onPointChanged: {
            const p = magnifyHover.point.position
            const c = listView.mapFromItem(root, p.x, p.y)
            root.pointerMain = root.vertical ? c.y : c.x
            root.pointerValid = true
        }
        onHoveredChanged: {
            if (!hovered) root.pointerValid = false
        }
    }

    // ─── Magnification frame loop (mock port) ───────────────────────────
    // Mirrors mock/src/shell/dock/dock_items.cpp:updateHoverZoom — a
    // frame-rate-independent lerp toward the cos^2 falloff scale, then the
    // symmetric neighbour spread clamped by one uniform spreadFactor so
    // nothing overflows the row bounds.
    FrameAnimation {
        running: root._magnifyActive && root.pointerValid && listView.count > 0
        onTriggered: root._stepMagnify()
    }

    function _hoverMultiplier(index): real {
        if (!root._magnifyActive || !root.pointerValid || index < 0) return 1.0
        const peak = Math.max(1.0, Config.options?.dock?.magnifyScale ?? 1.28)
        if (peak <= 1.0) return 1.0
        const item = listView.itemAtIndex(index)
        if (!item) return 1.0
        const centre = (root.vertical ? item.y + item.height / 2 : item.x + item.width / 2)
        const distance = Math.abs(root.pointerMain - centre)
        // kHoverZoomFalloffInfluence = 1.5 item pitches.
        const influence = root.itemPitch * 1.5
        if (distance >= influence) return 1.0
        const t = distance / influence
        const cosine = Math.cos(t * Math.PI / 2)
        return 1.0 + (peak - 1.0) * cosine * cosine
    }

    function _stepMagnify(): void {
        const now = Date.now()
        const deltaMs = Math.max(1, Math.min(50, now - root._magnifyLastStamp))
        root._magnifyLastStamp = now
        // kHoverZoomLerp at a 60 Hz reference frame, made frame-rate independent.
        const lerpFactor = 1.0 - Math.pow(1.0 - 0.28, deltaMs / (1000.0 / 60.0))

        const count = Math.min(listView.count, dockItems.length)
        if (count <= 0) {
            root.magnifyScales = []
            root.magnifyOffsets = []
            return
        }

        const iSize = root.effectiveIconSize
        const cellMain = root._cellMain
        const magnifyActive = Config.options?.dock?.magnifyActive ?? true
        const neighbourCap = Config.options?.dock?.magnifyNeighborScale ?? 1.15
        const radius = Math.max(1, Config.options?.dock?.magnifyRadius ?? 2)

        // Hovered index still matters for two things the mock gets for free:
        // the magnifyActive opt-out and the neighbour cap.
        const prevScales = root.magnifyScales
        const prevOffsets = root.magnifyOffsets
        const activeScale = Config.options?.dock?.activeScale ?? 1.0
        const inactiveScale = Config.options?.dock?.inactiveScale ?? 0.85

        // Hovered index still matters for two things the mock gets for free:
        // the magnifyActive opt-out and the neighbour cap.
        const hovered = root.macHoveredIndex

        const targetScales = []
        const targetMultipliers = []
        for (let i = 0; i < count; i++) {
            const item = listView.itemAtIndex(i)
            // Separators have no icon to magnify and are not part of the mock's
            // item set — keep them at rest scale.
            const isSeparator = dockItems[i].appId === "SEPARATOR"
            const isActive = !isSeparator && (item?.appIsActive ?? false)
            const base = isSeparator ? 1.0 : (isActive ? activeScale : inactiveScale)
            let multiplier = isSeparator ? 1.0 : root._hoverMultiplier(i)

            if (multiplier > 1.0) {
                const dist = hovered < 0 ? 99 : Math.abs(hovered - i)
                // magnifyActive: the icon never magnifies when its app is unfocused.
                if (!magnifyActive && !isActive) multiplier = 1.0
                // magnifyNeighborScale caps how far a non-hovered neighbour may grow.
                else if (dist !== 0 && dist <= radius) {
                    multiplier = Math.min(multiplier, Math.max(1.0, neighbourCap))
                }
            }
            targetMultipliers.push(multiplier)
            targetScales.push(base * multiplier)
        }

        // computeSymmetricSpreadOffsets
        const rawOffsets = []
        for (let i = 0; i < count; i++) rawOffsets.push(0)
        if (count > 1) {
            for (let i = 1; i < count; i++) {
                const pairExtra = iSize * (targetScales[i - 1] + targetScales[i] - 2.0) * 0.5
                if (pairExtra <= 0) continue
                const halfExtra = pairExtra * 0.5
                rawOffsets[i - 1] -= halfExtra
                rawOffsets[i] += halfExtra
            }
        }

        // clampSpreadOffsetsToBounds — one uniform factor for the whole row.
        const rowMainSize = root.vertical ? listView.height : listView.width
        const boundsMin = 0
        const boundsMax = rowMainSize
        let spreadFactor = 1.0
        for (let i = 0; i < count; i++) {
            const offset = rawOffsets[i]
            if (Math.abs(offset) <= 0.001) continue
            const item = listView.itemAtIndex(i)
            if (!item) continue
            const restMainPos = root.vertical ? item.y : item.x
            const centre = restMainPos + cellMain * 0.5
            if (offset > 0) {
                const maxRightOffset = boundsMax - (centre + iSize * targetScales[i] * 0.5)
                if (maxRightOffset <= 0) spreadFactor = 0
                else spreadFactor = Math.min(spreadFactor, maxRightOffset / offset)
            } else {
                const maxLeftOffset = boundsMin - (centre - iSize * targetScales[i] * 0.5)
                if (maxLeftOffset >= 0) spreadFactor = 0
                else spreadFactor = Math.min(spreadFactor, maxLeftOffset / offset)
            }
        }
        spreadFactor = Math.max(0, Math.min(1, spreadFactor))
        for (let i = 0; i < count; i++) rawOffsets[i] *= spreadFactor

        // lerpHoverMainOffset / applyAnimatedIconScale. magnifyScales holds the
        // icon *multiplier*; the delegate's own active/inactive scale supplies
        // the base, so magnification composes instead of overwriting it.
        const scales = []
        const offsets = []
        for (let i = 0; i < count; i++) {
            const target = targetMultipliers[i]
            const prevScale = prevScales.length > i ? prevScales[i] : target
            const prevOffset = prevOffsets.length > i ? prevOffsets[i] : 0
            scales.push(Math.abs(prevScale - target) <= 0.002
                        ? target
                        : prevScale + (target - prevScale) * lerpFactor)
            offsets.push(Math.abs(prevOffset - rawOffsets[i]) <= 0.25
                        ? rawOffsets[i]
                        : prevOffset + (rawOffsets[i] - prevOffset) * lerpFactor)
        }
        root.magnifyScales = scales
        root.magnifyOffsets = offsets
    }

    // Snapshot the stamp the first time the loop starts so a long idle gap
    // between two hover events cannot produce a single huge lerp step.
    onPointerValidChanged: {
        if (pointerValid) root._magnifyLastStamp = Date.now()
    }
    function magnifyScaleAt(index): real {
        return index >= 0 && index < magnifyScales.length ? magnifyScales[index] : 1.0
    }
    function magnifyOffsetAt(index): real {
        return index >= 0 && index < magnifyOffsets.length ? magnifyOffsets[index] : 0
    }

    property Item lastHoveredButton
    property bool buttonHovered: false
    property bool contextMenuOpen: false
    property bool requestDockShow: dockPreviewPopup.visible || contextMenuOpen || dragActive

    // Track which button has its preview visible (for macOS hover persistence)
    readonly property Item previewAnchorItem: dockPreviewPopup.visible ? dockPreviewPopup.anchorItem : null

    // Signal to close any open context menu before opening a new one
    signal closeAllContextMenus()

    // Flag to suppress the automatic click() that RippleButton fires after release.
    // Set true when a drag ends so the subsequent onClicked is ignored.
    property bool _suppressNextClick: false

    // Function to show the new preview popup (Waffle-style)
    function showPreviewPopup(appEntry: var, button: Item): void {
        // Respect hoverPreview setting
        if (Config.options?.dock?.hoverPreview === false) return
        dockPreviewPopup.show(appEntry, button)
    }

    Layout.fillHeight: !vertical
    Layout.fillWidth: vertical
    // For vertical: use dockHeight (from config) as implicitWidth instead of
    // listView.contentWidth, which is -1 (unresolved) before the ColumnLayout
    // finishes sizing — creating a circular dependency with Layout.fillWidth.
    // The actual width is assigned by the ColumnLayout anyway via fillWidth.
    // The launcher is not a delegate, so listView.contentWidth does not include
    // it — add its extent back in or the dock surface clips it.
    implicitWidth: vertical ? (parentWindow?.dockHeight ?? 80) : Math.min(listView.contentWidth + _launcherExtent, pageWidth)
    // Horizontal mode: delegate height = ListView viewport height (standard
    // horizontal-ListView behavior), so implicitHeight MUST NOT come from
    // listView.contentHeight — that creates a circular dependency
    // (contentHeight → viewport height → root.height → RowLayout height →
    // this implicitHeight → contentHeight) that resolves to 0 and collapses
    // the horizontal dock to a zero-height row (icons invisible at top/bottom).
    // Use the config dockHeight instead, mirroring the vertical mode's use of
    // dockHeight for implicitWidth.
    // Stays PANEL-sized (mock: the pill is panel-sized and icons overhang it).
    // It must NOT use surfaceH: this value drives the parent layout, so growing
    // it would inflate the background pill to the full surface — the opposite of
    // the mock. The overhang is handled by NOT clipping (see `clip: false`
    // below) plus the zoom padding the surface already reserves.
    implicitHeight: vertical ? Math.min(listView.contentHeight + _launcherExtent, pageHeight) : (parentWindow?.dockHeight ?? 80)
    // Smooth the overall dock resize as items enter/leave or iconSize refits.
    // This animates the container's reported size, which drives the parent
    // layout (panel height/width and screen centering).
    Behavior on implicitWidth {
        enabled: Appearance.animationsEnabled
        animation: NumberAnimation { duration: Appearance.animation.elementResize.duration; easing.type: Appearance.animation.elementResize.type }
    }
    Behavior on implicitHeight {
        enabled: Appearance.animationsEnabled
        animation: NumberAnimation { duration: Appearance.animation.elementResize.duration; easing.type: Appearance.animation.elementResize.type }
    }


    // ─── Page Swipe State ───────────────────────────────────────────────
    property real pageWidth: 0
    property real pageHeight: 0
    // _pageSize = one page's visible dimension (the dock height/width).
    // Used as the step for snapToPage(), gesture threshold, and container offset.
    readonly property real _pageSize: vertical ? root.height : root.width
    // Two fixed pages: 0 = app icons, 1 = system controls
    readonly property int _pageCount: 2
    property int _currentPage: 0
    property real _contentOffset: 0

    // Gesture tracking
    property bool _gestureActive: false
    property real _gestureStartPos: 0
    property real _gestureCumulative: 0
    property int _gestureOriginPage: 0

    readonly property real _swipeSensitivity: Config.options?.dock?.swipeSensitivity ?? 1.0
    readonly property real _swipeThreshold: Config.options?.dock?.swipeThreshold ?? 0.25
    // ─── Drag & Drop State ───────────────────────────────────────────────
    readonly property bool dragEnabled: Config.options?.dock?.enableDragReorder ?? true
    property bool dragActive: false
    property int dragIndex: -1           // Index of item being dragged in dockItems
    property int dropTargetIndex: -1     // INSERT INDEX in [0, pinnedCount]
    property string dragAppId: ""        // AppId of the item being dragged
    property real dragStartX: 0          // Mouse position at drag start (in listView coords)
    property real dragStartY: 0
    property real dragCurrentX: 0        // Current mouse position (in listView coords)
    property real dragCurrentY: 0

    // Retain the last drag offsets for a single frame after drop to avoid the reverse snap
    property bool dropSettlingActive: false
    property string dropSettleId: ""
    property int dropSettleIndex: -1
    property real dropSettleOffsetX: 0
    property real dropSettleOffsetY: 0

    // How far mouse must move during long-press before it's cancelled
    readonly property real dragThreshold: 18
    // How far the pointer may travel during a press and still count as a TAP
    // rather than a drag. Suppression of the click is gated on REAL travel
    // past this budget, never on the prime timer having merely fired.
    //
    // Chosen as 10 px, the midpoint between the two bounds that matter here:
    //   - a touchpad tap on the ELAN9038 drifts a few px (the brief puts it at
    //     ~5 px), so 10 px clears it with 2x headroom — the tap cannot
    //     suppress itself;
    //   - `dragThreshold` (18 px) is what this file already uses to mean "the
    //     user is really moving", so 10 px stays strictly below it and a
    //     reorder drag that clears the drag threshold clears this too.
    // Below 8 px a deliberate but short drag would start launching apps;
    // above ~12 px a slow tap's drift would start eating the click again.
    readonly property real jitterTolerance: 10
    // How far the pointer must travel, along the paging axis, before a page
    // swipe ARMS. This is deliberately NOT a small jitter budget: a touchpad
    // tap (ELAN9038, tap-to-click under niri) arrives as press+release with a
    // few px of positional drift, and arming the swipe also arms
    // `_suppressNextClick`, which swallows the click on release. A 6 px arm
    // budget is inside that drift, so a single tap did nothing and only the
    // second tap — from a settled pointer — got through.
    //
    // 18 px matches `dragThreshold`, the constant this file already uses to
    // mean "the user is really moving, not jittering". It cannot break a real
    // swipe: a page only flips at `_pageSize * swipeThreshold` (0.25 of the
    // dock's width, i.e. hundreds of px), so arming 18 px early leaves ~90% of
    // the travel that decides the outcome, and the flip threshold itself is
    // untouched. Only the first 12 px of follow-finger tracking is deferred.
    readonly property real swipeArmThreshold: 18

    // Mock: dock_items.cpp computeDragTargetIndex — walk the pinned items and
    // take the last one whose rest centre the pointer has passed (plus a
    // 5%-of-pitch dead zone); the answer is an insert index, not a nearest
    // neighbour, and is clamped to [0, pinnedCount].
    function _dragInsertIndex(globalX: real, globalY: real): int {
        const limit = Math.min(root.pinnedCount, dockItems.length)
        if (limit <= 0) return 0
        const mainPos = root.vertical ? globalY : globalX
        const pitch = root.itemPitch
        let target = 0
        for (let i = 0; i < limit; i++) {
            const item = listView.itemAtIndex(i)
            if (!item) continue
            const restMain = root.vertical ? item.y : item.x
            const restCentre = restMain + root._cellMain * 0.5
            if (mainPos > restCentre + pitch * 0.05) target = i + 1
        }
        return Math.max(0, Math.min(target, limit))
    }

    // Mock: dock_items.cpp applyDragVisuals — every other PINNED item shifts by
    // exactly one pitch to open the insertion gap; unpinned running apps are
    // never displaced.
    function getDragDisplacement(itemIndex: int): real {
        if (!dragActive || dragIndex < 0 || dropTargetIndex < 0) return 0
        if (itemIndex === dragIndex) return 0 // Dragged item uses its own transform
        if (itemIndex >= root.pinnedCount) return 0
        const step = root.itemPitch
        // before = i < source && i >= target  → +pitch
        if (itemIndex < dragIndex && itemIndex >= dropTargetIndex) return step
        // after  = i > source && i <  target  → -pitch
        if (itemIndex > dragIndex && itemIndex < dropTargetIndex) return -step
        return 0
    }

    function startDrag(index: int, appId: string, globalX: real, globalY: real): void {
        if (!dragEnabled) return
        // Mock: dock.cpp beginDrag / dock_items.cpp press handler — only PINNED
        // items can start a drag; running-but-unpinned items ignore it entirely.
        if (index < 0 || index >= root.pinnedCount) return

        // Close any previews or context menus
        dockPreviewPopup.close()
        closeAllContextMenus()

        dragIndex = index
        dragAppId = appId
        dragStartX = globalX
        dragStartY = globalY
        dragCurrentX = globalX
        dragCurrentY = globalY
        dropTargetIndex = _dragInsertIndex(globalX, globalY)
        dragActive = true
        _log(`START index=${index} appId=${appId} pos=(${globalX.toFixed(0)},${globalY.toFixed(0)})`)
    }

    function updateDrag(globalX: real, globalY: real): void {
        if (!dragActive || dragIndex < 0) return
        dragCurrentX = globalX
        dragCurrentY = globalY

        const nextTarget = _dragInsertIndex(globalX, globalY)
        if (dropTargetIndex !== nextTarget) {
            _log(`UPDATE insertTarget=${nextTarget} (was ${dropTargetIndex})`)
        }
        dropTargetIndex = nextTarget
    }

    function endDrag(): void {
        if (!dragActive) return

        // Keep the current drag offset so the item stays in place while the model reorders
        const draggedItem = dockItems[dragIndex]
        dropSettleId = draggedItem?.uniqueId ?? dragAppId
        dropSettleIndex = dragIndex
        // Keep offsets at zero so the item “stays put” with animations off
        dropSettleOffsetX = 0
        dropSettleOffsetY = 0
        dropSettlingActive = true

        _log(`END dragIndex=${dragIndex} insertTarget=${dropTargetIndex}`)
        // Mock: dock.cpp endDrag — the target is an insert position in the
        // pinned list. source → source and source+1 are both no-ops once the
        // source has been erased, matching the mock's insertAt adjustment.
        if (dragIndex >= 0 && dropTargetIndex >= 0
                && dropTargetIndex !== dragIndex && dropTargetIndex !== dragIndex + 1) {
            _applyInsertReorder(dragIndex, dropTargetIndex)
        }

        _resetDragState(false)
        // Clear settle offsets on the next tick, after the model/layout updates
        dropSettleResetTimer.restart()
    }

    function _resetDragState(clearDropSettle = true): void {
        dragActive = false
        dragIndex = -1
        dropTargetIndex = -1
        dragAppId = ""
        dragStartX = 0
        dragStartY = 0
        dragCurrentX = 0
        dragCurrentY = 0
        if (clearDropSettle) {
            dropSettleResetTimer.stop()
            dropSettlingActive = false
            dropSettleId = ""
            dropSettleIndex = -1
            dropSettleOffsetX = 0
            dropSettleOffsetY = 0
        }
    }

    Timer {
        id: dropSettleResetTimer
        interval: 2
        repeat: false
        onTriggered: {
            dropSettlingActive = false
            dropSettleId = ""
            dropSettleIndex = -1
            dropSettleOffsetX = 0
            dropSettleOffsetY = 0
        }
    }

    function snapToPage(page: int): void {
        const target = page * root._pageSize
        if (Math.abs(target - root._contentOffset) < 1) {
            root._contentOffset = target
            root._currentPage = page
            return
        }
        pageSnapAnim.from = root._contentOffset
        pageSnapAnim.to = target
        _snapTargetPage = page
        pageSnapAnim.start()
    }

    function cancelPageSnap(): void {
        if (pageSnapAnim.running) {
            pageSnapAnim.stop()
            _contentOffset = _currentPage * _pageSize
        }
    }

    property int _snapTargetPage: 0

    NumberAnimation {
        id: pageSnapAnim
        target: root
        property: "_contentOffset"
        duration: 250
        easing.type: Easing.OutCubic
        onFinished: {
            root._contentOffset = root._snapTargetPage * root._pageSize
            root._currentPage = root._snapTargetPage
        }
    }

    // Mock: dock.cpp endDrag — erase the source from the pinned list and
    // re-insert it at `insertAt` (already adjusted for the erase, so the
    // caller passes the raw insert target). Because drag arms only on pinned
    // items, auto-pinning a running app and the "drop into the running
    // section" cases no longer exist.
    //
    // The clock rides this same path. It is not an app (it has no icon to
    // launch), so there is nothing to invent a synthetic app id FOR: the
    // "__clock__" sentinel already IS its identity in pinnedApps, and
    // _doRebuildDockItems already reads that sentinel as a position anchor.
    // Moving the clock is therefore just moving (or creating) one sentinel,
    // which reuses the persistence path below unchanged.
    function _applyInsertReorder(fromIdx: int, insertAt: int): void {
        const fromItem = dockItems[fromIdx]
        if (!fromItem) return

        const fromAppId = fromItem.originalAppId ?? fromItem.appId
        if (!fromAppId || fromAppId === "SEPARATOR") return

        const pinnedApps = [...(Config.options?.dock?.pinnedApps ?? [])]

        if (fromAppId === "__clock__") {
            _applyClockReorder(pinnedApps, _pinnedInsertIndex(insertAt))
            Config.setNestedValue("dock.pinnedApps", pinnedApps)
            return
        }

        // `insertAt` is a MODEL-space index; pinnedApps is the CONFIG list.
        // They coincide in the legacy branch but NOT in the separated one,
        // where a pinned app that is running emits no pinned entry and shows
        // up in the running section instead. Resolve through the rebuild's
        // map so a drop lands in the right config slot in both branches.
        const realInsertAt = _pinnedInsertIndex(insertAt)
        const lower = String(fromAppId).toLowerCase()
        const realFromIdx = pinnedApps.findIndex(p => String(p).toLowerCase() === lower)
        if (realFromIdx < 0) return

        const [moved] = pinnedApps.splice(realFromIdx, 1)
        let at = realInsertAt
        if (at > realFromIdx) at -= 1
        at = Math.max(0, Math.min(at, pinnedApps.length))
        pinnedApps.splice(at, 0, moved)
        Config.setNestedValue("dock.pinnedApps", pinnedApps)
    }

    // Move — or, on the very first drag, create — the clock's position anchor.
    // Creating it is what makes an `enabled: true` + no-sentinel config (the
    // clock renders at the end of the pinned section) remember where the user
    // dropped it. Either way exactly ONE "__clock__" exists afterwards, which
    // is what keeps _doRebuildDockItems emitting exactly one clock entry.
    function _applyClockReorder(pinnedApps, insertAt: int): void {
        const anchor = pinnedApps.indexOf("__clock__")
        if (anchor < 0) {
            pinnedApps.splice(Math.max(0, Math.min(insertAt, pinnedApps.length)), 0, "__clock__")
            return
        }
        pinnedApps.splice(anchor, 1)
        // `insertAt` is still expressed in the PRE-erase coordinate space, so
        // it has to drop by one when the target was past the source — the same
        // adjustment the app path above applies.
        let at = insertAt
        if (at > anchor) at -= 1
        pinnedApps.splice(Math.max(0, Math.min(at, pinnedApps.length)), 0, "__clock__")
    }

    // Translate a model-space insert index (clamped to [0, pinnedCount] by
    // _dragInsertIndex) into an index into the Config pinnedApps list.
    // _pinnedIndexMap is rebuilt alongside dockItems and holds, for every
    // pinned-section model entry, its pinnedApps index — or -1 for the clock
    // when the config carries no sentinel yet, because that entry occupies a
    // model slot with no config slot behind it.
    function _pinnedInsertIndex(insertAt: int): int {
        const map = root._pinnedIndexMap ?? []
        // No map (empty dock, or a rebuild that predates it): model space and
        // config space are the same thing here.
        if (map.length === 0) return Math.max(0, insertAt)
        if (insertAt < map.length && map[insertAt] >= 0) return map[insertAt]
        // Appending at/past the end of the pinned section: land just after the
        // last pinned entry that actually HAS a config slot.
        for (let i = map.length - 1; i >= 0; i--) {
            if (map[i] >= 0) return map[i] + 1
        }
        return 0
    }

    // Maps each pinned-section model index to its index in the Config
    // pinnedApps list, rebuilt by _doRebuildDockItems whenever dockItems is
    // rebuilt. -1 marks a model entry with no config slot behind it: the clock
    // rendered from `enabled: true` with no "__clock__" sentinel in the config
    // occupies a slot but nothing in pinnedApps corresponds to it. Consumed by
    // _pinnedInsertIndex so drag/drop resolves against the CONFIG list in both
    // model branches.
    property var _pinnedIndexMap: []

    // ─── Dock Items Model ────────────────────────────────────────────────
    readonly property real _maxDockHeight: Config.options?.dock?.maxDockHeight ?? 0
    readonly property real _configIconSize: Config.options?.dock?.iconSize ?? 35
    readonly property real _padding: (Config.options?.dock?.padding ?? 5) * 2
    readonly property real _spacing: Config.options?.dock?.spacing ?? 2
    readonly property int _itemCount: dockItems.length
    // Space available to the icon row/column, along its axis: the page size
    // Dock.qml computes from the viewport (already excludes margins + padding).
    // A maxDockHeight cap, when set, overrides the page dimension.
    readonly property real _availableSpace: {
        if (_maxDockHeight > 0) return _maxDockHeight - _padding
        return root.vertical ? pageHeight : pageWidth
    }
    // Auto-fit: icons render at iconSize unless the icon column would exceed
    // the dock's max size (maxDockHeight when set, else the page size Dock.qml
    // derives from the viewport), then shrink just enough to fit. No minimum
    // floor; the 8px clamp only guards against degenerate (<=0) sizes at
    // absurd item counts.
    readonly property real effectiveIconSize: {
        // Before layout resolves, _availableSpace is 0 and maxIcon goes
        // negative — fall back to full icon size instead of the 8px floor, so
        // the first frames lay out correctly behind the readiness gate.
        if (_availableSpace <= 0) return _configIconSize
        var maxIcon = (_availableSpace - (_itemCount - 1) * _spacing) / _itemCount - 12
        // Snap to a whole logical pixel. A fractional box size makes the icon
        // land on subpixel positions, and every device pixel of it is then a
        // resample rather than a copy.
        //
        // FLOOR, not round: Math.round could hand back a value up to 0.5px
        // LARGER than maxIcon, and the row length scales with _itemCount, so
        // that up-to-0.5px-per-item overflow could push the row past
        // _availableSpace and change how many icons fit. Ceil is worse for the
        // same reason. Floor can only ever shrink the row, so the auto-fit
        // contract (icons always fit) is preserved by construction.
        return Math.floor(Math.max(8, Math.min(_configIconSize, maxIcon)))
    }

    property var dockItems: []

    // Reactive per-app toplevel map keyed by uniqueId. DockAppButton reads this
    // instead of its modelData snapshot: ScriptModel matches items by uniqueId,
    // so a pinned app going open→closed keeps its delegate and the snapshot
    // would leave a stale running indicator/preview until an unrelated reorder.
    property var toplevelsByUniqueId: ({})

    // ─── Icon readiness gate ─────────────────────────────────────────────
    // `iconsReady` is the signal Dock.qml gates the whole dock surface on: it
    // stays fully transparent (background included) until every icon it means
    // to show has a decoded pixmap.
    //
    // WHY THIS AND NOT THE UPSTREAM SCANS.
    // There are three stages, and only the last one is the real gate:
    //   1. AppSearch.ready          — the .desktop scan finished, _map is
    //                                populated. This resolves APP IDs only; it
    //                                says nothing about artwork.
    //   2. IconThemeService._indexReady — the theme index is built, so
    //                                pathFor() can return a real file. Still a
    //                                PATH: the IconImage has not decoded it.
    //   3. every IconImage.status === Image.Ready — the pixmap exists.
    // The old gate was a bare 300 ms Timer, which orders against none of these;
    // on a cold cache the index alone takes longer than that, so icons kept
    // arriving after the dock appeared. Stage 3 is the only one that cannot be
    // followed by a late pop, so stages 1 and 2 are kept only as PRECONDITIONS
    // below — they stop the gate opening during a window in which a delegate
    // has not even been created yet.
    //
    // It LATCHES. Once true it never goes back to false: an app opening a
    // window, or a new pin, adds delegates long after startup and must not
    // re-hide a dock the user is already looking at.
    property bool iconsReady: false

    // Set of delegate icon keys that have registered but not yet reported in.
    // Rebuilt as a fresh object on every change: mutating a JS object in place
    // emits no notification, so a binding watching it would never re-evaluate.
    property var _pendingIconKeys: ({})

    // A delegate adds itself here before it has an image.
    function registerIconPending(key: string): void {
        if (root.iconsReady || !key) return
        if (root._pendingIconKeys[key]) return
        const next = {}
        for (const k in root._pendingIconKeys) next[k] = true
        next[key] = true
        root._pendingIconKeys = next
        root._checkIconGate()
    }

    // …and removes itself here once its icon has loaded. A key that was never
    // registered is ignored, so a delegate that reported before registering
    // (or one from a model already latched open) cannot drive the count.
    function notifyIconReady(key: string): void {
        if (root.iconsReady || !key || !root._pendingIconKeys[key]) return
        const next = {}
        for (const k in root._pendingIconKeys) next[k] = true
        delete next[key]
        root._pendingIconKeys = next
        // Every arrival reopens the quiet period below, so a second wave of
        // icons cannot slip through the gap between two reports.
        iconSettle.restart()
        root._checkIconGate()
    }

    // Quiet period before the gate is allowed to open. A source can still
    // change AFTER its first successful load: IconThemeService.rasterOrBlank()
    // returns "" while a raster is queued, so IconImage.source flips from ""
    // to the PNG once the conversion lands — a visible swap that a "status is
    // Ready" check alone would wave through. An empty source that is NOT
    // rasterPending is final and needs no settle window.
    // Re-opening the gate for one settle window after the LAST report lets that
    // swap land while the dock is still hidden.
    Timer {
        id: iconSettle
        interval: 120
        repeat: false
        onTriggered: root._checkIconGate()
    }

    // Both upstream scans must have landed. Read as a binding so the gate
    // re-checks itself the moment either flips.
    readonly property bool _upstreamReady:
        AppSearch.ready === true && IconThemeService._indexReady === true

    // Nothing pinned and nothing running: there are no icons to wait for, and
    // the gate must open rather than sit on the fallback timer forever.
    readonly property bool _noIconsExpected: root.dockItems.length === 0

    function _checkIconGate(): void {
        if (root.iconsReady) return
        // Still inside the quiet period after the last report.
        if (iconSettle.running) return
        if (!root._upstreamReady) return
        // "Nothing pending" is only meaningful once the model has actually
        // produced its delegates. Before that, an empty pending set means
        // "nothing created yet", not "everything loaded" — checking this is
        // what stops the gate opening on the very first frame.
        if (!root._noIconsExpected && listView.count !== root.dockItems.length) return
        if (Object.keys(root._pendingIconKeys).length > 0) return
        root.iconsReady = true
    }

    onDockItemsChanged: Qt.callLater(root._checkIconGate)
    Connections {
        target: listView
        function onCountChanged() { Qt.callLater(root._checkIconGate) }
    }
    Connections {
        target: AppSearch
        function onReadyChanged() { Qt.callLater(root._checkIconGate) }
    }
    Connections {
        target: IconThemeService
        function on_IndexReadyChanged() { Qt.callLater(root._checkIconGate) }
    }

    // Pending launch focus (mock: Dock::m_pendingLaunchFocus, dock.cpp:1097).
    // It lives HERE, on the dock root, not on a delegate: when a pinned app's
    // first window appears its uniqueId flips from "pinned-<id>" to "app-<id>"
    // (_doRebuildDockItems), which destroys the delegate that started the
    // launch. State kept on the delegate would be dropped before the retry
    // could ever fire. Delegates read/write this via appListRoot so the retry
    // survives the hand-over.
    property var _pendingLaunch: null

    // Direct reactive binding to Config - will automatically trigger when Config changes
    readonly property bool separatePinnedFromRunning: Config.options?.dock?.separatePinnedFromRunning ?? true
    onSeparatePinnedFromRunningChanged: {
        root.rebuildDockItems()
    }

    // Cache compiled regexes - only recompile when config changes
    property var _cachedIgnoredRegexes: []
    property var _lastIgnoredRegexStrings: []

    function _getIgnoredRegexes(): list<var> {
        const ignoredRegexStrings = Config.options?.dock?.ignoredAppRegexes ?? [];
        // Check if we need to recompile
        if (JSON.stringify(ignoredRegexStrings) !== JSON.stringify(_lastIgnoredRegexStrings)) {
            const systemIgnored = ["^$", "^portal$", "^x-run-dialog$", "^kdialog$", "^org.freedesktop.impl.portal.*"];
            const allIgnored = ignoredRegexStrings.concat(systemIgnored);
            _cachedIgnoredRegexes = allIgnored.map(pattern => new RegExp(pattern, "i"));
            _lastIgnoredRegexStrings = ignoredRegexStrings.slice();
        }
        return _cachedIgnoredRegexes;
    }

    // ─── Synchronous rebuild ───────────────────────────────────────────
    // Called directly from signal handlers. The function is lightweight
    // (builds an entry array + equality check) and skips the model update
    // when dockItems hasn't structurally changed. No deferral needed.
    // Re-entrancy guard prevents recursive calls when a model update
    // triggered by this function fires a signal that would re-enter.
    property bool _rebuilding: false

    function rebuildDockItems() {
        if (root._rebuilding) return
        root._rebuilding = true
        // try/finally is load-bearing: _doRebuildDockItems() runs user-supplied
        // regexes from config, so a malformed pattern throws. Without this the
        // lock stays true and every later call returns at the guard above,
        // leaving the dock permanently frozen with no error and no recovery
        // short of a restart.
        try {
            root._doRebuildDockItems()
        } finally {
            root._rebuilding = false
        }
    }
    // ─── Drag-to-reorder (mock: dock_items.cpp computeDragTargetIndex /
    // applyDragVisuals, dock.cpp beginDrag/updateDrag/endDrag) ──────────
    // Number of leading model entries that are pinned. Drag arms only on these
    // and the drop target is an INSERT INDEX clamped to [0, pinnedCount];
    // everything after the pinned block is never dragged nor displaced.
    readonly property int pinnedCount: {
        let n = 0
        for (let i = 0; i < dockItems.length; i++) {
            const it = dockItems[i]
            if (!it || !it.pinned) break
            n++
        }
        return n
    }

    function _toplevelLiveKey(toplevel) {
        if (!toplevel) return ""
        if (toplevel._sourceKey !== undefined && toplevel._sourceKey !== null)
            return String(toplevel._sourceKey)
        return `${toplevel.appId || ""}::${toplevel.title || ""}`
    }

    // Skip model update when structure hasn't changed (same apps, order, toplevels).
    // Compare toplevels by stable identifier (sourceKey / appId+title) instead of
    // object reference — sortToplevels() on Niri builds fresh enriched objects on
    // every focus change, so reference comparison would always trigger a rebuild
    // and shake the dock layout for non-structural updates.
    function _dockItemsEqual(oldItems, newItems): bool {
        if (oldItems.length !== newItems.length) return false
        for (let i = 0; i < oldItems.length; i++) {
            const o = oldItems[i], n = newItems[i]
            if (o.uniqueId !== n.uniqueId || o.pinned !== n.pinned || o.section !== n.section) return false
            const oTL = o.toplevels, nTL = n.toplevels
            if (oTL.length !== nTL.length) return false
            for (let j = 0; j < oTL.length; j++) {
                if (root._toplevelLiveKey(oTL[j]) !== root._toplevelLiveKey(nTL[j])) return false
                // Under niri the activated flag flickers on plain focus moves,
                // so ignore it there — the focused-window key above already
                // carries the change. Elsewhere the flag is meaningful.
                if (!CompositorService.isNiri && !!oTL[j].activated !== !!nTL[j].activated) return false
            }
        }
        return true
    }

    // Config fingerprint for the clock entry — changing any clock setting
    // alters the entry's uniqueId so the model rebuilds and the clock
    // delegate is recreated with fresh values.
    function _clockFingerprint(): string {
        const c = Config.options?.dock?.clock ?? {}
        return [c.mode, c.showHour, c.showMinutes,
                c.hourSize, c.minuteSize, c.hourStretch, c.minuteStretch,
                c.hourColor, c.minuteColor,
                c.hourWeight, c.minuteWeight,
                c.hourAlign, c.minuteAlign,
                c.hourOffsetX, c.hourOffsetY, c.minuteOffsetX, c.minuteOffsetY,
                c.clockSpacing, c.analogBackground, c.analogSeconds,
                c.analogHandColor, c.analogSecondColor].join("|")
    }

    // ─── Clock enablement ────────────────────────────────────────────────
    // dock.clock.enabled is the clock's ONLY master switch. The clock is a
    // dock feature, not an application, so it no longer needs a magic string
    // in pinnedApps to exist at all: `enabled: true` alone puts it in the dock.
    //
    // "__clock__" in pinnedApps is the clock's POSITION slot. It cannot
    // re-enable a clock that the switch turned off — that would make the two
    // disagree, with no way to tell which one the user meant. Precedence:
    //   enabled:false                → no clock entry, ever
    //   enabled:true  + "__clock__"  → one entry, at its pinnedApps position
    //   enabled:true  + no sentinel  → one entry, at the dock's leading end
    // The sentinel also tells _applyClockReorder which pinnedApps slot a
    // clock drop writes back to.
    function _clockEnabled(): bool {
        return Config.options?.dock?.clock?.enabled === true
    }

    // Index of the "__clock__" anchor in pinnedApps, or -1 when the config
    // carries no sentinel. Used to keep the clock's model slot pointing at a
    // real config slot for drag-reorder write-back.
    function _clockAnchorIndex(pinnedApps): int {
        return Array.isArray(pinnedApps) ? pinnedApps.indexOf("__clock__") : -1
    }

    // The single clock model entry. Built by one function so `enabled` alone
    // and the legacy sentinel can never drift into two different shapes.
    function _clockEntry(order: int): var {
        return {
            uniqueId: "clock-" + root._clockFingerprint(),
            appId: "CLOCK",
            originalAppId: "__clock__",
            clockEntry: true,
            pinned: true,
            section: "pinned",
            toplevels: [],
            order: order
        }
    }

    function _doRebuildDockItems() {
        const pinnedApps = Config.options?.dock?.pinnedApps ?? [];
        const ignoredRegexes = _getIgnoredRegexes();
        const separatePinnedFromRunning = root.separatePinnedFromRunning;

        const tmToplevels = ToplevelManager.toplevels.values;
        const sorted = CompositorService.sortedToplevels;
        const sortedHasItems = sorted && sorted.length > 0;
        const niriAuthoritative = CompositorService.isNiri;
        const allToplevels = niriAuthoritative
            ? (sorted ?? [])
            : (sortedHasItems ? sorted : tmToplevels);

        // ─── Running apps (mock: app_identity::resolveRunningApps) ───
        // A window's app id (WM_CLASS) frequently differs from its .desktop
        // entry id ("spotify-launcher" → "spotify", AppImage binary names,
        // reverse-DNS ids, …). The mock resolves every running id onto its
        // desktop entry BEFORE building the model, so such a window folds into
        // the pinned item instead of producing a second dock icon. We key the
        // running map on the resolved desktop-entry id for the same reason;
        // without the resolution the pinned item and the running item diverge.
        const runningAppsMap = new Map();
        for (const toplevel of allToplevels) {
            if (!toplevel) continue
            if (!toplevel.appId) continue
            if (toplevel.appId === "" || toplevel.appId === "null") continue

            if (ignoredRegexes.some(re => re.test(toplevel.appId))) {
                continue;
            }

            const windowAppId = String(toplevel.appId)
            const desktopId = AppSearch.ready ? (AppSearch.lookupDesktopId(windowAppId) || "") : ""
            // Case-preserving resolved id for display/lookup, lowercased for the
            // map key. No desktop entry at all → fall back to the raw app id.
            const resolvedAppId = desktopId !== "" ? desktopId : windowAppId
            const lowerAppId = resolvedAppId.toLowerCase();

            if (!runningAppsMap.has(lowerAppId)) {
                runningAppsMap.set(lowerAppId, {
                    appId: resolvedAppId,
                    originalAppId: windowAppId,
                    toplevels: [],
                    pinned: false
                });
            }
            runningAppsMap.get(lowerAppId).toplevels.push(toplevel);
        }

        // showRunning (mock config_types.h:179 → dock_model.cpp:97/107):
        // when false, running apps that are NOT already listed as pinned are
        // never appended. Pinned entries keep merging their windows as usual.
        if (Config.options?.dock?.showRunning === false) {
            const pinnedLower = new Set();
            for (const p of pinnedApps) {
                if (p === "__clock__") continue;
                pinnedLower.add(String(p).toLowerCase());
            }
            for (const key of Array.from(runningAppsMap.keys())) {
                if (!pinnedLower.has(key)) runningAppsMap.delete(key)
            }
        }

        const values = [];
        let order = 0;

        // Model index → pinnedApps index, for the pinned section only. Built
        // alongside `values` so _applyInsertReorder can translate a drop target
        // back into a config slot. See _pinnedInsertIndex.
        const pinnedIndexMap = []

        // If separation is disabled, use legacy behavior: combine pinned with their running windows
        if (!separatePinnedFromRunning) {
            // The clock is NOT emitted here. "__clock__" in pinnedApps is a
            // config-time marker only: it no longer decides where the entry
            // renders, because a special (non-app) entry must flank the app
            // icons instead of sitting between them. The single clock entry is
            // emitted at the dock's outer edge once both branches have built
            // their sections — see the shared tail below.
            // Add all pinned apps (with or without windows)
            for (let pi = 0; pi < pinnedApps.length; pi++) {
                const appId = pinnedApps[pi]
                // "__clock__" is consumed as a config slot only. It must never
                // create a model entry at this position: that is exactly what
                // put the clock glyph mid-dock, on top of a neighbouring app
                // icon. The clock comes back at an end, enabled-gated.
                if (appId === "__clock__") {
                    continue
                }
                const lowerAppId = appId.toLowerCase();
                const runningEntry = runningAppsMap.get(lowerAppId);
                pinnedIndexMap[values.length] = pi
                values.push({
                    uniqueId: "app-" + lowerAppId,
                    appId: lowerAppId,
                    toplevels: runningEntry?.toplevels ?? [],
                    pinned: true,
                    originalAppId: appId,
                    section: "pinned",
                    order: order++
                });
                // Remove from running map so we don't add it again
                runningAppsMap.delete(lowerAppId);
            }

            // Add separator if there are both pinned and unpinned running apps
            if (Config.options?.dock?.showSeparator !== false && values.length > 0 && runningAppsMap.size > 0) {
                values.push({
                    uniqueId: "separator",
                    appId: "SEPARATOR",
                    toplevels: [],
                    pinned: false,
                    originalAppId: "SEPARATOR",
                    section: "separator",
                    order: order++
                });
            }

            // Add unpinned running apps in a stable alphabetical order so they
            // don't shuffle as sortedToplevels reorders on focus/layout changes.
            const unpinned = Array.from(runningAppsMap.entries())
                .sort((a, b) => a[0].localeCompare(b[0]));
            for (const [lowerAppId, entry] of unpinned) {
                values.push({
                    uniqueId: "app-" + lowerAppId,
                    appId: lowerAppId,
                    toplevels: entry.toplevels,
                    pinned: false,
                    originalAppId: entry.appId,
                    section: "open",
                    order: order++
                });
            }
        } else {
            // NEW BEHAVIOR: Separate pinned-only from running apps
            // 1) Add ONLY pinned apps (without running windows) - left section
            // Same rule as the legacy branch: the "__clock__" sentinel is
            // consumed as a config slot only, never emitted as a model entry
            // at its pinnedApps position. The clock is emitted once, at an
            // end of the dock, after both sections are built.
            for (let pi = 0; pi < pinnedApps.length; pi++) {
                const appId = pinnedApps[pi]
                // "__clock__" is consumed as a config slot only; it never
                // emits a model entry at its pinnedApps position. The clock
                // is emitted once at an end of the dock, enabled-gated.
                if (appId === "__clock__") {
                    continue
                }
                const lowerAppId = appId.toLowerCase();
                // Only show pinned apps that don't have running windows
                if (!runningAppsMap.has(lowerAppId)) {
                    // THIS is the branch where model index ≠ pinnedApps index:
                    // a pinned-but-running app is skipped here and shows up in
                    // the running section instead, shifting every later model
                    // slot down. Recording `pi` is what keeps a clock drop
                    // landing in the right config slot.
                    pinnedIndexMap[values.length] = pi
                    values.push({
                        uniqueId: "app-" + lowerAppId,
                        appId: lowerAppId,
                        toplevels: [],
                        pinned: true,
                        originalAppId: appId,
                        section: "pinned",
                        order: order++
                    });
                }
            }

            // 2) Add separator if there are both pinned-only apps and running apps
            const hasPinnedOnly = values.length > 0;
            const hasRunning = runningAppsMap.size > 0;

                if (hasPinnedOnly && hasRunning && Config.options?.dock?.showSeparator !== false) {
                values.push({
                    uniqueId: "separator",
                    appId: "SEPARATOR",
                    toplevels: [],
                    pinned: false,
                    originalAppId: "SEPARATOR",
                    section: "separator",
                    order: order++
                });
            }

            // 3) Add running apps (right section) - includes pinned apps that are also running
            const sortedRunningApps = [];
            for (const [lowerAppId, entry] of runningAppsMap) {
                sortedRunningApps.push({
                    lowerAppId: lowerAppId,
                    entry: entry
                });
            }
            // Sort to keep consistency: pinned+running apps first (by pinned order),
            // then unpinned apps in a STABLE alphabetical order. Without the
            // alphabetical fallback, unpinned apps inherit the iteration order of
            // sortedToplevels which can shuffle as windows are focused / moved
            // between columns, causing the dock icons to dance.
            sortedRunningApps.sort((a, b) => {
                const aIndex = pinnedApps.findIndex(p => p.toLowerCase() === a.lowerAppId);
                const bIndex = pinnedApps.findIndex(p => p.toLowerCase() === b.lowerAppId);

                const aIsPinned = aIndex !== -1;
                const bIsPinned = bIndex !== -1;

                if (aIsPinned && bIsPinned) return aIndex - bIndex;
                if (aIsPinned) return -1;
                if (bIsPinned) return 1;

                return a.lowerAppId.localeCompare(b.lowerAppId);
            });

            for (const {lowerAppId, entry} of sortedRunningApps) {
                values.push({
                    uniqueId: "app-" + lowerAppId,
                    appId: lowerAppId,
                    toplevels: entry.toplevels,
                    pinned: pinnedApps.some(p => p.toLowerCase() === lowerAppId),
                    originalAppId: entry.appId,
                    section: "running",
                    order: order++
                });
            }
        }

        // ─── Clock placement follows its "__clock__" slot ────────────────
        // The clock is a normal delegate with a normal cell, so it can sit
        // anywhere in the pinned section: it is inserted at the model slot
        // matching its pinnedApps position, which is what makes drag-reorder
        // stick. No sentinel yet → leading end (slot 0); the first drag
        // materialises one there via _applyClockReorder. Gating is solely
        // dock.clock.enabled; "__clock__" is only a position slot.
        if (root._clockEnabled()) {
            const anchor = root._clockAnchorIndex(pinnedApps)
            let insertPos = 0
            if (anchor >= 0) {
                // pinnedIndexMap covers exactly the pinned section in order,
                // so the slot is the count of pinned entries ahead of anchor.
                let before = 0
                for (let i = 0; i < pinnedIndexMap.length; i++) {
                    if (pinnedIndexMap[i] >= 0 && pinnedIndexMap[i] < anchor) before++
                }
                insertPos = Math.max(0, Math.min(before, pinnedIndexMap.length))
            }
            // pinnedIndexMap is indexed by model slot, so splicing here keeps
            // every app entry pointing at its own pinnedApps slot.
            pinnedIndexMap.splice(insertPos, 0, anchor)
            values.splice(insertPos, 0, root._clockEntry(0))
            // order stays dense and equal to the model index.
            for (let i = 0; i < values.length; i++) {
                values[i].order = i
            }
        }

        // Always refresh the reactive toplevel map, even when the model
        // structure is unchanged — delegates bind to it for live window state.
        const tlMap = {}
        for (const v of values) tlMap[v.uniqueId] = v.toplevels
        root.toplevelsByUniqueId = tlMap

        // Published UNCONDITIONALLY, outside the _dockItemsEqual guard below:
        // a config that drops the "__clock__" sentinel produces a byte-identical
        // model (the clock simply renders at the end of the pinned section
        // either way), yet the map's entry for that slot flips from a real
        // index to -1. Gating this on a model change would leave a stale slot
        // behind and send the next clock drop to the wrong position.
        root._pinnedIndexMap = pinnedIndexMap

        if (!_dockItemsEqual(dockItems, values)) {
            dockItems = values
        }
    }

    Component.onCompleted: {
        rebuildDockItems()
        // Deferred: the model above has only just been handed its values, so
        // listView.count is not yet meaningful when this runs synchronously.
        Qt.callLater(root._checkIconGate)
    }

    // External config edits (config.json hot-reload) fire configChanged; the
    // clock entry's uniqueId embeds a clock-config fingerprint, so a rebuild
    // recreates the clock delegate with fresh values. Non-clock edits compare
    // equal in _dockItemsEqual and skip the model update.
    Connections {
        target: Config
        function onConfigChanged() {
            root.rebuildDockItems()
        }
    }

    // Rebuild when the toplevel list changes (windows open/close) or when the
    // active toplevel changes (focus switch) so the dock model stays in sync.
    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() {
            root.rebuildDockItems()
        }
    }

    // ─── Pages container ─────────────────────────────────────────────
    // Holds both pages side-by-side. _contentOffset slides this container so
    // exactly one page shows at a time.
    //
    // It keeps clipping (that is what bounds the page swipe), but is grown by
    // the hover-zoom pad on BOTH axes so a magnified/active icon can overhang
    // the pill on any side — the mock paints icons outside the pill and reserves
    // that room in the surface (dockHoverZoomCrossPad / MainPad). Without the
    // main-axis slack the dock's left/right ends clip the outermost icons.
    //
    // Use the larger of the two pads so whichever side the icon grows toward has
    // room; the cross pad covers the dock-edge axis and the main pad the ends.
    readonly property real _zoomSlack: Math.max(
        root.parentWindow?.zoomCrossPad ?? 0,
        root.parentWindow?.zoomMainPad ?? 0)
    Item {
        id: pagesContainer
        clip: true
        // The container is grown by the slack on BOTH axes, and page 0's content
        // is offset back INSIDE it by the same amount. Net effect: page 0 stays
        // exactly where it was (still centred on the pill and aligned with the
        // swipe snap positions), while transparent room opens up outside the
        // dock's ends for enlarged icons to overhang into.
        x: root.vertical ? -root._zoomSlack : -root._contentOffset - root._zoomSlack
        y: root.vertical ? -root._contentOffset - root._zoomSlack : -root._zoomSlack
        // Per axis: the PAGING axis is _pageSize * _pageCount (plus slack), the
        // other axis is the dock's own extent (plus slack). Both get slack.
        width: root.vertical ? root.width + 2 * root._zoomSlack : root._pageSize * root._pageCount + 2 * root._zoomSlack
        height: root.vertical ? root._pageSize * root._pageCount + 2 * root._zoomSlack : root.height + 2 * root._zoomSlack

    StyledListView {
        id: listView
        spacing: Config.options?.dock?.spacing ?? 2
        orientation: root.vertical ? ListView.Vertical : ListView.Horizontal
        // A "start" launcher owns the row origin, so the items are pushed past
        // it by one cell + spacing — the flex row's leading child. "end" needs
        // no offset. This is the same length implicitWidth adds back.
        // +_zoomSlack undoes the container's outward shift so page 0 content
        // still sits exactly where the pill and the swipe snap positions expect.
        x: root.vertical ? root._zoomSlack : (root._zoomSlack + (root._launcherAtStart ? root._launcherExtent : 0))
        y: root.vertical ? (root._zoomSlack + (root._launcherAtStart ? root._launcherExtent : 0)) : root._zoomSlack
        // Page 0 stays EXACTLY root-sized inside the padded container. Using
        // parent.* (which now includes the zoom slack) would centre the row in
        // an oversized box and shift the icons down by the slack.
        width: root.vertical ? root.width : root._pageSize
        height: root.vertical ? root._pageSize : root.height
        interactive: false // Dock should never flick/scroll — all items visible

        // ─── Item entrance / exit transitions ───
        // The new/leaving item fades in place. Neighbours are intentionally NOT
        // animated: the layout refits immediately and the container's
        // implicitWidth/Height Behavior smooths the overall dock resize.
        // Animations are suppressed during a manual reorder drag so they never
        // fight drag transforms.
        //
        // TIMING: both transitions deliberately read elementResize — the SAME
        // preset that animates DockApps.implicitWidth, and therefore the pill.
        // They used to read elementMoveEnter (280 ms) and elementMoveExit
        // (220 ms), which put the icon fade on its own clock:
        //   - both presets were `type: Easing.BezierSpline` with the curve held
        //     in a `var`, so the curve never reached QEasingCurve and both ran
        //     LINEAR, while the pill ran OutQuint;
        //   - the icon therefore finished ~133 ms AFTER the pill had already
        //     settled (measured: pill settled 145-168 ms, icon reached full
        //     opacity 278-301 ms, on the same 4 ms clock).
        // Sharing one duration AND one easing makes the icon arrive with the
        // pill instead of trailing it. `elementMove`/`elementMoveFast` are left
        // alone: they drive hover, scale and drag, which are not part of this
        // resize and should not inherit the resize's easing.
        readonly property bool _animOk: Appearance.animationsEnabled && !root.dragActive

        populate: Transition {} // instant on startup; add/remove handle app open/close
        add: Transition {
            enabled: listView._animOk
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Appearance.animation.elementResize.duration; easing.type: Appearance.animation.elementResize.type }
        }
        remove: Transition {
            enabled: listView._animOk
            NumberAnimation { property: "opacity"; to: 0; duration: Appearance.animation.elementResize.duration; easing.type: Appearance.animation.elementResize.type }
        }
        displaced: Transition {
            enabled: listView._animOk
            NumberAnimation {
                property: root.vertical ? "y" : "x"
                duration: Appearance.animation.elementResize.duration
                easing.type: Appearance.animation.elementResize.type
            }
        }
        addDisplaced: displaced
        removeDisplaced: displaced
        move: Transition {}
        moveDisplaced: Transition {}

        model: ScriptModel {
            objectProp: "uniqueId"
            values: root.dockItems
        }

          delegate: DockAppButton {
              id: dockDelegate
              required property var modelData
              required property int index
              appToplevel: modelData
              appListRoot: root
              listIndex:   index
              vertical: root.vertical
              dockPosition: root.dockPosition
              iconSize: root.effectiveIconSize

              anchors.verticalCenter: !root.vertical ? parent?.verticalCenter : undefined
              anchors.horizontalCenter: root.vertical ? parent?.horizontalCenter : undefined

              // Sin insets - el tamaño viene del DockButton
              topInset: 0
              bottomInset: 0
              leftInset: 0
              rightInset: 0

               onButtonHoveredChanged: {
                   if (root._magnifyActive) {
                       if (buttonHovered) {
                           macHoverResetTimer.stop()
                           root.macHoveredIndex = index
                       } else {
                           macHoverResetTimer.restart()
                       }
                   }
               }

            // ─── Drag & Drop Properties ──────────────────────────────
            readonly property bool isBeingDragged: root.dragActive && root.dragIndex === index
            // dropTargetIndex is an INSERT INDEX in [0, pinnedCount]; the line
            // rides the item the gap opens in front of (nothing at the very end).
            readonly property bool isDropTarget: root.dragActive
                && root.dropTargetIndex === index
                && index < root.pinnedCount
                && root.dragIndex !== index
            readonly property bool isDropSettling: !isBeingDragged && root.dropSettleId !== "" && root.dropSettleId === appToplevel?.uniqueId
            readonly property real dragDisplacement: root.getDragDisplacement(index)

            // Visual offset when being dragged
            property real _dragOffsetX: isBeingDragged ? (root.dragCurrentX - root.dragStartX) : 0
            property real _dragOffsetY: isBeingDragged ? (root.dragCurrentY - root.dragStartY) : 0

            // Apply displacement transform for non-dragged items during reorder
            transform: [
                // Drag / drop-settle displacement (existing behaviour, unchanged).
                Translate {
                x: dockDelegate.isBeingDragged
                    ? (root.vertical ? 0 : dockDelegate._dragOffsetX)
                    : dockDelegate.isDropSettling
                        ? (root.vertical ? 0 : root.dropSettleOffsetX)
                        : (root.vertical ? 0 : dockDelegate.dragDisplacement)
                y: dockDelegate.isBeingDragged
                    ? (root.vertical ? dockDelegate._dragOffsetY : 0)
                    : dockDelegate.isDropSettling
                        ? (root.vertical ? root.dropSettleOffsetY : 0)
                        : (root.vertical ? dockDelegate.dragDisplacement : 0)

                Behavior on x {
                    enabled: Appearance.animationsEnabled && !root.dropSettlingActive && !dockDelegate.isBeingDragged && !dockDelegate.isDropSettling
                    NumberAnimation {
                        duration: Appearance.animation.elementResize.duration
                        easing.type: Appearance.animation.elementResize.type
                    }
                }
                Behavior on y {
                    enabled: Appearance.animationsEnabled && !root.dropSettlingActive && !dockDelegate.isBeingDragged && !dockDelegate.isDropSettling
                    NumberAnimation {
                        duration: Appearance.animation.elementResize.duration
                        easing.type: Appearance.animation.elementResize.type
                    }
                }
                },

                // Magnification displacement (mock: applyItemMainOffset).
                // Listed after the drag translate so a drag always wins.
                Translate {
                    x: root.vertical ? 0 : root.magnifyOffsetAt(index)
                    y: root.vertical ? root.magnifyOffsetAt(index) : 0
                }
            ]

            // Magnification owns the icon's own scale (applied in
            // DockAppButton on the icon container, like the mock's
            // applyHoverIconScale) — it deliberately does NOT scale the cell,
            // so the hover background and shadow keep their rest size.
            readonly property real magnifyMultiplier: root._magnifyActive && !isSeparator
                ? root.magnifyScaleAt(index)
                : 1.0

            // Elevated z-order when dragging; otherwise a magnified icon must
            // paint above its neighbours (mock: applyHoverZoomZIndex).
            z: isBeingDragged ? 200 : Math.round(magnifyMultiplier * 100)

            // Active/inactive base scale (mock: iconScale = active ? activeScale
            // : inactiveScale). Magnification multiplies this, never replaces it.
            scale: isBeingDragged ? 1.08
                 : (dockDelegate.appIsActive ? (Config.options?.dock?.activeScale ?? 1.0)
                                             : (Config.options?.dock?.inactiveScale ?? 0.85))
            Behavior on scale {
                enabled: Appearance.animationsEnabled
                animation: NumberAnimation {
                    duration: Appearance.animation.elementMoveFast.duration
                    easing.type: Appearance.animation.elementMoveFast.type
                }
            }

            // Mock: applyDragVisuals dims ONLY the dragged icon (0.85); every
            // other item keeps its normal opacity during a reorder.
            opacity: isBeingDragged ? 0.85 : 1.0
            Behavior on opacity {
                enabled: Appearance.animationsEnabled
                NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
            }

            // ─── Insertion line at drop gap ───────────────────────────
            // Thin accent line centered in the gap that displacement opens.
            // Direction-aware: shows at the edge facing the gap so it
            // visually marks the exact insertion point.
            Rectangle {
                visible: dockDelegate.isDropTarget && !dockDelegate.isSeparator
                z: 50

                // Which direction the item is being dragged
                readonly property bool forward: root.dragIndex >= 0
                    && root.dragIndex < root.dropTargetIndex

                // Horizontal dock → vertical line; vertical dock → horizontal line
                width: root.vertical ? (parent.width * 0.55) : 3
                height: root.vertical ? 3 : (parent.height * 0.55)
                radius: 1.5

                // Position: center the line in the spacing gap at the correct edge
                x: root.vertical
                    ? (parent.width - width) / 2
                    : (forward
                        ? parent.width + (listView.spacing - width) / 2
                        : -(listView.spacing + width) / 2)
                y: root.vertical
                    ? (forward
                        ? parent.height + (listView.spacing - height) / 2
                        : -(listView.spacing + height) / 2)
                    : (parent.height - height) / 2

                color: Appearance.colors.colPrimary

                opacity: dockDelegate.isDropTarget ? 0.9 : 0

                Behavior on opacity {
                    enabled: Appearance.animationsEnabled
                    NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
                }
            }

            // ─── Drag detection: "prime + move" pattern ──────────────
            // 1. Press  → start short timer (180ms)
            // 2. Timer  → silently "prime" (no visual change)
            // 3. Move after primed → drag starts INSTANTLY
            // 4. Release before moving → normal click
            // This feels snappy because the user is usually already
            // moving when the timer fires, so drag begins at ~180ms.
            property real _pressMouseX: 0
            property real _pressMouseY: 0
            property bool _hasPressPos: false
            // Peak squared displacement from the press origin, over the whole
            // press. `wasArmed` alone is not evidence of a drag — a touchpad
            // tap can outlive `_dockPrimeTimer` while never travelling — so
            // this, not the timer, decides whether a click is suppressed.
            property real _pressMaxDist2: 0
            property bool _dragPrimed: false      // Timer fired, awaiting movement
            property bool _longPressTriggered: false // Drag actually started

            downAction: () => {
                // Mock: drag arms on press of a PINNED item only; separators and
                // running-but-unpinned items ignore drag entirely.
                if (!root.dragEnabled || dockDelegate.isSeparator) return
                if (index < 0 || index >= root.pinnedCount) return
                root.cancelPageSnap()  // Stop any in-progress page snap animation
                _longPressTriggered = false
                _dragPrimed = false
                _hasPressPos = false
                _pressMaxDist2 = 0
                _dockPrimeTimer.restart()
            }

            moveAction: (event) => {
                // Only track during an active press, not hover
                if (!dockDelegate.down) return

                // Capture initial press position on first move event
                if (!_hasPressPos) {
                    _pressMouseX = event.x
                    _pressMouseY = event.y
                    _hasPressPos = true
                    return
                }

                const dx = event.x - _pressMouseX
                const dy = event.y - _pressMouseY
                const dist2 = dx * dx + dy * dy
                // Remember the furthest this press ever got from its origin.
                // Tracked on every move, before any early return, so a press
                // that drifts out and back still records the travel it did.
                if (dist2 > dockDelegate._pressMaxDist2)
                    dockDelegate._pressMaxDist2 = dist2


                // ── Page swipe detection ──────────────────────────────
                // If movement is primarily in the swipe direction and
                // exceeds threshold, start page navigation instead of
                // app drag or long-press.
                if (!root._gestureActive && !root.dragActive && !_longPressTriggered) {
                    const swipeDelta = root.vertical ? dy : dx
                    const perpDelta  = root.vertical ? dx : dy
                    if (dist2 > root.swipeArmThreshold * root.swipeArmThreshold
                            && Math.abs(swipeDelta) > Math.abs(perpDelta)) {
                        _dockPrimeTimer.stop()
                        root._gestureActive = true
                        root._gestureStartPos = root.vertical ? _pressMouseY : _pressMouseX
                        root._gestureCumulative = 0
                        root._gestureOriginPage = root._currentPage
                        root.cancelPageSnap()
                        root._suppressNextClick = true
                    }
                }

                // If page swipe is active, update content offset
                if (root._gestureActive) {
                    const currentPos = root.vertical ? event.y : event.x
                    root._gestureCumulative = currentPos - root._gestureStartPos
                    const base = root._gestureOriginPage * root._pageSize
                    const raw = base - root._gestureCumulative * root._swipeSensitivity
                    const maxOffset = (root._pageCount - 1) * root._pageSize
                    root._contentOffset = Math.max(0, Math.min(raw, maxOffset))
                    return
                }

                // Before primed: cancel if mouse drifts too far (user is swiping, not holding)
                if (_dockPrimeTimer.running && !_dragPrimed) {
                    if (dist2 > root.dragThreshold * root.dragThreshold) {
                        _dockPrimeTimer.stop()
                    }
                    return
                }

                // Primed but drag not yet started → start on first movement
                if (_dragPrimed && !root.dragActive) {
                    _longPressTriggered = true
                    const listPos = dockDelegate.mapToItem(listView, _pressMouseX, _pressMouseY)
                    const appId = dockDelegate.appToplevel?.originalAppId
                        ?? dockDelegate.appToplevel?.appId ?? ""
                    root.startDrag(dockDelegate.index, appId, listPos.x, listPos.y)
                    // Fall through to immediately update with current position
                }

                // Forward mouse position during active drag
                if (root.dragActive && root.dragIndex === dockDelegate.index) {
                    const listPos = dockDelegate.mapToItem(listView, event.x, event.y)
                    root.updateDrag(listPos.x, listPos.y)
                }
            }

            releaseAction: () => {
                _dockPrimeTimer.stop()
                // Arming alone is NOT a drag. `_dockPrimeTimer` fires at 180 ms,
                // squarely inside the 100–250 ms a touchpad tap lasts, so a
                // plain tap used to land here with `wasArmed === true` and
                // suppress its own click — one tap did nothing, and only the
                // second, faster tap from a settled pointer got through.
                // A press only counts as a drag if the pointer actually
                // travelled past `jitterTolerance`.
                const wasArmed = _dragPrimed
                _dragPrimed = false
                // `wasArmed` scopes this to presses this delegate actually
                // armed: separators and unpinned running items never restart
                // the prime timer, so a stray wander on them must not start
                // suppressing their clicks.
                const movedBeyondJitter = wasArmed
                    && dockDelegate._pressMaxDist2 > root.jitterTolerance * root.jitterTolerance
                dockDelegate._pressMaxDist2 = 0

                // End page swipe if active
                if (root._gestureActive) {
                    root._gestureActive = false
                    const offset = root._gestureCumulative
                    const absOffset = Math.abs(offset)
                    const threshold = root._pageSize * root._swipeThreshold
                    if (offset < 0 && absOffset > threshold && root._currentPage < root._pageCount - 1) {
                        root.snapToPage(root._currentPage + 1)
                    } else if (offset > 0 && absOffset > threshold && root._currentPage > 0) {
                        root.snapToPage(root._currentPage - 1)
                    } else {
                        root.snapToPage(root._currentPage)
                    }
                    root._suppressNextClick = true
                    return
                }

                if (dockDelegate._longPressTriggered) {
                    // Drag was active — end it and suppress the click()
                    // that RippleButton fires right after releaseAction.
                    if (root.dragActive && root.dragIndex === dockDelegate.index) {
                        root.endDrag()
                    }
                    root._suppressNextClick = true
                    dockDelegate._longPressTriggered = false
                } else if (movedBeyondJitter) {
                    // Armed, and the pointer genuinely travelled — but the
                    // drag never started (e.g. it left the item). Still a
                    // gesture, so still no launch.
                    root._suppressNextClick = true
                }
            }

            Timer {
                id: _dockPrimeTimer
                interval: 180  // Short: just enough to distinguish from a quick click
                onTriggered: {
                    dockDelegate._dragPrimed = true
                    // No visual change yet — drag starts on first movement
                }
            }

            // Connect hover preview signals
            onHoverPreviewRequested: {
                if (!root.dragActive) {
                    root.showPreviewPopup(appToplevel, this)
                }
            }
            onHoverPreviewDismissed: {
                dockPreviewPopup.close()
            }
        }
    }

    // ─── Launcher button ────────────────────────────────────────────────
    // Mock: `if (launcher_position == Start) row->addChild(createLauncherButton(...))`
    // before the item loop and the mirrored `End` check after it. A sibling of
    // the ListView reproduces both placements exactly: "start" pins it to the
    // row origin, "end" puts it one spacing-gap past the last item. It has no
    // index, so startDrag/getDragDisplacement can never select it, and it is not
    // in dockItems, so the magnify frame loop (which iterates dockItems) ignores
    // it — the mock gives the launcher a fixed inactive scale for the same
    // reason.
    DockLauncherButton {
        visible: root._launcherVisible
        enabled: root._launcherVisible
        z: 10
        vertical: root.vertical
        dockPosition: root.dockPosition
        iconSize: root.effectiveIconSize

        // Same cross-axis centring the delegates use, so the launcher cell lines
        // up with every other cell in both orientations.
        anchors.verticalCenter: !root.vertical ? parent.verticalCenter : undefined
        anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined

        // Main axis. The anchors above own the cross axis and simply win over
        // these coordinates, so both are always assigned a real number (an
        // `undefined` assignment logs a scene warning and deletes the property).
        x: root.vertical ? 0 : (root._launcherAtStart
            ? 0
            : listView.contentWidth + listView.spacing)
        y: root.vertical ? (root._launcherAtStart
            ? 0
            : listView.contentHeight + listView.spacing) : 0

        // DockApps deliberately never sets appListRoot/macHoveredIndex here: the
        // launcher has no windows, so there is no hover preview, and it has no
        // model index, so it must not claim the magnify hover slot.
        onLauncherRequested: {
            // No launcher IPC in this build — see DockLauncherButton for why.
        }
    }
    // Layout self-heal: after an app open/close or config change the ListView
    // can settle with a stale layout (ghost slot, delegate held by a removed
    // transition), visible as the icon column ending short of the dock edge
    // until restart. If the live layout disagrees with the model-derived
    // expectation for two consecutive seconds, re-sync from the live toplevel
    // list and force a relayout. Comparisons are cheap; the force paths run at
    // most once per incident.
    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: if (typeof root._verifyLayoutHealth === "function") root._verifyLayoutHealth()
    }
    property int _healStrikes: 0
    // Reference geometry, used for diagnostics only — never for health decisions.
    // It cannot be exact: a separator contributes separatorSize along the main axis
    // (8 across it), a normal button contributes the peak-adjusted cell, and horizontal docks
    // further subtract button insets that live on DockButton and are unreachable here.
    function _expectedContentLength(): real {
        const n = dockItems.length
        if (n === 0) return 0
        const button = root._cellMain
        const sep = Math.max(1, (Config.options?.dock?.height ?? 70) - button)
        let total = 0
        for (const item of dockItems) {
            const isSeparator = item?.section === "separator" || item?.uniqueId === "separator"
            total += root.vertical ? (isSeparator ? sep : button) : (isSeparator ? 8 : button)
        }
        return total + (n - 1) * (Config.options?.dock?.spacing ?? 2)
    }
    function _verifyLayoutHealth(): void {
        const live = root.vertical ? listView.contentHeight : listView.contentWidth
        const countOk = listView.count === dockItems.length
        // Deliberately coarse. The previous check demanded the live length match
        // _expectedContentLength() within 1px, but that formula ignored separators
        // entirely — so with showSeparator enabled it never matched, the watchdog
        // fired every second and drove a permanent ScriptModel re-sync loop.
        // The count check is exact and geometry-free; the length check now only
        // catches a genuinely stuck layout sitting at zero extent.
        const lenOk = dockItems.length === 0 || live > 0
        if (countOk && lenOk) {
            _healStrikes = 0
            return
        }
        _healStrikes++
        console.info("[dock-heal] mismatch strike", _healStrikes,
            "count", listView.count, "expected", dockItems.length,
            "live", live.toFixed(1), "expected", _expectedContentLength().toFixed(1))
        if (_healStrikes === 1) {
            rebuildDockItems()      // refresh model from live toplevel list
            return
        }
        dockItems = dockItems.slice()  // new array identity forces ScriptModel re-sync
        listView.forceLayout()
        _healStrikes = 0
    }

    // Page 1: System controls (WiFi, Bluetooth, Audio, Power)
    DockControls {
        // REVERTED to the original two-term binding. An earlier revision added
        // `|| root._gestureActive` to keep the page alive for the duration of a
        // swipe, but _gestureActive is only cleared in the release/cancel
        // handlers — so a reload, a cancel that never fires them, or any press
        // that arms the gesture without a matching release leaves it stuck
        // true, and the controls then render on top of page 0 permanently.
        // That is worse than the mid-swipe flicker it was meant to prevent.
        visible: root._currentPage === 1 || root._contentOffset > 0
        appListRoot: root
        // Same _zoomSlack offset as page 0 so the swipe step stays one _pageSize.
        x: root.vertical ? root._zoomSlack : root._pageSize + root._zoomSlack
        y: root.vertical ? root._pageSize + root._zoomSlack : root._zoomSlack
        width: root.vertical ? parent.width : root._pageSize
        height: root.vertical ? root._pageSize : parent.height
    }

    } // pagesContainer

    // ─── Page Swipe Gesture Handler ─────────────────────────────────────
    // Follow-finger swipe navigation. Uses a MouseArea with drag detection
    // to distinguish swipes from taps. When a swipe is detected (movement
    // exceeds threshold), the page offset is updated directly. Taps pass
    // through to DockAppButton delegates via propagateComposedEvents.
    MouseArea {
        id: pageSwipeArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        hoverEnabled: false
        // Let press events propagate to child MouseAreas (buttons).
        // We only track position for swipe detection in empty space.
        propagateComposedEvents: true

        property real _pressX: 0
        property real _pressY: 0
        property bool _tracking: false

        onPressed: (mouse) => {
            // `_suppressNextClick` is cleared ONLY by DockAppButton.onClicked,
            // and a click() is only ever emitted for a press that landed on a
            // delegate. Two everyday paths set the flag without one following:
            //
            //  - a flick that starts over dead space (the 6 px band above and
            //    below an 80 px icon inside the 92 px pill, the spacing gap
            //    between cells, the launcher cell) — this area arms the swipe
            //    at onPositionChanged below and nothing ever consumes it;
            //  - a drag-reorder: releaseAction sets the flag AFTER endDrag(),
            //    and endDrag() reorders the model synchronously, so the
            //    delegate whose click() would consume it is already destroyed.
            //
            // Either way the flag outlives its press and silently swallows the
            // user's NEXT click, which is what makes the icons look dead. A new
            // press can never be the tail of an older gesture, so reset it
            // here: the suppression for THIS press is (re)armed further down,
            // by the movement handlers.
            root._suppressNextClick = false
            if (root.dragActive || root._pageCount <= 1) return
            _pressX = mouse.x
            _pressY = mouse.y
            _tracking = true
            mouse.accepted = false
        }

        onPositionChanged: (mouse) => {
            if (!_tracking) return

            const dx = mouse.x - _pressX
            const dy = mouse.y - _pressY
            const dist2 = dx * dx + dy * dy

            // Only start page swipe if movement is clearly in swipe direction
            // and exceeds threshold — otherwise let the child button handle it
            if (!root._gestureActive) {
                const swipeDelta = root.vertical ? dy : dx
                const perpDelta  = root.vertical ? dx : dy
                if (dist2 > root.swipeArmThreshold * root.swipeArmThreshold
                    && Math.abs(swipeDelta) > Math.abs(perpDelta)) {
                    root._gestureActive = true
                    root._gestureStartPos = root.vertical ? _pressY : _pressX
                    root._gestureCumulative = 0
                    root._gestureOriginPage = root._currentPage
                    root.cancelPageSnap()
                    root._suppressNextClick = true
                }
            }

            if (root._gestureActive) {
                const currentPos = root.vertical ? mouse.y : mouse.x
                root._gestureCumulative = currentPos - root._gestureStartPos

                const base = root._gestureOriginPage * root._pageSize
                const raw = base - root._gestureCumulative * root._swipeSensitivity
                const maxOffset = (root._pageCount - 1) * root._pageSize
                root._contentOffset = Math.max(0, Math.min(raw, maxOffset))
            }

            mouse.accepted = false
        }

        onReleased: (mouse) => {
            _tracking = false
            if (root._gestureActive) {
                root._gestureActive = false

                const offset = root._gestureCumulative
                const absOffset = Math.abs(offset)
                const threshold = root._pageSize * root._swipeThreshold

                if (offset < 0 && absOffset > threshold && root._currentPage < root._pageCount - 1) {
                    root.snapToPage(root._currentPage + 1)
                } else if (offset > 0 && absOffset > threshold && root._currentPage > 0) {
                    root.snapToPage(root._currentPage - 1)
                } else {
                    root.snapToPage(root._currentPage)
                }
            }
            mouse.accepted = false
        }

        onCanceled: {
            _tracking = false
            if (root._gestureActive) {
                root._gestureActive = false
                root.snapToPage(root._currentPage)
            }
        }
    }

    // New Waffle-style preview popup
    DockPreview {
        id: dockPreviewPopup
        dockHovered: root.buttonHovered
        dockPosition: root.dockPosition
        anchor.window: root.parentWindow
    }

}
