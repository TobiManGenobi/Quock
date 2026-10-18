pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell.Widgets
import Quickshell.Wayland
import Quickshell
import qs.services.Desktop
import qs.services.Apps
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

Button {
    id: root

    required property var toplevel
    padding: 6
    Layout.fillHeight: true

    // Emitted BEFORE focus IPC so the popup can close instantly
    signal windowActivated()
    // Emitted when the user closes a window from the preview
    signal windowCloseClicked()

    onClicked: {
        root.windowActivated()
        if (CompositorService.isNiri && root.toplevel?.niriWindowId) {
            NiriService.focusWindow(root.toplevel.niriWindowId)
        } else {
            root.toplevel?.activate()
        }
    }

    background: Rectangle {
        id: background
        radius: Appearance.rounding.small
        color: root.down
            ? ColorUtils.transparentize(Appearance.colors.colPrimary, 0.7)
            : ColorUtils.transparentize(Appearance.colors.colLayer1, 0.9)
        Behavior on color {
            ColorAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
        }
    }

    contentItem: ColumnLayout {
        id: contentItem
        anchors.fill: parent
        anchors.margins: root.padding
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: false
            spacing: 6

            IconImage {
                id: appIcon
                Layout.alignment: Qt.AlignVCenter
                asynchronous: true
                source: {
                    const appId = root.toplevel?.appId ?? "";
                    const de = AppSearch.lookupDesktopEntry(appId);
                    const icon = de?.icon || AppSearch.guessIcon(appId);
                    const resolved = IconThemeService.smartIconName(icon, appId);
                    if (resolved.startsWith("/") || resolved.startsWith("file://")) {
                        return resolved.startsWith("file://") ? resolved : `file://${resolved}`;
                    }
                    // Same reason as ContextMenu: iconPath() yields the @2x
                    // SVGs Qt mis-renders. rasterOrBlank() returns the PNG,
                    // or "" while the conversion is queued — never the SVG,
                    // so libqsvg is never asked to render gradientTransform.
                    return IconThemeService.rasterOrBlank(
                        IconThemeService.resolveIconUrl(resolved), 64)
                }
                implicitSize: 16
                mipmap: true
                smooth: true
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                implicitHeight: closeButton.implicitHeight

                StyledText {
                    anchors.fill: parent
                    anchors.rightMargin: closeButton.visible ? closeButton.width + 4 : 0
                    text: root.toplevel?.title ?? ""
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer0
                    verticalAlignment: Text.AlignVCenter
                }
            }

            RippleButton {
                id: closeButton
                opacity: root.hovered ? 1 : 0
                visible: opacity > 0
                implicitWidth: 20
                implicitHeight: 20
                buttonRadius: Appearance.rounding.full
                Behavior on opacity {
                    enabled: Appearance.animationsEnabled
                    NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
                }
                colBackground: "transparent"
                colBackgroundHover: ColorUtils.transparentize(Appearance.colors.colError, 0.8)
                colRipple: ColorUtils.transparentize(Appearance.colors.colError, 0.6)
                
                onClicked: {
                    root.windowCloseClicked()
                    root.toplevel?.close()
                }

                contentItem: MaterialSymbol {
                    text: "close"
                    iconSize: 14
                    color: root.hovered 
                        ? Appearance.colors.colSubtext
                        : "transparent"
                }
            }
        }

        Item {
            id: previewArea
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 4
            Layout.topMargin: 0
            implicitWidth: 140
            implicitHeight: 90

            // Prefer niriWindowId for Niri compositor
            readonly property int windowId: CompositorService.isNiri
                ? (root.toplevel?.niriWindowId ?? root.toplevel?.id ?? 0)
                : (root.toplevel?.id ?? 0)
            property string previewUrl: ""

            // Fallback icon (snap visibility like waffle — no opacity fade)
            IconImage {
                anchors.centerIn: parent
                source: appIcon.source
                implicitSize: Math.min(48, parent.width * 0.4)
                visible: windowPreview.status !== Image.Ready
                opacity: 0.7
                mipmap: true
                smooth: true
                asynchronous: true
            }

            // Preview image
            Image {
                id: windowPreview
                source: previewArea.previewUrl
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                smooth: true
                mipmap: true
                anchors.fill: parent
                anchors.margins: 2
                opacity: status === Image.Ready ? 1 : 0

                Behavior on opacity {
                    enabled: Appearance.animationsEnabled
                    NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
                }

                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: windowPreview.width
                        height: windowPreview.height
                        radius: Appearance.rounding.small
                    }
                }
            }

            // Listen for preview updates
            Connections {
                target: WindowPreviewService
                function onPreviewUpdated(updatedId: int): void {
                    if (updatedId === previewArea.windowId) {
                        previewArea.previewUrl = WindowPreviewService.getPreviewUrl(updatedId)
                    }
                }
                function onCaptureComplete(): void {
                    const url = WindowPreviewService.getPreviewUrl(previewArea.windowId)
                    if (url) previewArea.previewUrl = url
                }
            }

            // Check if preview exists on load
            Component.onCompleted: {
                Qt.callLater(() => {
                    const url = WindowPreviewService.getPreviewUrl(windowId)
                    if (url) previewUrl = url
                })
            }
        }
    }
}
