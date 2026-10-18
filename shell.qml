//@ pragma ShellId dock
//@ pragma DefaultEnv QT_QUICK_CONTROLS_STYLE=Basic
//@ pragma Env QT_LOGGING_RULES=quickshell.dbus.properties=false

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.dock

// Stand-alone dock — a self-contained Quickshell config.
//
//   qs -c dock              # run
//   qs kill -c dock         # stop
//
// Configure via ~/.config/quickshell/dock/config.json (dock.* keys + theme.accent /
// theme.dark). Pinned apps, position, style (panel | pill | macos) and all
// dock options behave exactly as in iNiR.

ShellRoot {
    id: root

    // Touch the singletons so Config loads its JSON and Appearance binds to the
    // accent before the dock evaluates its first bindings.
    readonly property var _forceConfig: Config
    readonly property var _forceAppearance: Appearance

    Dock { id: dock }

    // ── IPC ─────────────────────────────────────────────────────────
    //   qs ipc -c dock call dock showVolumeOsd
    //
    // niri's volume-up/down binds invoke this in addition to volume-osd.sh
    // (see ~/.config/niri/config.kdl). The dock reacts to volume only when
    // the sink LEVEL changes, so a press already sitting at the ceiling —
    // which `volume-osd.sh` re-sets to the same value — would otherwise
    // produce no feedback at all. This restores it: see Dock.showVolumeOsd().
    IpcHandler {
        target: "dock"
        function showVolumeOsd(): void { dock.showVolumeOsd() }
    }
}
