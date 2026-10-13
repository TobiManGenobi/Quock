pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// i18n passthrough. A stand-alone dock ships no translation catalogs, so tr()
// returns its input verbatim.

Singleton {
    id: root

    function tr(text): string {
        if (!text) return ""
        return text.toString()
    }
}
