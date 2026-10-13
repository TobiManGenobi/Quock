pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// Compositor detection + reactive toplevel source for the stand-alone dock.
// Uses Quickshell's Wayland ToplevelManager directly via wlr-foreign-toplevel;
// we keep it dependency-free and let foreign-toplevel .activate() do the
// focusing.
//
// IMPORTANT: sortedToplevels returns enriched plain-JS objects, NOT live
// ToplevelHandle QObjects.  This prevents use-after-free crashes when QML
// bindings re-evaluate during Wayland event dispatch (the ToplevelHandle
// QObject can be destroyed while property notifications are still flying).

Singleton {
    id: root

    readonly property bool isNiri: {
        const d = String(Quickshell.env("XDG_CURRENT_DESKTOP") ?? "").toLowerCase()
        return d.indexOf("niri") !== -1
    }

    // Authoritative list of open toplevels, sorted for deterministic dock order.
    // Returns enriched plain-JS objects (not QObject pointers) so QML bindings
    // inside the PanelWindow never read properties from a destroyed ToplevelHandle.
    //
    // Updated synchronously by onValuesChanged so callers always see current data.
    property var sortedToplevels: []

    function _rebuildSortedToplevels() {
        const v = ToplevelManager.toplevels?.values ?? []
        sortedToplevels = v.slice().sort((a, b) =>
            String(a.appId ?? "").localeCompare(String(b.appId ?? "")))
            .map(tl => _enrich(tl))
    }

    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() { root._rebuildSortedToplevels() }
    }

    Component.onCompleted: root._rebuildSortedToplevels()

    // Snapshot of the active toplevel's key, updated in the same cycle as
    // sortedToplevels so QML bindings read a stable string, not a live QObject.
    readonly property string activeToplevelKey: _toplevelKey(ToplevelManager.activeToplevel)

    readonly property bool hasActiveActivatedToplevel: ToplevelManager.activeToplevel?.activated ?? false

    function _enrich(toplevel): var {
        if (!toplevel) return null
        const key = _toplevelKey(toplevel)
        return {
            appId: toplevel.appId,
            id: toplevel.id,
            title: toplevel.title,
            activated: toplevel.activated,
            minimized: toplevel.minimized,
            maximized: toplevel.maximized,
            fullscreen: toplevel.fullscreen,
            address: toplevel.address,
            niriWindowId: toplevel.niriWindowId,
            pid: toplevel.pid,
            wayland: {
                appId: toplevel.wayland?.appId ?? "",
                title: toplevel.wayland?.title ?? "",
            },
            close: function() {
                const k = this._sourceKey
                if (!k) return
                Qt.callLater(() => {
                    for (const tl of ToplevelManager.toplevels.values) {
                        if (root._toplevelKey(tl) === k) {
                            tl.close()
                            return
                        }
                    }
                })
            },
            activate: function() {
                const k = this._sourceKey
                if (!k) return
                Qt.callLater(() => {
                    for (const tl of ToplevelManager.toplevels.values) {
                        if (root._toplevelKey(tl) === k) {
                            tl.activate()
                            return
                        }
                    }
                })
            },
            // Stable key from the live QObject's pointer string.
            // Used by activate/close to look up the live handle, and by
            // DockAppButton to match enriched snapshots against the active toplevel.
            _sourceKey: key,
        }
    }

    function _toplevelKey(toplevel): string {
        if (!toplevel) return ""
        // For live ToplevelHandle QObjects, String() returns a stable
        // pointer-based identifier (e.g. "ToplevelHandle(0x7f520bf40800)")
        // that does NOT change when properties like title/activated change.
        // This is critical: title-based keys break when the window title
        // updates (e.g. nautilus "Loading…" → "Home"), causing appIsActive
        // to fail matching the active window.
        const s = String(toplevel)
        if (s && s !== "[object Object]" && s !== "undefined" && s !== "null")
            return "ptr:" + s
        // Fallback for plain-JS objects (shouldn't happen for live handles)
        if (toplevel._sourceKey !== undefined && toplevel._sourceKey !== null)
            return String(toplevel._sourceKey)
        return ""
    }
}
