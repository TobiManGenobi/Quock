pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

// A small modal confirmation, used by the dock's "Change icon" action before
// it touches a desktop entry. It exists because that action rewrites a file
// the whole desktop reads, and an accidental click must not be able to do
// that silently.
//
// Deliberately a plain Loader/PopupWindow pair, like ContextMenu.qml, so it
// creates no window until it is actually opened. Escape, Enter and a click on
// the backdrop are handled explicitly; every non-committing route rejects,
// which is the safe direction — rejecting writes nothing.
Loader {
    id: root

    property string titleText: ""
    // Free-form body; every entry is rendered as its own row.
    property var bodyLines: []
    property string confirmText: "Confirm"
    property string cancelText: "Cancel"
    property bool destructive: false

    // Where the popup is anchored, exactly as ContextMenu.qml does it. Without
    // an anchor block PopupWindow has no item/gravity/edges and lands at the
    // surface's default origin instead of next to the icon.
    property Item anchorItem: parent

    // Raised only when the user commits. This is the single point at which the
    // caller may start an operation.
    signal confirmed()
    signal rejected()

    function open(): void {
        root.active = true
    }

    function confirm(): void {
        root.active = false
        root.confirmed()
    }

    function reject(): void {
        root.active = false
        root.rejected()
    }

    active: false
    visible: active

    sourceComponent: PopupWindow {
        id: popupWindow
        visible: true
        color: "transparent"

        // GlassBackground is a plain Rectangle with no implicit size of its
        // own, so the window is sized from the dialog's own column instead —
        // the way ContextMenu.qml does it. 56 = the column's 16 px margins on
        // each side plus the 12 px margin left around the card.
        implicitWidth: Math.max(380, dialogColumn.implicitWidth + 56)
        implicitHeight: dialogColumn.implicitHeight + 56

        anchor {
            adjustment: PopupAdjustment.Slide
            item: root.anchorItem
            gravity: Edges.Bottom
            edges: Edges.Bottom
        }

        // A click outside the card rejects rather than confirms.
        MouseArea {
            anchors.fill: parent
            onClicked: root.reject()
        }

        Item {
            id: keyHandler
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    root.reject()
                    event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.confirm()
                    event.accepted = true
                }
            }
        }

        GlassBackground {
            id: card
            anchors.centerIn: parent
            // Width and height come from popupWindow above.
            width: popupWindow.implicitWidth - 24
            height: popupWindow.implicitHeight - 24
            fallbackColor: Appearance.colors.colSurfaceContainer
            radius: Appearance.rounding.normal
            border.width: 1
            border.color: Appearance.colors.colSurfaceContainerHighest

            StyledRectangularShadow {
                target: card
            }

            // A press anywhere on the card itself must not reach the backdrop
            // MouseArea above, or clicking the title or the body text
            // dismisses the dialog as a cancel. GlassBackground, the
            // ColumnLayout and the spacer Items do not accept presses, so
            // without this the only MouseArea in the window sees the click.
            // Declared first so the RippleButtons later in the column still
            // sit above it and keep winning.
            MouseArea {
                anchors.fill: parent
                onClicked: {}
            }

            ColumnLayout {
                id: dialogColumn
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10

                StyledText {
                    Layout.fillWidth: true
                    text: root.titleText
                    color: Appearance.m3colors.m3onSurface
                    font.pixelSize: Appearance.font.pixelSize.normal
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: root.bodyLines
                    delegate: StyledText {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData ?? ""
                        color: Appearance.colors.colSubtext
                        font.pixelSize: Appearance.font.pixelSize.small
                        wrapMode: Text.WordWrap
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 6
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Item {
                        Layout.fillWidth: true
                    }

                    RippleButton {
                        buttonText: root.cancelText
                        buttonRadius: Appearance.rounding.small
                        colBackground: "transparent"
                        colBackgroundHover: ColorUtils.transparentize(Appearance.colors.colPrimary, 0.85)
                        onClicked: root.reject()
                    }

                    RippleButton {
                        buttonText: root.confirmText
                        buttonRadius: Appearance.rounding.small
                        toggled: true
                        colBackgroundToggled: root.destructive
                            ? Appearance.colors.colError
                            : Appearance.colors.colPrimary
                        colBackgroundToggledHover: root.destructive
                            ? Appearance.colors.colError
                            : Appearance.colors.colPrimaryHover
                        onClicked: root.confirm()
                    }
                }
            }
        }

        Component.onCompleted: Qt.callLater(() => keyHandler.forceActiveFocus())
    }
}
