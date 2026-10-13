import qs.modules.common
import qs.modules.common.widgets
import Qt5Compat.GraphicalEffects
import QtQuick

// Mock port: createLauncherButton() in
// mock/src/shell/dock/dock_items.cpp.
//
// A dock cell that is *not* an app: it is never part of the pinned/running
// model, never drag-reorderable, never bounces on click and never shows the
// "active" state. Its cell is exactly one item cell (iconSize + 2*kCellPad, with
// kCellPad == 6), so it inherits the dock's row padding and spacing.
DockButton {
    id: root

    property real iconSize: Config.options?.dock?.iconSize ?? 35
    // Mirrors the cell geometry DockAppButton uses, so the launcher occupies
    // exactly one item slot.
    readonly property real cellSize: root.iconSize + 12

    // ─── Configuration ─────────────────────────────────────────────────
    // Tabler-style glyph name, or an absolute path / file:// URL in which case
    // the image replaces the glyph.
    readonly property string launcherIcon: Config.options?.dock?.launcherIcon ?? "grid-dots"
    readonly property bool _colorize: Config.options?.dock?.launcherCustomImageColorize ?? false
    readonly property color _onSurface: Appearance?.m3colors?.m3onSurface ?? Appearance?.colors?.colOnSurface ?? "#ffffff"

    // The mock branches on launcher_custom_image, which is derived from
    // launcher_icon: a leading "/" or a file:// scheme means "image".
    readonly property bool _isCustomImage: root.launcherIcon.startsWith("/")
        || root.launcherIcon.startsWith("file://")
    readonly property string _imageSource: root.launcherIcon.startsWith("file://")
        ? root.launcherIcon
        : ("file://" + root.launcherIcon)

    // kLauncherGlyphSizeRatio — the glyph is drawn smaller than an app icon and
    // centred inside the iconSize box.
    readonly property real glyphSize: root.iconSize * 0.8

    // Material Symbols ligature names use underscores; the config carries the
    // Tabler spelling with dashes.
    function _ligatureName(name): string {
        return (name ?? "").replace(/-/g, "_")
    }

    // Detect whether the icon font actually carries the requested ligature.
    // QML's FontMetrics has no inFont(), but a formed ligature collapses the
    // whole name into one glyph, so its advance width no longer equals the sum
    // of the per-character advances.
    FontMetrics {
        id: glyphMetrics
        font.family: Appearance?.font?.family?.iconMaterial ?? "Material Symbols Rounded"
        font.pixelSize: 100
    }

    function _ligatureAvailable(name): bool {
        if (!name || name.length === 0)
            return false
        let perChar = 0
        for (let i = 0; i < name.length; i++)
            perChar += glyphMetrics.advanceWidth(name[i])
        return Math.abs(glyphMetrics.advanceWidth(name) - perChar) > 0.5
    }

    // Mock: dockLauncherIconGlyph() — an empty name yields "grid-dots", and an
    // unresolvable glyph falls back to the same one.
    readonly property string _glyphName: {
        const requested = root._ligatureName(root.launcherIcon)
        if (root._ligatureAvailable(requested))
            return requested
        return root._ligatureAvailable("grid_dots") ? "grid_dots" : requested
    }

    // ─── Cell geometry ─────────────────────────────────────────────────
    implicitWidth: root.cellSize
    implicitHeight: root.cellSize
    background.implicitWidth: root.cellSize
    background.implicitHeight: root.cellSize
    rippleEnabled: !(Config.options?.dock?.disableRipple ?? false)

    // The launcher is never "active" and is never magnify-lerped: the mock
    // pins its visual scale to cfg.inactiveScale (instance.launcherVisualScale
    // is seeded with it and only ever animated toward it).
    scale: Config.options?.dock?.inactiveScale ?? 0.85
    Behavior on scale {
        enabled: Appearance.animationsEnabled
        animation: NumberAnimation { duration: Appearance.animation.elementMoveFast.duration; easing.type: Appearance.animation.elementMoveFast.type }
    }

    // ─── Click behaviour ───────────────────────────────────────────────
    // The mock calls clickContext->callbacks.toggleLauncher here. This build has
    // no launcher IPC: Dock::registerIpc only binds dockShow/dockHide/
    // dockToggle/dockReload and the IPC service never opens a socket, so there
    // is nothing to invoke and no app-grid exists to open. The signal is exposed
    // as an overridable no-op so a shell that later grows real launcher IPC can
    // bind it without touching this component.
    signal launcherRequested()

    onClicked: root.launcherRequested()

    contentItem: Item {
        anchors.centerIn: parent

        Loader {
            anchors.centerIn: parent
            active: !root._isCustomImage
            sourceComponent: MaterialSymbol {
                iconSize: root.glyphSize
                text: root._glyphName
                color: root._onSurface
            }
        }

        Image {
            anchors.centerIn: parent
            width: root.iconSize
            height: root.iconSize
            visible: root._isCustomImage
            // ImageFit::Contain — preserve the aspect ratio inside the box.
            fillMode: Image.PreserveAspectFit
            sourceSize.width: root.iconSize
            sourceSize.height: root.iconSize
            asynchronous: true
            source: root._isCustomImage ? root._imageSource : ""

            // Mock: setForegroundTint(colorSpecFromRole(OnSurface)) only when
            // launcher_custom_image_colorize is set; otherwise the image keeps
            // its own colours.
            layer.enabled: root._isCustomImage && root._colorize
            layer.effect: ColorOverlay {
                color: root._onSurface
            }
        }
    }
}