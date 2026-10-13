import qs.modules.common
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Quickshell

// Digital (two-line hour/minutes) or analog (hands) clock rendered at app-icon
// size with a custom SVG background. Version-safe: plain Timer + new Date()
// (Quickshell 0.3.0 on PikaOS has no Quickshell/Time singleton).
//
// Every visual aspect is configurable per line from config.json under
// `dock.clock` (see Config.qml defaults):
//   enabled, mode ("digital"|"analog")
//   analogSeconds, analogHandColor, analogSecondColor
//   showHour, showMinutes
//   hourSize, minuteSize          (null = auto from iconSize)
//   hourOffsetX/Y, minuteOffsetX/Y (logical px; hourOffsetY null = auto raise)
//   hourColor, minuteColor        ("" = white)
//   hourWeight, minuteWeight      (Normal | Light | Medium | DemiBold | Bold)
//   hourAlign, minuteAlign        (left | center | right)
//   clockSpacing                  (gap between lines; null = auto tight)
Item {
    id: root

    property bool vertical: false
    property string dockPosition: "bottom"
    property real iconSize: Config.options?.dock?.iconSize ?? 35
    // Icon background for the clock in digital mode. Empty = no background
    // image (glass dock panel shows through). Analog mode uses
    // dock.clock.analogBackground instead. This is a writable state property
    // synced reactively from Config (see _syncAnalogConfig); it is NOT a
    // binding because nested Config bindings are not reliably re-evaluated.
    property string backgroundSource: ""

    // Match DockAppButton sizing so the clock occupies exactly one app-icon slot.
    readonly property real _buttonSize: iconSize + 12

    // Analog mode state.
    property bool _isAnalog: false
    property string _analogBackground: ""
    // Sized exactly like app-icon artwork: the IconImage in DockAppButton
    // renders at iconSize × iconSize, so the analog face uses the full icon
    // box too (factor 1.0) instead of the old 0.88 inactive-artwork shrink.
    readonly property real _analogFaceSize: root.iconSize
    readonly property bool _analogSeconds: Config.options?.dock?.clock?.analogSeconds ?? false
    readonly property color _analogHandColor: (Config.options?.dock?.clock?.analogHandColor ?? "").length > 0
        ? Config.options.dock.clock.analogHandColor : "white"
    readonly property color _analogSecondColor: (Config.options?.dock?.clock?.analogSecondColor ?? "").length > 0
        ? Config.options.dock.clock.analogSecondColor : "#ff5a5a"
    property real _hourAngle: 0
    property real _minuteAngle: 0
    property real _secondAngle: 0

    // Font sizes: explicit config value, or auto-derived from iconSize.
    readonly property real _hourFontSize: {
        const s = Config.options?.dock?.clock?.hourSize ?? -1
        return s > 0 ? s : Math.max(20, Math.round(iconSize * 0.46))
    }
    readonly property real _minuteFontSize: {
        const s = Config.options?.dock?.clock?.minuteSize ?? -1
        return s > 0 ? s : Math.max(14, Math.round(iconSize * 0.28))
    }
    // Vertical nudges (logical px). hourOffsetY null = auto slight raise.
    readonly property real _hourOffsetY: {
        const o = Config.options?.dock?.clock?.hourOffsetY
        if (o !== undefined && o !== null && o !== -1) return o
        return -Math.round(root._hourFontSize * 0.13)
    }
    readonly property real _hourOffsetX: Config.options?.dock?.clock?.hourOffsetX ?? 0
    readonly property real _minuteOffsetX: Config.options?.dock?.clock?.minuteOffsetX ?? 0
    readonly property real _minuteOffsetY: Config.options?.dock?.clock?.minuteOffsetY ?? 0
    // Horizontal glyph stretch (1.0 = normal, >1 wider, <1 narrower).
    readonly property real _hourStretch: Config.options?.dock?.clock?.hourStretch ?? 1.0
    readonly property real _minuteStretch: Config.options?.dock?.clock?.minuteStretch ?? 1.0
    // Gap between lines; null = auto (tight, pulled into hour descent).
    readonly property real _clockSpacing: {
        const s = Config.options?.dock?.clock?.clockSpacing
        if (s !== undefined && s !== null && s !== -1) return s
        return -Math.round(root._hourFontSize * 0.45)
    }
    readonly property color _hourColor: (Config.options?.dock?.clock?.hourColor ?? "").length > 0
        ? Config.options.dock.clock.hourColor : "white"
    readonly property color _minuteColor: (Config.options?.dock?.clock?.minuteColor ?? "").length > 0
        ? Config.options.dock.clock.minuteColor : "white"
    readonly property int _hourWeight: _weight(Config.options?.dock?.clock?.hourWeight ?? "DemiBold")
    readonly property int _minuteWeight: _weight(Config.options?.dock?.clock?.minuteWeight ?? "DemiBold")
    readonly property int _hourAlign: _align(Config.options?.dock?.clock?.hourAlign ?? "center")
    readonly property int _minuteAlign: _align(Config.options?.dock?.clock?.minuteAlign ?? "center")

    function _weight(w: string): int {
        const s = String(w ?? "DemiBold").toLowerCase()
        if (s === "normal") return Font.Normal
        if (s === "light") return Font.Light
        if (s === "medium") return Font.Medium
        if (s === "bold") return Font.Bold
        return Font.DemiBold
    }
    function _align(a: string): int {
        const s = String(a ?? "center").toLowerCase()
        if (s === "left") return Text.AlignLeft
        if (s === "right") return Text.AlignRight
        return Text.AlignHCenter
    }

    Layout.fillHeight: !vertical
    Layout.fillWidth: vertical
    implicitWidth: _buttonSize
    implicitHeight: _buttonSize

    property string hourText: "--"
    property string minuteText: "--"



    // Quickshell 0.3.1 workaround: readonly/property bindings to nested
    // Config.options objects are not re-evaluated after _hydrate().
    // We explicitly sync config values on startup and on configChanged.
    function _syncAnalogConfig(): void {
        const mode = Config.options?.dock?.clock?.mode ?? "digital"
        root._isAnalog = mode === "analog"
        root._analogBackground = Config.options?.dock?.clock?.analogBackground ?? ""
        // backgroundSource must ALSO be synced here (not bound) so runtime
        // changes to dock.clock.digitalBackground are reflected — nested
        // Config bindings are not re-evaluated after _hydrate().
        root.backgroundSource = Config.options?.dock?.clock?.digitalBackground ?? ""
        // Image.source stays bound to the reactive state properties below, so
        // it re-evaluates on configChanged without being clobbered here.
    }

    // ─── Icon-gate participation ────────────────────────────────────────
    // The dock holds its whole surface closed until every icon it means to
    // show has something decoded. App icons report through
    // registerIconPending/notifyIconReady; without an equivalent signal here
    // the clock would be exempt and the dock could reveal over a face whose
    // SVG background has not painted yet.
    //
    // "Settled" mirrors _iconSettled() in DockAppButton: an EMPTY source is
    // ready (nothing is configured, nothing will ever arrive — waiting would
    // park the dock on its fallback timeout for the same picture), and a
    // failed decode is ready for the same reason. Only a real load in flight
    // counts as not-ready.
    readonly property bool hasBackground:
        root._isAnalog ? (root._analogBackground.length > 0) : (root.backgroundSource.length > 0)
    readonly property bool backgroundSettled:
        !root.hasBackground || clockBackground.status === Image.Ready
                             || clockBackground.status === Image.Error
    // QML auto-generates backgroundSettledChanged() for this property, which
    // is what the delegate's Connections listens to — declaring it explicitly
    // here would only shadow it with an identical duplicate.

    Component.onCompleted: {
        // Delay to ensure Config singleton has loaded (FileView is async)
        root._syncAnalogConfig()
    }

    Connections {
        target: Config
        function onConfigChanged() {
            root._syncAnalogConfig()
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            const d = new Date()
            hourText = ("0" + d.getHours()).slice(-2)
            minuteText = ("0" + d.getMinutes()).slice(-2)
            // Analog hand angles (degrees, 0 = up/12 o'clock).
            root._hourAngle = (d.getHours() % 12) * 30 + d.getMinutes() * 0.5
            root._minuteAngle = d.getMinutes() * 6
            root._secondAngle = d.getSeconds() * 6
        }
    }

    Image {
        id: clockBackground
        anchors.centerIn: parent
        // FIX: Image.source is a url-typed property; `.length` on it is not
        // reliably the string length (observed: visible=false with a valid
        // source). Evaluate against the string state props instead.
        visible: root.hasBackground
        width: root._isAnalog ? root._analogFaceSize : root.iconSize
        height: root._isAnalog ? root._analogFaceSize : root.iconSize
        source: root._isAnalog && root._analogBackground.length > 0 ? root._analogBackground : root.backgroundSource
        sourceSize.width: width
        sourceSize.height: height
        smooth: true
        fillMode: Image.PreserveAspectFit
    }

    Column {
        visible: !root._isAnalog
        anchors.centerIn: clockBackground
        width: root.iconSize
        spacing: root._clockSpacing

        Text {
            id: hourTextItem
            width: parent.width
            horizontalAlignment: root._hourAlign
            visible: Config.options?.dock?.clock?.showHour ?? true
            text: root.hourText
            font.family: Appearance.font.family.main
            font.pixelSize: root._hourFontSize
            font.weight: root._hourWeight
            color: root._hourColor
            transform: [
                Translate {
                    x: root._hourOffsetX
                    y: root._hourOffsetY
                },
                Scale {
                    xScale: root._hourStretch
                    yScale: 1.0
                    // Qt 6.9 Scale has no originX/Y — use the 3D `origin`
                    // vector; without it, scaling happens around (0,0) and
                    // shifts the text right when stretched.
                    origin: Qt.vector3d(hourTextItem.width / 2, hourTextItem.height / 2, 0)
                }
            ]
        }
        Text {
            id: minuteTextItem
            width: parent.width
            horizontalAlignment: root._minuteAlign
            visible: Config.options?.dock?.clock?.showMinutes ?? true
            text: root.minuteText
            font.family: Appearance.font.family.main
            font.pixelSize: root._minuteFontSize
            font.weight: root._minuteWeight
            color: root._minuteColor
            transform: [
                Translate {
                    x: root._minuteOffsetX
                    y: root._minuteOffsetY
                },
                Scale {
                    xScale: root._minuteStretch
                    yScale: 1.0
                    origin: Qt.vector3d(minuteTextItem.width / 2, minuteTextItem.height / 2, 0)
                }
            ]
        }
    }

    // ─── Analog mode ───────────────────────────────────────────────────
    // Hands rotate around the face center (parent size / 2). Each hand is
    // laid out with its bottom-center at the pivot and rotates via Rotation
    // with the origin at that local point.
    Item {
        visible: root._isAnalog
        anchors.centerIn: clockBackground
        width: root._analogFaceSize
        height: root._analogFaceSize

        // Hour hand — short and thick.
        Rectangle {
            id: analogHourHand
            width: Math.max(2.5, parent.width * 0.06)
            height: parent.height * 0.24
            radius: width / 2
            color: root._analogHandColor
            x: (parent.width - width) / 2
            y: parent.height / 2 - height
            antialiasing: true
            transform: Rotation {
                angle: root._hourAngle
                origin.x: analogHourHand.width / 2
                origin.y: analogHourHand.height
            }
        }

        // Minute hand — longer and thinner.
        Rectangle {
            id: analogMinuteHand
            width: Math.max(1.8, parent.width * 0.04)
            height: parent.height * 0.34
            radius: width / 2
            color: root._analogHandColor
            x: (parent.width - width) / 2
            y: parent.height / 2 - height
            antialiasing: true
            transform: Rotation {
                angle: root._minuteAngle
                origin.x: analogMinuteHand.width / 2
                origin.y: analogMinuteHand.height
            }
        }

        // Optional second hand — thin, accent color.
        Rectangle {
            id: analogSecondHand
            visible: root._analogSeconds
            width: Math.max(1.2, parent.width * 0.025)
            height: parent.height * 0.38
            radius: width / 2
            color: root._analogSecondColor
            x: (parent.width - width) / 2
            y: parent.height / 2 - height
            antialiasing: true
            transform: Rotation {
                angle: root._secondAngle
                origin.x: analogSecondHand.width / 2
                origin.y: analogSecondHand.height
            }
        }

        // Center cap.
        Rectangle {
            width: Math.max(3.5, parent.width * 0.055)
            height: width
            radius: width / 2
            color: root._analogHandColor
            x: (parent.width - width) / 2
            y: (parent.height - height) / 2
        }
    }
}
