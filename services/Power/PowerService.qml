pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Power management commands — lock, suspend, reboot, shutdown.
Singleton {
    id: root

    function lock(): void { lockProc.running = true }
    function suspend(): void { suspendProc.running = true }
    function reboot(): void { rebootProc.running = true }
    function shutdown(): void { shutdownProc.running = true }

    Process { id: lockProc;     command: ["loginctl", "lock-session"]; running: false }
    Process { id: suspendProc;  command: ["systemctl", "suspend"];     running: false }
    Process { id: rebootProc;   command: ["systemctl", "reboot"];      running: false }
    Process { id: shutdownProc; command: ["systemctl", "poweroff"];    running: false }
}
