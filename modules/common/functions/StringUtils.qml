pragma Singleton
import Quickshell

Singleton {
    id: root

    /**
     * Converts a string to Title Case.
     * @param { string } str
     * @returns { string }
     */
    function toTitleCase(str) {
        if (!str)
            return "";
        return str.replace(/\w\S*/g, function(txt) {
            return txt.charAt(0).toUpperCase() + txt.substr(1).toLowerCase();
        });
    }
}
