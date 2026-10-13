pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import qs.modules.common
import qs.modules.common.functions

// Stand-alone visual token singleton for the niOS dock.
//
// Derives a coherent Material palette from a single configurable accent
// (Config.options.theme.accent) plus a light/dark toggle.

Singleton {
    id: root

    // ─── Source of truth ────────────────────────────────────────────────
    readonly property color accent: {
        const a = Config.options?.theme?.accent ?? "#7c5cff"
        try { return Qt.color(a) } catch (e) { return Qt.color("#7c5cff") }
    }
    readonly property bool dark: Config.options?.theme?.dark ?? true

    // ─── Top-level toggles ──────────────────────────────────────────────
    // Both were hardcoded `true` and assigned by nothing, while 39 call sites read
    // animationsEnabled and exactly one (StyledRectangularShadow.qml) reads
    // effectsEnabled — the plumbing existed but no switch ever turned it. Bind them
    // to config, keeping the previous behaviour when the key is absent.
    property bool animationsEnabled: Config.options?.theme?.animations !== false
    property bool effectsEnabled: Config.options?.theme?.effects !== false
    property bool gameModeMinimal: false


    // ─── Neutral surface palette (switches with light/dark) ─────────────
    readonly property color _surfBase: root.dark ? "#101016" : "#fdfaff"
    readonly property color _surf0:    root.dark ? "#1a1a21" : "#f2effa"
    readonly property color _surf0H:   root.dark ? "#272731" : "#e5e0f3"
    readonly property color _surf0A:   root.dark ? "#34343f" : "#d8d2e9"
    readonly property color _surf0B:   root.dark ? "#363642" : "#d6d0e6"
    readonly property color _surf1:    root.dark ? "#25252e" : "#ebe6f6"
    readonly property color _surf1H:   root.dark ? "#31313c" : "#ded8ee"
    readonly property color _surf1A:   root.dark ? "#3d3d49" : "#d2cbe6"
    readonly property color _onSurf:   root.dark ? "#e7e3f1" : "#241c38"
    readonly property color _subtext:  root.dark ? "#a59fb5" : "#5b5269"
    readonly property color _outline:  root.dark ? "#3a3a47" : "#cabbd9"
    readonly property color _error:    root.dark ? "#f28b82" : "#b3261e"
    readonly property color _shadow:   root.dark ? "#000000" : "#241a38"
    readonly property color _sc:       root.dark ? "#22222a" : "#efeaf8"
    readonly property color _scLow:    root.dark ? "#1d1d24" : "#f4f1fb"
    readonly property color _scHigh:   root.dark ? "#2b2b34" : "#e7e1f2"
    readonly property color _scTop:    root.dark ? "#33333c" : "#dfd8ec"

    // ─── Accent-derived colors ──────────────────────────────────────────
    readonly property color _primary:         root.accent
    readonly property color _primaryHover:    ColorUtils.mix(root.accent, "#ffffff", 0.82)
    readonly property color _primaryActive:   ColorUtils.mix(root.accent, "#ffffff", 0.66)
    readonly property color _primaryContainer: root.dark ? ColorUtils.mix(root.accent, root._surf1, 0.74)
                                                       : ColorUtils.mix(root.accent, "#ffffff", 0.84)
    readonly property color _secondary:         ColorUtils.mix(root.accent, "#6a8cff", 0.5)
    readonly property color _secondaryContH:    ColorUtils.mix(root._secondary, root._surf1, 0.6)
    readonly property color _secondaryContA:    ColorUtils.mix(root._secondary, root._surf1, 0.4)
    readonly property color _onPrimary:         ColorUtils.contrastColor(root.accent)
    readonly property color _onSecondaryCont:   ColorUtils.contrastColor(root._primaryContainer)

    // ─── colors ─────────────────────────────────────────────────────────
    property QtObject colors: QtObject {
        property color colLayer0Hover: root._surf0H
        property color colLayer0Active: root._surf0A
        property color colLayer0Border: root._surf0B
        property color colLayer1: root._surf1
        property color colLayer1Hover: root._surf1H
        property color colLayer1Active: root._surf1A
        property color colOnLayer0: root._onSurf
        property color colSubtext: root._subtext
        property color colOutlineVariant: root._outline
        property color colPrimary: root._primary
        property color colPrimaryHover: root._primaryHover
        property color colPrimaryActive: root._primaryActive
        property color colSecondary: root._secondary
        property color colError: root._error
        property color colShadow: root._shadow
        property color colSurfaceContainer: root._sc
        property color colSurfaceContainerHighest: root._scTop
    }

    // ─── m3colors ───────────────────────────────────────────────────────
    property QtObject m3colors: QtObject {
        property bool darkmode: root.dark
        property color m3onBackground: root._onSurf
        property color m3primary: root._primary
        property color m3onSurface: root._onSurf
        property color m3onPrimary: root._onPrimary
    }


    // ─── rounding ───────────────────────────────────────────────────────
    property QtObject rounding: QtObject {
        property real full: 999
        property real large: 18
        property real normal: 12
        property real small: 8
    }

    // ─── sizes ──────────────────────────────────────────────────────────
    property QtObject sizes: QtObject {
        // Margin reserved around the dock for elevation/shadow.
        property real elevationMargin: 8
    }

    // ─── font ───────────────────────────────────────────────────────────
    property QtObject font: QtObject {
        property QtObject family: QtObject {
            property string main: "Inter"
            property string numbers: "Inter"
            property string monospace: "JetBrains Mono"
            property string iconMaterial: "Material Symbols Rounded"
        }
        property QtObject pixelSize: QtObject {
            property int small: 11
            property int normal: 13
        }
        property var variableAxes: ({ "main": ({}) })
    }

    // ─── animation ──────────────────────────────────────────────────────
    property QtObject animation: QtObject {
        property QtObject elementMoveEnter: QtObject {
            property int duration: 280
            property int type: Easing.BezierSpline
            property var bezierCurve: [0.05, 0.7, 0.1, 1.0]
        }
        property QtObject elementMoveExit: QtObject {
            property int duration: 220
            property int type: Easing.BezierSpline
            property var bezierCurve: [0.3, 0.0, 0.8, 0.2]
        }
        property QtObject elementMoveFast: QtObject {
            property int duration: 170
            property int type: Easing.BezierSpline
            property var bezierCurve: [0.2, 0.0, 0.0, 1.0]
        }
        property QtObject elementResize: QtObject {
            // This is the animation that drives the dock BACKGROUND's width:
            // dockBackground.width -> panelW -> dockRow.implicitWidth ->
            // DockApps.implicitWidth, whose Behavior reads duration and type.
            //
            // `type` must be a named easing, not Easing.BezierSpline. Measured on
            // this dock (one icon added, 353 -> 440 px): linear reached 13.8% at
            // 31 ms and 89.7% at 229 ms, i.e. ~278 ms of crawl. With
            // Easing.OutQuint the same transition is 59.8% at 29 ms, 94.3% at
            // 79 ms and settled by 130 ms. Do not "fix" it by switching back to
            // BezierSpline.
            //
            // `bezierCurve` is UNUSED: setting `easing.type` on an animation
            // replaces the whole QEasingCurve, discarding any curve written
            // alongside it. The dead `easing.bezierCurve` writes have been
            // removed from every call site; the field below remains only as the
            // documented curve for this preset and may be deleted outright.
            property int duration: 200
            property int type: Easing.OutQuint
            property var bezierCurve: [0.2, 0.0, 0.0, 1.0]
        }
        property QtObject elementMove: QtObject {
            property int duration: 280
            property int type: Easing.BezierSpline
            property var bezierCurve: [0.2, 0.0, 0.0, 1.0]
        }
        property QtObject scroll: QtObject {
            property int duration: 200
            property int type: Easing.BezierSpline
            property var bezierCurve: [0.2, 0.0, 0.0, 1.0]
        }
    }

    // ─── animationCurves ────────────────────────────────────────────────
    property QtObject animationCurves: QtObject {
        property var standardDecel: [0.0, 0.0, 0.0, 1.0]
    }
}
