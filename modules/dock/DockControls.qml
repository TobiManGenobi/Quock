import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services.Audio
import qs.services.Network
import qs.services.Power
import QtQuick
import QtQuick.Layouts
import Quickshell

// Control center page for the vertical dock.
// Displays a vertical column of system toggle buttons accessible by swiping
// from the app icons page. Each button matches the size of an app icon
// button: same iconSize and buttonSize from dock config.
Item {
    id: root
    clip: true

    readonly property real iconSize: Config.options?.dock?.iconSize ?? 35
    readonly property real buttonSize: Math.max(50, iconSize + 12)
    readonly property string _bgSource: Qt.resolvedUrl("toggle-bg.svg")

    // Reference to the DockApps root for page swipe state
    property var appListRoot: null
    // The button under the pointer, tracked by hoverHandler below.
    // swipeGuard (z: 100) covers every button, so the buttons' own internal
    // MouseArea never sees the pointer and RippleButton.buttonHovered stays
    // false. Hover state has to be driven from here instead.
    property Item _hoverButton: null
    // Orientation comes from the pager that mounts this page, so the same
    // component can spread its buttons along the dock's MAIN axis.
    readonly property bool vertical: appListRoot?.vertical ?? false


    // Controls used to be a `Grid` with `anchors.centerIn: parent`: one
    // column, centred inside a page that is exactly `_pageSize` wide — i.e.
    // the full dock width. That put the whole control stack, the volume glyph
    // included, on the dock's horizontal centre line, right where the app icon
    // row sits, so the glyphs overlapped an app icon.
    //
    // They are laid out along the dock's MAIN axis instead and pinned to its
    // two ends: volume at the leading end, lock at the trailing end, with the
    // remaining toggles sharing the middle. `Layout.fillWidth` makes each cell
    // take a full column, and `Layout.alignment` then pins the button to that
    // cell's outer edge — so the positions below are resolved against the
    // dock's own width, not against a centred stack.
    GridLayout {
        id: grid
        anchors.fill: parent
        columns: root.vertical ? 1 : 4
        rowSpacing: 5
        columnSpacing: 5

        // ── Audio / Mute Toggle ──────────────────────────────────────
        RippleButton {
            id: volBtn
            // The volume glyph is pinned to the dock's LEADING END: it now
            // sits at x == 0 of the page, not on the dock's centre line.
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter

            implicitWidth: root.buttonSize
            implicitHeight: root.buttonSize
            buttonRadius: Appearance.rounding.normal
            colBackground: "transparent"
            colBackgroundHover: "transparent"
            colRipple: Appearance.colors.colLayer0Active

            Image {
                anchors.centerIn: parent
                source: root._bgSource
                sourceSize.width: root.buttonSize
                sourceSize.height: root.buttonSize
                opacity: 0.35
                z: -2
            }

            Rectangle {
                anchors.fill: parent
                visible: root._hoverButton === volBtn
                color: Appearance.colors.colLayer0Hover
                radius: parent.buttonEffectiveRadius
                z: -1
            }

            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                iconSize: root.iconSize
                text: AudioService.muted ? "volume_off" : "volume_up"
                color: AudioService.muted
                    ? ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.5)
                    : Appearance.colors.colPrimary

                Behavior on color {
                    enabled: Appearance.animationsEnabled
                    ColorAnimation {
                        duration: Appearance.animation.elementMoveFast.duration
                        easing.type: Appearance.animation.elementMoveFast.type
                    }
                }
            }

            onClicked: AudioService.toggleMute()
        }

        // ── WiFi Toggle ─────────────────────────────────────────────
        RippleButton {
            id: wifiBtn
            // Middle cluster: aligned so wifi+bluetooth still meet at the
            // dock's centre line, exactly as the old centred column had them.
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter

            implicitWidth: root.buttonSize
            implicitHeight: root.buttonSize
            buttonRadius: Appearance.rounding.normal
            colBackground: "transparent"
            colBackgroundHover: "transparent"
            colRipple: Appearance.colors.colLayer0Active

            Image {
                anchors.centerIn: parent
                source: root._bgSource
                sourceSize.width: root.buttonSize
                sourceSize.height: root.buttonSize
                opacity: 0.35
                z: -2
            }

            Rectangle {
                anchors.fill: parent
                visible: root._hoverButton === wifiBtn
                color: Appearance.colors.colLayer0Hover
                radius: parent.buttonEffectiveRadius
                z: -1
            }

            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                iconSize: root.iconSize
                text: WifiService.enabled ? "wifi" : "wifi_off"
                color: WifiService.enabled
                    ? Appearance.colors.colPrimary
                    : ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.5)

                Behavior on color {
                    enabled: Appearance.animationsEnabled
                    ColorAnimation {
                        duration: Appearance.animation.elementMoveFast.duration
                        easing.type: Appearance.animation.elementMoveFast.type
                    }
                }
            }

            onClicked: WifiService.toggle()
        }

        // ── Bluetooth Toggle ─────────────────────────────────────────
        RippleButton {
            id: btBtn
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter
            implicitWidth: root.buttonSize
            implicitHeight: root.buttonSize
            buttonRadius: Appearance.rounding.normal
            colBackground: "transparent"
            colBackgroundHover: "transparent"
            colRipple: Appearance.colors.colLayer0Active

            Image {
                anchors.centerIn: parent
                source: root._bgSource
                sourceSize.width: root.buttonSize
                sourceSize.height: root.buttonSize
                opacity: 0.35
                z: -2
            }

            Rectangle {
                anchors.fill: parent
                visible: root._hoverButton === btBtn
                color: Appearance.colors.colLayer0Hover
                radius: parent.buttonEffectiveRadius
                z: -1
            }

            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                iconSize: root.iconSize
                text: BluetoothService.enabled ? "bluetooth" : "bluetooth_disabled"
                color: BluetoothService.enabled
                    ? Appearance.colors.colPrimary
                    : ColorUtils.transparentize(Appearance.colors.colOnLayer0, 0.5)

                Behavior on color {
                    enabled: Appearance.animationsEnabled
                    ColorAnimation {
                        duration: Appearance.animation.elementMoveFast.duration
                        easing.type: Appearance.animation.elementMoveFast.type
                    }
                }
            }

            onClicked: BluetoothService.toggle()
        }

        // ── Power / Lock ─────────────────────────────────────────────
        RippleButton {
            id: lockBtn
            // Trailing end, mirroring volBtn at the leading end.
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
            implicitWidth: root.buttonSize
            implicitHeight: root.buttonSize
            buttonRadius: Appearance.rounding.normal
            colBackground: "transparent"
            colBackgroundHover: "transparent"
            colRipple: Appearance.colors.colLayer0Active

            Image {
                anchors.centerIn: parent
                source: root._bgSource
                sourceSize.width: root.buttonSize
                sourceSize.height: root.buttonSize
                opacity: 0.35
                z: -2
            }

            Rectangle {
                anchors.fill: parent
                visible: root._hoverButton === lockBtn
                color: Appearance.colors.colLayer0Hover
                radius: parent.buttonEffectiveRadius
                z: -1
            }

            contentItem: MaterialSymbol {
                anchors.centerIn: parent
                iconSize: root.iconSize
                text: "lock"
                color: Appearance.colors.colOnLayer0
            }

            onClicked: PowerService.lock()
        }
    }

    // ─── Swipe Intercept Overlay ────────────────────────────────────
    // Sits above all buttons. Detects swipe gestures for page navigation.
    // Taps are forwarded to the button underneath on release.
    MouseArea {
        id: swipeGuard
        anchors.fill: parent
        z: 100
        acceptedButtons: Qt.LeftButton
        // Hover is tracked by the HoverHandler below, not here: this MouseArea
        // covers every button, so its own hover would fire over dead space too
        // and would double up with the buttons' internal MouseAreas.
        hoverEnabled: false
        // Pointing hand over a control, arrow over dead space — matching what
        // the app icons on page 0 do. Driven by the same root._hoverButton the
        // highlight rectangles bind to.
        cursorShape: root._hoverButton ? Qt.PointingHandCursor : Qt.ArrowCursor

        property real _pressX: 0
        property real _pressY: 0
        property bool _swiping: false

        // Derived from the grid's own children instead of a hardcoded array, so
        // a newly added control is clickable without editing this list. The old
        // `const btns = [wifiBtn, btBtn, volBtn, lockBtn]` silently excluded any
        // fifth button: it would render and position correctly but never
        // receive a tap, because only buttons listed here are forwarded to.
        readonly property var buttons: {
            const out = []
            for (let i = 0; i < grid.children.length; i++) {
                const c = grid.children[i]
                // RippleButton (a Button) exposes clicked(); the Image,
                // Rectangle and MaterialSymbol children do not.
                if (c && typeof c.clicked === "function") out.push(c)
            }
            return out
        }

        // Find which button is under the press position. Tests against the
        // button's own implicit size rather than its laid-out width: the
        // GridLayout gives every cell Layout.fillWidth, so `width` is the whole
        // cell and the inter-button columnSpacing would map onto a neighbour.
        function _buttonAt(pos): Item {
            const btns = buttons
            for (const btn of btns) {
                const local = btn.mapFromItem(swipeGuard, pos.x, pos.y)
                const w = btn.implicitWidth > 0 ? btn.implicitWidth : btn.width
                const h = btn.implicitHeight > 0 ? btn.implicitHeight : btn.height
                if (local.x >= 0 && local.x <= w && local.y >= 0 && local.y <= h)
                    return btn
            }
            return null
        }

        onPressed: (mouse) => {
            // Reset ALL per-gesture state unconditionally, BEFORE any early
            // return. The old code returned first when there was no appListRoot
            // (or only one page), leaving _pressX/_pressY/_swiping holding
            // values from a previous gesture. A cancel that never reaches
            // onReleased — which happens on every hot reload, since watchFiles
            // is on — could then arm a swipe from a position the user never
            // touched. DockApps' pageSwipeArea resets for the same reason.
            _pressX = mouse.x
            _pressY = mouse.y
            _swiping = false

            // Same stale-flag hazard as DockApps' pageSwipeArea: this area sets
            // root.appListRoot._suppressNextClick when a swipe is detected, but
            // only a DockAppButton.onClicked ever clears it. A press here can
            // end without any app click following, so drop whatever an earlier
            // press left behind before this one arms its own suppression.
            if (!root.appListRoot) { mouse.accepted = false; return }
            root.appListRoot._suppressNextClick = false
            if (root.appListRoot._pageCount <= 1) { mouse.accepted = false; return }
        }

        onPositionChanged: (mouse) => {
            const dx = mouse.x - _pressX
            const dy = mouse.y - _pressY
            const dist2 = dx * dx + dy * dy
            const threshold = root.appListRoot?.swipeArmThreshold ?? 18

            if (!_swiping) {
                const swipeDelta = root.appListRoot?.vertical ? dy : dx
                const perpDelta  = root.appListRoot?.vertical ? dx : dy
                if (dist2 > threshold * threshold && Math.abs(swipeDelta) > Math.abs(perpDelta)) {
                    _swiping = true
                    if (root.appListRoot) {
                        root.appListRoot._gestureActive = true
                        root.appListRoot._gestureStartPos = root.appListRoot.vertical ? _pressY : _pressX
                        root.appListRoot._gestureCumulative = 0
                        root.appListRoot._gestureOriginPage = root.appListRoot._currentPage
                        root.appListRoot.cancelPageSnap()
                        root.appListRoot._suppressNextClick = true
                    }
                }
            }

            if (_swiping && root.appListRoot) {
                const currentPos = root.appListRoot.vertical ? mouse.y : mouse.x
                root.appListRoot._gestureCumulative = currentPos - root.appListRoot._gestureStartPos

                const base = root.appListRoot._gestureOriginPage * root.appListRoot._pageSize
                const raw = base - root.appListRoot._gestureCumulative * root.appListRoot._swipeSensitivity
                const maxOffset = (root.appListRoot._pageCount - 1) * root.appListRoot._pageSize
                root.appListRoot._contentOffset = Math.max(0, Math.min(raw, maxOffset))
            }
        }

        onReleased: (mouse) => {
            if (_swiping && root.appListRoot) {
                root.appListRoot._gestureActive = false
                const offset = root.appListRoot._gestureCumulative
                const absOffset = Math.abs(offset)
                const threshold = root.appListRoot._pageSize * root.appListRoot._swipeThreshold

                if (offset < 0 && absOffset > threshold && root.appListRoot._currentPage < root.appListRoot._pageCount - 1) {
                    root.appListRoot.snapToPage(root.appListRoot._currentPage + 1)
                } else if (offset > 0 && absOffset > threshold && root.appListRoot._currentPage > 0) {
                    root.appListRoot.snapToPage(root.appListRoot._currentPage - 1)
                } else {
                    root.appListRoot.snapToPage(root.appListRoot._currentPage)
                }
                root.appListRoot._suppressNextClick = true
            } else {
                // Tap — forward to the button underneath
                const btn = _buttonAt({x: _pressX, y: _pressY})
                if (btn) {
                    btn.clicked()
                }
            }
            _swiping = false
        }

        onCanceled: {
            _swiping = false
            if (root.appListRoot?._gestureActive) {
                root.appListRoot._gestureActive = false
                root.appListRoot.snapToPage(root.appListRoot._currentPage)
            }
        }
    }

    // ─── Hover Tracking ─────────────────────────────────────────────
    // swipeGuard swallows the pointer, so RippleButton.buttonHovered (bound to
    // its own internal MouseArea) can never become true and every control
    // showed a plain arrow cursor with no hover highlight — while the app
    // icons on page 0 correctly showed a hand. A HoverHandler observes the
    // pointer without taking the press, and root._hoverButton is the single
    // source of truth the buttons' visuals bind to.
    HoverHandler {
        id: hoverHandler
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

        onHoveredChanged: {
            if (!hovered) root._hoverButton = null
        }
        // `point` is a PROPERTY, not a signal parameter — HoverHandler's only
        // signals are canceled and grabChanged. Binding onPointChanged and
        // reading the argument threw "Cannot read property 'position' of
        // undefined" on every pointer move, so hover never updated at all.
        onPointChanged: {
            if (!hovered) return
            // `point` is a PROPERTY of the handler, not a signal parameter
            // (HoverHandler's only signals are canceled and grabChanged), so it
            // must be read off the handler's id. Two earlier forms both failed
            // at runtime: taking the signal argument — "Cannot read property
            // 'position' of undefined" — and reading bare `point` —
            // "ReferenceError: point is not defined".
            const p = hoverHandler.point.position
            const local = swipeGuard.mapFromItem(root, p.x, p.y)
            root._hoverButton = swipeGuard._buttonAt({x: local.x, y: local.y})
        }
    }
}
