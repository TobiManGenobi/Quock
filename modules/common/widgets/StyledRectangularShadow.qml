import QtQuick
import QtQuick.Effects
import qs.modules.common
import qs.modules.common.functions

// Material-style blur shadow behind a target item (the dock panel, buttons,
// menus). 52+ usages across the shell — this ONE component themes everything.
//
// Two modes:
//  • Default (every other call site): plain Appearance-themed blur shadow.
//  • `direction` set: reproduces mock shell::surface_shadow — a FLAT 2px offset
//    for every non-center direction and a fixed 12px blur radius, so the caller
//    can reserve exactly that much bleed on the surface (see `bleed`).
Item {
    id: root
    required property var target
    property bool hovered: false
    property real radius: (target && target.radius !== undefined) ? Number(target.radius) : 0
    // Passthrough properties for backward compat (some sites override these)
    property real blur: (Appearance.sizes && Appearance.sizes.elevationMargin !== undefined) ? (0.9 * Number(Appearance.sizes.elevationMargin)) : 0
    property real spread: 1
    property color color: Appearance.colors.colShadow
    property vector2d offset: Qt.vector2d(0.0, 1.0)

    // ─── mock parity ──────────────────────────────────────────────────
    // Mock constants (shell/surface/shadow.cpp). The offset is deliberately a
    // flat 2px for every direction rather than derived from the blur.
    readonly property real mockBlurRadius: 12
    readonly property real mockOffsetMagnitude: 2

    // "center" | "down" | "up" | "left" | "right" | diagonals.
    // Empty string keeps the legacy Appearance-driven shadow.
    property string direction: ""
    property real alpha: 0.55

    readonly property bool mockMode: direction !== "" && direction !== "center"

    readonly property vector2d _dirOffset: {
        switch (direction) {
        case "down": return Qt.vector2d(0, mockOffsetMagnitude)
        case "up": return Qt.vector2d(0, -mockOffsetMagnitude)
        case "left": return Qt.vector2d(-mockOffsetMagnitude, 0)
        case "right": return Qt.vector2d(mockOffsetMagnitude, 0)
        case "downLeft": return Qt.vector2d(-mockOffsetMagnitude, mockOffsetMagnitude)
        case "downRight": return Qt.vector2d(mockOffsetMagnitude, mockOffsetMagnitude)
        case "upLeft": return Qt.vector2d(-mockOffsetMagnitude, -mockOffsetMagnitude)
        case "upRight": return Qt.vector2d(mockOffsetMagnitude, -mockOffsetMagnitude)
        case "center": return Qt.vector2d(0, 0)
        }
        return Qt.vector2d(0, 0)
    }

    readonly property real _effectiveBlur: mockMode ? mockBlurRadius : blur
    readonly property vector2d _effectiveOffset: mockMode ? _dirOffset : offset

    readonly property color _effectiveColor: mockMode ? Qt.rgba(0, 0, 0, alpha) : color

    // Track the target's geometry — size AND position. Call sites pass
    // `target:` only and set no anchors, so this Item used to sit at its
    // parent's (0,0) while an inset target sat elsewhere: in ContextMenu.qml
    // the card is inset by `margins: ambientShadowWidth + visualMargin`, so
    // the shadow painted a card-sized rect at the popup origin, displaced
    // up-and-left of the card by exactly that margin — the hard black band in
    // the screenshot. Binding x/y to the target's makes the shadow track it
    // for free, including while the card animates (sourceEdgeMargin), and is
    // a no-op at the ~52 call sites whose target already sits at the origin.
    x: target ? target.x : 0
    y: target ? target.y : 0
    width: target ? Math.max(0, target.width) : 0
    height: target ? Math.max(0, target.height) : 0

    visible: Appearance.effectsEnabled

    // ─── MATERIAL MODE: standard blur shadow ───
    // RectangularShadow shrinks its effective corner radius by ~blur*0.75 (see
    // Qt's clampedRadius()), so with a wide blur the shadow corners turn squarer
    // than the target and poke out past its rounded corners. Compensate so the
    // shadow's rendered radius matches the panel outline.
    RectangularShadow {
        visible: true
        anchors.fill: parent
        radius: root.radius + root._effectiveBlur * 0.75
        blur: root._effectiveBlur
        offset: root._effectiveOffset
        spread: root.mockMode ? 0 : root.spread
        color: root._effectiveColor
        cached: true
    }
}