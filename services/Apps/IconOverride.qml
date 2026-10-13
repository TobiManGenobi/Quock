pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services.Apps

// ─── Systemwide dock icon overrides ("Change icon") ────────────────────
//
// WHAT THIS DOES. Right-clicking a dock icon and picking "Change icon"
// rewrites the `Icon=` line of that application's desktop entry, so the new
// artwork shows up in the dock, in the panel launcher, in any menu launcher
// and in `gtk-launch`, not just in this dock.
//
// WHERE THE WRITE IS ALLOWED TO LAND — and this is the one rule that must
// never be relaxed:
//
//   ~/.local/share/applications/<filename>.desktop
//
// A file in the user's applications directory SHADOWS the file of the same
// name in a system directory: the XDG desktop-entry lookup walks
// $XDG_DATA_HOME (i.e. ~/.local/share/applications) before the system data
// directories and stops at the first hit. So the user's copy is the
// sanctioned, root-free, reversible way to override a packaged entry. This
// service therefore NEVER writes to /usr/share/applications,
// /usr/local/share/applications or anything else under a system prefix, and
// it never escalates — no sudo, no pkexec, no polkit prompt. When the entry
// exists only as a system file, the file is COPIED into the user directory
// first and the copy is edited; the system file is left untouched, so a
// package upgrade can never clobber the override.
//
// BACKUPS. Every write is preceded by a copy into
// ~/.local/state/quickshell-dock-backup/desktop-entries/, the dock config's
// established durable-backup location. When a user entry already existed,
// that pre-change copy is what is saved, so the whole operation can be
// undone. When it did not, the pristine SYSTEM entry is saved instead, as
// `<filename>.desktop.system-original`, so the original Icon= survives the
// copy verbatim. Nothing here ever unlinks a desktop entry: "reset" restores
// content over the user copy rather than deleting it.
//
// THE REWRITE (rewriteIconText) is surgical — it replaces ONE line and leaves
// every other byte alone: localized Name[…], Exec=, StartupWMClass=,
// Terminal=, MimeType=, Actions= and every [Desktop Action …] stanza. The file
// is never regenerated from a parsed model; regenerating is exactly what
// silently drops keys this dock knows nothing about.
//
// CANCELLATION. Nothing is written until a picker has returned a path AND the
// confirmation dialog has been accepted. Cancelling either step leaves the
// filesystem untouched — a cancelled picker is zenity's exit code 1 and is
// simply ignored.
Singleton {
    id: root

    // ─── Paths ────────────────────────────────────────────────────────
    readonly property string home: Quickshell.env("HOME") ?? ""

    // The ONLY applications directory this service ever writes into.
    readonly property string userAppsDir: home + "/.local/share/applications"

    // Read-only sources, in XDG lookup order. Never written to.
    readonly property var systemAppsDirs: [
        "/usr/local/share/applications",
        "/usr/share/applications"
    ]

    // Established durable backup location for this dock config.
    readonly property string backupDir: home + "/.local/state/quickshell-dock-backup/desktop-entries"

    // Image types the picker offers and this service will accept.
    readonly property var imageExtensions: ["png", "svg", "jpg", "jpeg", "webp", "xpm"]

    // ─── Directory inventory ──────────────────────────────────────────
    //
    // dir -> { "<filename>.desktop": true }
    //
    // Held as a map rather than probed with `test -f` per question, so that
    // locate() and hasUserOverride() are plain synchronous functions: the dock
    // context menu builds its rows inside a `readonly property var` binding,
    // and an asynchronous probe cannot be awaited from there.
    property var _entriesByDir: ({})

    // True once at least one listing pass has produced an inventory. The scan
    // is a Process, so _entriesByDir stays empty for the whole of its first
    // run; a caller that resolves an id inside that window sees null and must
    // not conclude the entry does not exist.
    property bool inventoryReady: false

    // Bumped after every inventory pass so that bindings which asked "did this
    // app have an override?" re-evaluate when the answer changes.
    property int _revision: 0

    // ─── Run state ────────────────────────────────────────────────────
    property bool busy: false
    property string lastError: ""

    // The job in flight. `plan` carries everything the confirmation dialog
    // needs to describe the write before it happens.
    property var _plan: null
    property int _step: 0
    property string _stamp: ""

    // Emitted after a desktop entry was rewritten, so the dock can pick up the
    // new Icon= without a restart.
    signal iconChanged(string desktopId)

    function _fileName(id): string {
        return String(id ?? "") + ".desktop"
    }

    function userPathFor(id): string {
        return root.userAppsDir + "/" + root._fileName(id)
    }

    // Everything known about where an entry for `id` lives:
    //   userPath     — the only file this service may ever write
    //   userExists   — whether the user copy is already there
    //   systemPath   — the packaged file, or "" when there is none
    //   copy         — true when the packaged file must be copied first
    // Returns null when no directory ships the entry at all.
    function locate(id) {
        const name = root._fileName(id)
        if (!id || id === "SEPARATOR" || !name || name === ".desktop") return null
        // User directory first — the same precedence the system uses, so this
        // matches what a launcher will actually load.
        const userExists = root._entriesByDir[root.userAppsDir]?.[name] === true
        let systemPath = ""
        for (const dir of root.systemAppsDirs) {
            if (root._entriesByDir[dir]?.[name]) {
                systemPath = dir + "/" + name
                break
            }
        }
        if (!userExists && systemPath === "") return null
        return {
            id: String(id),
            userPath: root.userPathFor(id),
            userExists: userExists,
            systemPath: systemPath,
            copy: !userExists
        }
    }

    // True when the user directory already shadows this app. Drives the
    // "Reset icon to default" row, which is pointless without an override.
    function hasUserOverride(id): bool {
        const name = root._fileName(id)
        if (!id || !name) return false
        // Touching _revision makes the dependency explicit for callers that
        // evaluate this inside a binding.
        return (root._entriesByDir[root.userAppsDir]?.[name] === true) && root._revision >= 0
    }

    // ─── Inventory scan ───────────────────────────────────────────────
    //
    // One listing pass over the user and the two system directories. The
    // directories are baked into the script as JSON-quoted literals (they are
    // fixed constants, never user input) and the names come back from `ls -1`
    // verbatim, so no filename is ever handed to a shell as syntax.
    function _scanScript(): string {
        let s = ""
        for (const dir of [root.userAppsDir].concat(root.systemAppsDirs)) {
            s += 'd=' + JSON.stringify(dir) + '; '
                + '[ -d "$d" ] || continue; '
                + 'echo "@@DIR $d"; '
                + 'ls -1 "$d" 2>/dev/null | grep -e "\\.desktop$"; '
                + 'echo "@@END"; '
        }
        return s
    }

    Process {
        id: _scanProc
        running: false
        command: ["/usr/bin/env", "sh", "-c", root._scanScript()]
        stdout: StdioCollector {
            id: _scanOut
            onStreamFinished: {
                const map = ({})
                let dir = null
                for (const raw of (_scanOut.text || "").split("\n")) {
                    const line = raw.trim()
                    // "@@DIR " is six characters ("@@DIR" plus one space),
                    // so slice(6) — not slice(7) — keeps the leading "/" of
                    // the directory path.
                    if (line.startsWith("@@DIR ")) {
                        dir = line.slice(6)
                        map[dir] = ({})
                    } else if (line === "@@END") {
                        dir = null
                    } else if (dir !== null && line.endsWith(".desktop")) {
                        map[dir][line] = true
                    }
                }
                root._entriesByDir = map
                root._revision++
                // The listing is only usable once it has landed. Callers that
                // resolve an entry on demand (the "Change icon…" row) wait on
                // this rather than reading a still-empty map.
                root.inventoryReady = true
            }
        }
    }

    function refresh(): void {
        _scanProc.running = true
    }


    // ─── The rewrite ──────────────────────────────────────────────────
    //
    // Replace the main group's Icon= line with `value`, and nothing else.
    //
    // Two rules, both derived from the group structure:
    //
    // 1. REPLACE. Only an `Icon=` in the FIRST section's body is the
    //    application's own — `[Desktop Entry]` is the first header and its
    //    keys follow it, and the body ends at the next header. An `Icon=`
    //    inside a `[Desktop Action …]` stanza belongs to that action and must
    //    never be touched.
    // 2. INSERT. When the main group has no Icon= at all, the new line goes
    //    at the END OF THAT GROUP — immediately before the SECOND section
    //    header, or before the file's trailing newline when there is none.
    //    Inserting BEFORE the first header would put the key outside any
    //    group, which makes the entry invalid.
    //
    // Splitting and rejoining on "\n" keeps every untouched line — comments,
    // blank lines, localized Name[…], ordering — byte-identical.
    function rewriteIconText(text, value): string {
        const lines = String(text ?? "").split("\n")
        // Section headers, tolerating CRLF ("[Desktop Entry]\r" does not end
        // with "]"). Without this a CRLF entry has no headers at all, which
        // both hides the main group's extent and lets an action stanza's
        // Icon= be mistaken for the application's own.
        const headers = []
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].replace(/\r$/, "")
            if (line.startsWith("[") && line.endsWith("]"))
                headers.push(i)
        }
        // The main group is the FIRST header's body: [Desktop Entry] is line
        // 0, so its keys live AFTER it, and they end at the second header
        // (the first [Desktop Action …]) or at end of file.
        const groupStart = headers.length > 0 ? headers[0] + 1 : 0
        const groupEnd = headers.length > 1 ? headers[1] : lines.length
        // A CRLF file's lines still carry their \r, so the replacement has to
        // put it back or the entry is joined into one line.
        let eol = ""
        for (let i = 0; i < lines.length; i++) {
            if (lines[i] !== "") { eol = lines[i].endsWith("\r") ? "\r" : ""; break }
        }
        for (let i = groupStart; i < groupEnd; i++) {
            if (lines[i].replace(/\r$/, "").startsWith("Icon=")) {
                lines[i] = "Icon=" + String(value) + eol
                return lines.join("\n")
            }
        }
        let at = groupEnd
        // A file ending in "\n" splits with a trailing empty element; insert
        // before it so the new line still gets its own terminator. Never
        // before groupStart, which would put the key outside any group.
        if (at === lines.length && at > groupStart && lines[at - 1] === "")
            at -= 1
        lines.splice(at, 0, "Icon=" + String(value) + eol)
        return lines.join("\n")
    }

    // ─── Change icon ──────────────────────────────────────────────────
    //
    // `plan` is normally the locate() result the confirmation dialog showed
    // the user, so the dialog and the write cannot disagree.
    function apply(id, imagePath, plan): bool {
        if (root.busy) return false
        const p = plan || root.locate(id)
        if (!p) {
            root.fail("No desktop entry found for this app")
            return false
        }
        const value = root.iconValueFor(imagePath)
        if (value === null) {
            root.fail("Not an image file: " + imagePath)
            return false
        }
        root.busy = true
        root.lastError = ""
        root._plan = Object.assign({}, p, { value: value, reset: false })
        root._stamp = root._timeStamp()
        root._step = 0
        _job.command = root._nextCommand()
        _job.running = true
        return true
    }

    // The Icon= value: the absolute path, verbatim and unquoted. Icon is a
    // plain string in the desktop-entry spec, so a path containing spaces
    // needs no escaping; IconThemeService.smartIconName turns a leading "/"
    // into a file:// URL when the dock resolves it. Returns null when the path
    // is not absolute or does not carry an accepted image extension — the
    // caller must treat that as a refusal and write nothing.
    function iconValueFor(imagePath): string {
        const raw = String(imagePath ?? "").trim()
        if (!raw.startsWith("/")) return null
        if (raw.indexOf("\n") >= 0 || raw.indexOf("\r") >= 0) return null
        const dot = raw.lastIndexOf(".")
        if (dot < 0 || dot === raw.length - 1) return null
        return root.imageExtensions.indexOf(raw.slice(dot + 1).toLowerCase()) === -1
            ? null
            : raw
    }

    function _timeStamp(): string {
        const d = new Date()
        const p = n => String(n).padStart(2, "0")
        return d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate())
            + "-" + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds())
    }

    function backupPathFor(id): string {
        return root.backupDir + "/" + root._fileName(id) + "." + root._stamp
    }

    // ─── Reset to the system default ──────────────────────────────────
    //
    // Copies the packaged entry back over the user copy. The packaged file IS
    // the original — it is exactly what was copied on the first override — so
    // this restores the default Icon= without unlinking anything. (If the
    // package was upgraded in between, the per-change backup written by
    // apply() still holds the state at the moment of the change.)
    function reset(id): bool {
        if (root.busy) return false
        const p = root.locate(id)
        if (!p) {
            root.fail("No desktop entry found for this app")
            return false
        }
        if (!p.userExists) {
            root.fail("No icon override to reset")
            return false
        }
        if (p.systemPath === "") {
            root.fail("No system entry to restore from")
            return false
        }
        root.busy = true
        root.lastError = ""
        root._plan = Object.assign({}, p, { value: "", reset: true })
        root._stamp = root._timeStamp()
        root._step = 0
        _job.command = root._nextCommand()
        _job.running = true
        return true
    }

    // ─── Step machine ─────────────────────────────────────────────────
    //
    // Every command is an argv array; mkdir/cp run directly, never through a
    // shell, so no filename can be reinterpreted as syntax.
    function _nextCommand() {
        const p = root._plan
        if (!p) return null
        if (p.reset) {
            switch (root._step) {
            case 0:
                // Keep the overridden entry too, so a reset is itself
                // reversible without relying on the packaged file.
                return ["/usr/bin/env", "mkdir", "-p", root.backupDir]
            case 1:
                return ["/usr/bin/env", "cp", "-p", p.userPath, root.backupPathFor(p.id) + ".override"]
            case 2:
                return ["/usr/bin/env", "cp", "-p", p.systemPath, p.userPath]
            default:
                return null
            }
        }
        switch (root._step) {
        case 0:
            return ["/usr/bin/env", "mkdir", "-p", root.backupDir]
        case 1:
            // Preserve what is about to be overwritten: the pre-existing USER
            // entry when there is one, otherwise the pristine SYSTEM entry.
            return p.copy
                ? ["/usr/bin/env", "cp", "-p", p.systemPath, root.backupPathFor(p.id) + ".system-original"]
                : ["/usr/bin/env", "cp", "-p", p.userPath, root.backupPathFor(p.id)]
        case 2:
            return p.copy ? ["/usr/bin/env", "cp", "-p", p.systemPath, p.userPath] : null
        default:
            return null
        }
    }

    function _nextStepCount(): int {
        const p = root._plan
        if (!p) return 0
        return p.reset ? 3 : (p.copy ? 3 : 2)
    }

    Process {
        id: _job
        running: false
        function onExited(exitCode, exitStatus) {
            const code = exitCode
            const p = root._plan
            if (code !== 0) {
                // A failed step aborts the whole job. Note that a failure of
                // the copy step leaves only a backup behind — the target entry
                // was never opened for writing.
                root.fail("Failed to prepare " + (p ? p.userPath : "") + " (exit " + code + ")")
                return
            }
            if (root._step + 1 >= root._nextStepCount()) {
                if (p.reset) {
                    root.succeed(p.id, true)
                    return
                }
                // The target now exists in the user directory; load it, change
                // the single line, write it back.
                _edit.path = p.userPath
                return
            }
            root._step++
            _job.command = root._nextCommand()
            _job.running = true
        }
    }

    FileView {
        id: _edit
        // Only [Desktop Entry]'s Icon= may change. atomicWrites keeps a
        // half-written entry from ever being observed by a menu that rescans
        // ~/.local/share/applications.
        atomicWrites: true
        onLoaded: {
            const p = root._plan
            let text = ""
            try {
                text = _edit.text()
            } catch (e) {
                root.fail("Could not read " + (p ? p.userPath : ""))
                return
            }
            const updated = root.rewriteIconText(text, p.value)
            if (updated === text) {
                // Already exactly this value: idempotent, and nothing written.
                root.succeed(p.id, false)
                return
            }
            try {
                _edit.setText(updated)
            } catch (e) {
                root.fail("Could not write " + p.userPath)
            }
        }
        onSaveFailed: root.fail("Could not write " + (root._plan ? root._plan.userPath : ""))
        onSaved: root.succeed(root._plan.id, true)
        onLoadFailed: root.fail("Could not read " + (root._plan ? root._plan.userPath : ""))
    }

    // ─── Picker start directory ───────────────────────────────────────
    //
    // ~/Pictures is where a user's own artwork usually is;
    // ~/.local/share/icons is the fallback for people who install icons
    // rather than keep pictures. Resolved ONCE, here, rather than per dock
    // delegate: a dock with fifteen icons must not run fifteen probes. The
    // paths are this config's own constants, so they are baked into the script
    // as JSON-quoted literals and never come from user input.
    property string pickerStartDir: root.home + "/"
    readonly property string _picturesDir: root.home + "/Pictures"
    readonly property string _iconsDir: root.home + "/.local/share/icons"

    Process {
        id: _startDirProbe
        running: false
        command: ["/usr/bin/env", "sh", "-c",
            "for d in " + JSON.stringify(root._picturesDir) + " "
            + JSON.stringify(root._iconsDir) + " " + JSON.stringify(root.home)
            + "; do [ -d \"$d\" ] && { printf %s \"$d/\"; exit 0; }; done; exit 1"]
        stdout: StdioCollector {
            id: _startDirOut
            onStreamFinished: {
                const dir = (_startDirOut.text || "").trim()
                if (dir !== "") root.pickerStartDir = dir
            }
        }
        function onExited(exitCode, exitStatus) {
            if (exitCode !== 0) {
                // Not even the home directory exists: leave the default.
                console.warn("dock IconOverride: no picker start directory found")
            }
        }
    }


    function succeed(id, changed): void {
        const p = root._plan
        root.busy = false
        root._plan = null
        // Re-list first (so hasUserOverride() is true immediately) and re-scan
        // the desktop entries: AppSearch is the dock's source of `Icon=`, and
        // re-running it is what makes the icon change on screen without a
        // restart. Its old map is kept until the new one lands, so nothing
        // flickers.
        root.refresh()
        if (changed) {
            AppSearch.refresh()
            root.iconChanged(String(id))
        }
        console.log("dock IconOverride:",
            p && p.reset ? "restored" : (changed ? "Icon= written" : "Icon= already set"),
            "for", id, "->", p ? p.userPath : "")
    }

    function fail(message): void {
        root.busy = false
        root.lastError = message
        root._plan = null
        console.warn("dock IconOverride:", message)
    }

    // ─── Startup ──────────────────────────────────────────────────────
    //
    // ensureReady() is idempotent and is the only place a probe is ever
    // started, so a caller can be sure the inventory is being rebuilt no
    // matter which entry point ran first.
    //
    // A Timer, not Component.onCompleted: this singleton is created during
    // engine setup, and processes requested from onCompleted there were
    // silently dropped. The timer runs one event-loop turn after the singleton
    // is first used, which is always long before a context menu is opened.
    function ensureReady(): void {
        if (root._probed) return
        root._probed = true
        root.refresh()
        _startDirProbe.running = true
    }

    property bool _probed: false

    Timer {
        interval: 0
        running: true
        onTriggered: root.ensureReady()
    }
}
