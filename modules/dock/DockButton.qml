import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts

RippleButton {
    id: root
    property bool vertical: false
    property string dockPosition: "bottom"

    Layout.fillHeight: !vertical
    Layout.fillWidth: vertical

    implicitWidth: implicitHeight - topInset - bottomInset
    implicitHeight: 50
    buttonRadius: Appearance.rounding.normal

    // Background: fully transparent; hover overlay provides the glass highlight
    colBackground: "transparent"

    // Hover background — bypasses RippleButton's background.color chain (broken via
    // DockButton inheritance). Renders as a sibling z:-1 Rectangle behind content.
    Rectangle {
        id: hoverOverlay
        anchors.fill: parent
        visible: root.buttonHovered
        color: (Config.options?.dock?.hoverBackgroundColor ?? "").length > 0
            ? Config.options.dock.hoverBackgroundColor
            : Appearance.colors.colLayer0Hover
        radius: root.buttonEffectiveRadius
        z: -1
    }

    // Hover background handled by hoverOverlay Rectangle.
    colBackgroundHover: "transparent"
    colRipple: Appearance.colors.colLayer0Active

    background.implicitHeight: 50
    background.implicitWidth: 50
}
