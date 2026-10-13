pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Minimal Niri IPC surface. The dock only calls NiriService.focusWindow(id)
// when a toplevel carries a niriWindowId. Foreign-toplevel .activate() handles
// focusing in every other case, so this is best-effort.

Singleton {
    id: root

    function focusWindow(windowId): void {
        const id = String(windowId ?? "").trim()
        if (id.length === 0) return
        // One detached process per request. The previous single reused Process
        // dropped calls whenever a focus request arrived while the previous one
        // was still running: assigning `running = true` to an already-running
        // Process is a silent no-op, so rapid clicking silently lost focus.
        Quickshell.execDetached(["niri", "msg", "action", "focus-window", "--id", id])
    }
}
