import QtQuick
import QtQuick.Shapes

// Rectangle-like panel that supports an independent radius per corner, plus a
// per-corner "concave" mode used by the dock's screen-edge corners.
//
// Stock QtQuick Rectangle only has a uniform `radius`; per-corner radii need a
// Shape path. A concave corner bends the outline the other way so the corner
// point stays inside the fill — a dock that hugs the screen edge wants that
// instead of a rounded bite. API mirrors Rectangle (color, border) so it can be
// used as a drop-in for panel backgrounds.
Shape {
    id: root

    property real topLeftRadius: 0
    property real topRightRadius: 0
    property real bottomLeftRadius: 0
    property real bottomRightRadius: 0

    // Which corners bend inward. The caller picks these (mock: dockConcaveShape).
    property bool topLeftConcave: false
    property bool topRightConcave: false
    property bool bottomLeftConcave: false
    property bool bottomRightConcave: false

    property color color: "transparent"
    property color borderColor: "transparent"
    property real borderWidth: 0

    // Uniform "radius" view for shadow consumers that read target.radius
    // (StyledRectangularShadow). Uses the largest corner.
    readonly property real radius: Math.max(topLeftRadius, topRightRadius, bottomLeftRadius, bottomRightRadius)

    antialiasing: true

    // Inset the path by half the border width so the stroke renders fully
    // inside the item, matching Rectangle's border (which is clipped inside).
    readonly property real _inset: Math.max(0, borderWidth) / 2
    readonly property real _w: Math.max(0, width - 2 * _inset)
    readonly property real _h: Math.max(0, height - 2 * _inset)
    readonly property real _ox: _inset
    readonly property real _oy: _inset

    readonly property real _tl: Math.min(Math.max(0, topLeftRadius), _w / 2, _h / 2)
    readonly property real _tr: Math.min(Math.max(0, topRightRadius), _w / 2, _h / 2)
    readonly property real _br: Math.min(Math.max(0, bottomRightRadius), _w / 2, _h / 2)
    readonly property real _bl: Math.min(Math.max(0, bottomLeftRadius), _w / 2, _h / 2)

    // Cubic approximation of the circular arc between two corner endpoints.
    // `cx, cy` is the arc centre: for a convex corner it sits one radius
    // diagonally inside the corner point; for a concave corner it sits one
    // radius diagonally OUTSIDE, which is what flips the curve's bulge.
    function _corner(ax: real, ay: real, bx: real, by: real, cx: real, cy: real): var {
        const rax = ax - cx
        const ray = ay - cy
        const rbx = bx - cx
        const rby = by - cy
        const ra = Math.hypot(rax, ray)
        const rb = Math.hypot(rbx, rby)
        if (ra <= 0 || rb <= 0) return null

        const dot = (rax * rbx + ray * rby) / (ra * rb)
        const theta = Math.acos(Math.max(-1, Math.min(1, dot)))
        if (theta < 1e-4) return null

        // (4/3)·tan(θ/4)·R — the exact handle length for a circular arc;
        // equals the familiar 0.5523 for a quarter circle.
        const k = (4 / 3) * Math.tan(theta / 4)
        const chordX = bx - ax
        const chordY = by - ay

        // Travel tangents: perpendicular to each radius, signed to agree with
        // the chord direction so the curve sweeps the short way round.
        let t1x = -ray / ra
        let t1y = rax / ra
        if (t1x * chordX + t1y * chordY < 0) { t1x = -t1x; t1y = -t1y }
        let t2x = -rby / rb
        let t2y = rbx / rb
        if (t2x * chordX + t2y * chordY < 0) { t2x = -t2x; t2y = -t2y }

        return {
            c1x: ax + t1x * k * ra,
            c1y: ay + t1y * k * ra,
            c2x: bx - t2x * k * rb,
            c2y: by - t2y * k * rb,
        }
    }

    // Clockwise path: top edge → TR → BR → BL → TL. Corner arc centres sit one
    // radius diagonally inside the corner; concave corners mirror that centre
    // to the outside of the shape, flipping the bulge.
    readonly property var _tlC: _corner(_ox, _oy + _tl, _ox + _tl, _oy,
        _ox + _tl * (topLeftConcave ? -1 : 1), _oy + _tl * (topLeftConcave ? -1 : 1))
    readonly property var _trC: _corner(_ox + _w - _tr, _oy, _ox + _w, _oy + _tr,
        _ox + _w - _tr * (topRightConcave ? -1 : 1), _oy + _tr * (topRightConcave ? -1 : 1))
    readonly property var _brC: _corner(_ox + _w, _oy + _h - _br, _ox + _w - _br, _oy + _h,
        _ox + _w - _br * (bottomRightConcave ? -1 : 1), _oy + _h - _br * (bottomRightConcave ? -1 : 1))
    readonly property var _blC: _corner(_ox + _bl, _oy + _h, _ox, _oy + _h - _bl,
        _ox + _bl * (bottomLeftConcave ? -1 : 1), _oy + _h - _bl * (bottomLeftConcave ? -1 : 1))

    ShapePath {
        id: outline
        fillColor: root.color
        strokeColor: root.borderColor
        strokeWidth: root.borderWidth
        joinStyle: ShapePath.RoundJoin

        startX: root._ox + root._tl
        startY: root._oy

        PathLine { x: root._ox + root._w - root._tr; y: root._oy }
        PathCubic {
            control1X: root._trC ? root._trC.c1x : 0
            control1Y: root._trC ? root._trC.c1y : 0
            control2X: root._trC ? root._trC.c2x : 0
            control2Y: root._trC ? root._trC.c2y : 0
            x: root._ox + root._w
            y: root._oy + root._tr
        }
        PathLine { x: root._ox + root._w; y: root._oy + root._h - root._br }
        PathCubic {
            control1X: root._brC ? root._brC.c1x : 0
            control1Y: root._brC ? root._brC.c1y : 0
            control2X: root._brC ? root._brC.c2x : 0
            control2Y: root._brC ? root._brC.c2y : 0
            x: root._ox + root._w - root._br
            y: root._oy + root._h
        }
        PathLine { x: root._ox + root._bl; y: root._oy + root._h }
        PathCubic {
            control1X: root._blC ? root._blC.c1x : 0
            control1Y: root._blC ? root._blC.c1y : 0
            control2X: root._blC ? root._blC.c2x : 0
            control2Y: root._blC ? root._blC.c2y : 0
            x: root._ox
            y: root._oy + root._h - root._bl
        }
        PathLine { x: root._ox; y: root._oy + root._tl }
        PathCubic {
            control1X: root._tlC ? root._tlC.c1x : 0
            control1Y: root._tlC ? root._tlC.c1y : 0
            control2X: root._tlC ? root._tlC.c2x : 0
            control2Y: root._tlC ? root._tlC.c2y : 0
            x: root._ox + root._tl
            y: root._oy
        }
    }
}