pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// Window thumbnail provider. Stand-alone: no compositor screencopy is wired,
// so previews fall back to the app icon. Signals are declared so the dock's
// Connections compile; they are never emitted.

Singleton {
    id: root

    signal previewUpdated(int windowId)
    signal captureComplete()

    function captureForTaskView(): void { /* no-op */ }

    function getPreviewUrl(_windowId: int): string { return "" }
}
