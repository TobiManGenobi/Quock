pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// Stand-alone subset of iNiR's GlobalStates. Only the state flags the dock
// actually consumes are modelled; everything defaults to a sensible "running,
// unlocked, ready" state so the dock is visible out of the box.

Singleton {
    id: root

    // Read by Dock.qml to gate visibility / reveal.
    property bool shellEntryReady: true
    property bool screenLocked: false
    property bool widgetEditMode: false
    property bool coverflowSelectorOpen: false
}
