import qs.modules.common
import qs.modules.common.functions
import QtQuick

// Reusable glass/acrylic background component.
// Wallpaper blur pipeline removed; renders as a solid Material-colored rectangle.
Rectangle {
    id: root

    property color fallbackColor: Appearance.colors.colLayer1

    color: root.fallbackColor

    property bool hovered: false

    border.width: 0
    border.color: "transparent"

    clip: true
}
