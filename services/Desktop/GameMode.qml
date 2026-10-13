pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// Stand-alone stub. The dock only reads GameMode.shouldHidePanels to decide
// whether to hide itself; a stand-alone dock is never in game mode.
Singleton {
    id: root
    property bool shouldHidePanels: false
}
