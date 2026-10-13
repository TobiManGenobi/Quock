pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property var _map: ({})
    property bool ready: false

    Process {
        id: _scanner
        command: ["sh", "-c", `
            for f in /usr/share/applications/*.desktop /usr/local/share/applications/*.desktop "$HOME/.local/share/applications/"*.desktop; do
                [ -f "$f" ] || continue
                id=$(basename "$f" .desktop)
                icon=$(grep -m1 '^Icon=' "$f" 2>/dev/null | cut -d= -f2-)
                name=$(grep -m1 '^Name=' "$f" 2>/dev/null | cut -d= -f2-)
                exec=$(grep -m1 '^Exec=' "$f" 2>/dev/null | cut -d= -f2-)
                # Chromium web-app entries are the only ones whose window id
                # cannot be matched by name, so their URL and WM class are
                # harvested too (see lookupDesktopId).
                wmclass=$(grep -m1 '^StartupWMClass=' "$f" 2>/dev/null | cut -d= -f2-)
                [ -z "$wmclass" ] && wmclass=$(printf '%s' "$exec" | sed -n 's/.*--class=\\([^ "]*\\).*/\\1/p')
                appurl=$(printf '%s' "$exec" | sed -n 's/.*--app=\\?"\\([^"]*\\)\\?".*/\\1/p')
                [ -n "$icon" ] && printf 'ENTRY\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$icon" "$name" "$exec" "$wmclass" "$appurl"
                # mock: DesktopEntry.actions drives a whole context-menu group
                # (dock_context_menu.cpp:207-217). Without this the
                # desktop-actions rows can never populate.
                awk -v id="$id" '
                    function flush() {
                        if (an != "") printf "ACTION\t%s\t%s\t%s\t%s\n", id, an, ae, ai
                        an = ""; ae = ""; ai = ""
                    }
                    /^\[/ {
                        # A new section: [Desktop Action Foo] continues the group,
                        # anything else ends it.
                        if (ina) flush()
                        ina = ($0 ~ /^\[Desktop Action/)
                        next
                    }
                    ina && /^Name=/ { an = substr($0, 6); next }
                    ina && /^Exec=/ { ae = substr($0, 6); next }
                    ina && /^Icon=/ { ai = substr($0, 6); next }
                    END { if (ina) flush() }
                ' "$f" 2>/dev/null
            done
        `]
        running: true
        stdout: StdioCollector {
            id: _collector
            onStreamFinished: {
                const map = {}
                const lines = (_collector.text || "").split("\n")
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i]
                    if (!line) continue
                    const parts = line.split("\t")
                    if (parts.length < 2) continue
                    if (parts[0] === "ACTION") {
                        // ACTION<TAB>id<TAB>name<TAB>exec<TAB>icon
                        const entry = map[parts[1]]
                        if (!entry) continue
                        const actExec = parts[3] || ""
                        ;(entry.actions = entry.actions || []).push({
                            name: parts[2] || "",
                            exec: actExec,
                            icon: parts[4] || "",
                            // DockAppButton.qml maps desktopEntry.actions and
                            // calls action.execute(), so expose it here rather
                            // than editing that file.
                            execute: () => {
                                if (!actExec) return false
                                // A .desktop Exec line carries field codes
                                // ("firefox %u"); passing them through would make
                                // the app open a file literally named "%u".
                                const cmd = root._stripFieldCodes(actExec)
                                Quickshell.execDetached(["sh", "-c", cmd])
                                return true
                            }
                        })
                        continue
                    }
                    // ENTRY<TAB>id<TAB>icon<TAB>name<TAB>exec<TAB>wmClass<TAB>appUrl
                    map[parts[1]] = {
                        icon: parts[2] || "",
                        name: parts[3] || parts[1],
                        exec: parts[4] || "",
                        wmClass: parts[5] || "",
                        appUrl: parts[6] || "",
                        actions: []
                    }
                }
                root._map = map
                root.ready = true
            }
        }
    }

    // Re-run the scan.
    //
    // The dock reads every app's `Icon=` from this map, so an entry rewritten
    // on disk (IconOverride, i.e. the dock's "Change icon") is only picked up
    // by scanning again. Assigning `running: true` to an already-finished
    // Process would be a no-op, hence the false -> true flip deferred by
    // callLater. `ready` stays true and `_map` is only replaced when the new
    // output arrives, so nothing flickers while the scan runs.
    function refresh(): void {
        if (_scanner.running) return
        _scanner.running = false
        Qt.callLater(() => { _scanner.running = true })
    }

    // Parse a .desktop Exec= line into an argv array, per the freedesktop
    // Desktop Entry Specification.
    //
    // The line is tokenized first (quoting + backslash escapes), then field
    // codes are resolved inside each token:
    //   %%              a literal "%"
    //   %f %F           one file / a list of files
    //   %u %U           one URL / a list of URLs
    //   %i              --icon <Icon>, or empty when Icon= is unset
    //   %c              the translated Name=
    //   %d %D %n %N %k %v %m  deprecated / undefined here
    // We always launch with no file and no URL, so every legacy code is
    // removed; a token left empty by the removal is dropped entirely (the
    // spec's own rule), which is what makes Nautilus come up as a bare
    // `nautilus --new-window` rather than `nautilus --new-window ""`.
    function _execArgv(exec) {
        const src = String(exec ?? "")
        const argv = []
        let cur = ""
        let have = false
        let i = 0
        while (i < src.length) {
            const ch = src[i]
            // Whitespace separates arguments, but only outside quotes.
            if (ch === " " || ch === "\t") {
                if (have) { argv.push(cur); cur = ""; have = false }
                i++
                continue
            }
            // Double quotes group an argument and are removed from it. A
            // backslash inside quotes escapes only the characters the spec
            // reserves ("`$\), otherwise it stays literal.
            if (ch === "\"") {
                have = true
                i++
                while (i < src.length && src[i] !== "\"") {
                    if (src[i] === "\\") {
                        const next = src[i + 1]
                        if (next === "\"" || next === "`" || next === "$" || next === "\\") {
                            cur += next
                            i += 2
                            continue
                        }
                    }
                    cur += src[i]
                    i++
                }
                i++ // closing quote
                continue
            }
            // Outside quotes a backslash escapes the next character.
            if (ch === "\\" && i + 1 < src.length) {
                cur += src[i + 1]
                have = true
                i += 2
                continue
            }
            // Field codes.
            if (ch === "%" && i + 1 < src.length) {
                const code = src[i + 1]
                if (code === "%") {
                    cur += "%"
                    have = true
                    i += 2
                    continue
                }
                // Every remaining code is one we launch with nothing for, so
                // it contributes nothing to the argument.
                i += 2
                continue
            }
            cur += ch
            have = true
            i++
        }
        if (have) argv.push(cur)
        return argv.filter(arg => arg !== "")
    }

    // Single-quote an argument for /bin/sh.
    function _shellQuote(arg): string {
        return "'" + String(arg).replace(/'/g, "'\\''") + "'"
    }

    // A .desktop Exec line as a ready-to-run shell command, with the field
    // codes resolved away. A line whose only argument was a field code
    // collapses to the bare program name, never to `program ""`.
    function _stripFieldCodes(exec): string {
        return root._execArgv(exec).map(root._shellQuote).join(" ")
    }

    function _kebab(str) {
        return str.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase()
    }

    function lookupDesktopId(appId) {
        const id = String(appId ?? "")
        if (!id || id === "SEPARATOR") return ""

        if (_map[id]) return id

        // Running processes often carry a script extension the desktop entry
        // omits ("webapp-manager.py" → webapp-manager.desktop).
        const stripped = id.replace(/\.(py|sh|bin|pl|rb|js)$/, "")
        if (stripped !== id && _map[stripped]) return stripped

        const parts = id.split(".")
        if (parts.length > 1) {
            const last = parts[parts.length - 1]
            if (_map[last]) return last
            const kebab = _kebab(last)
            if (_map[kebab]) return kebab
            const kebabFull = _kebab(id)
            if (_map[kebabFull]) return kebabFull
        }

        return ""
    }

    function lookupDesktopEntry(appId) {
        // desktopIdForWindow, not lookupDesktopId: a window whose id names no
        // entry (a Chromium web app) still has one, and this is what every
        // caller uses to reach the entry's Icon=.
        const desktopId = root.desktopIdForWindow(appId)
        return desktopId ? _map[desktopId] : null
    }

    function guessIcon(str): string {
        const e = root.lookupDesktopEntry(str)
        return e?.icon ?? ""
    }

    // A window id -> desktop-entry id, for ids that name no entry at all.
    //
    // Chromium runs a web app as `chromium --app=URL --class=NAME`, and the
    // compositor then reports the window as
    //   chrome-app.<host>__<slug>-Default
    // e.g. `chrome-app.openpencil.dev__demo-Default`. That matches no desktop
    // id and no kebab variant of one, so lookupDesktopId returned "" and the
    // dock used the raw id as an icon name — which no theme ships, so the slot
    // fell back to the generic glyph.
    //
    // Two matches are tried, cheapest first:
    //   1. the window id against StartupWMClass / --class= of every entry
    //   2. the host in a `chrome-app.` id against the --app= URL of web-app
    //      entries, matching the host or any subdomain of it
    //      (app.openpencil.dev serves the chrome-app.openpencil.dev window)
    function _matchByWmClass(id) {
        for (const key in _map) {
            const cls = _map[key].wmClass
            if (cls && (cls === id || _kebab(cls) === _kebab(id))) return key
        }
        return ""
    }

    function _hostOf(url) {
        const m = String(url).match(/^[a-z]+:\/\/([^/:?#]+)/i)
        return m ? m[1].toLowerCase() : ""
    }

    function _matchByWebAppHost(id) {
        // Gated to `chrome-app.` ids on purpose. Without the gate a reverse-DNS
        // window id such as org.gnome.Nautilus would be read as a host and
        // could be captured by some unrelated entry's --app= URL.
        if (!/^chrome-app\./i.test(String(id))) return ""
        const host = String(id).replace(/^chrome-app\./i, "").split("__")[0].toLowerCase()
        if (!host || host.indexOf(".") === -1) return ""
        for (const key in _map) {
            const urlHost = _hostOf(_map[key].appUrl)
            if (urlHost && (urlHost === host || urlHost.endsWith("." + host))) return key
        }
        return ""
    }

    // The desktop-entry id for a window id, or "" when there is none. The
    // direct id/name matches win; these are only fallbacks for windows whose
    // id names nothing (web apps, AppImages).
    function desktopIdForWindow(appId) {
        const id = String(appId ?? "")
        if (!id || id === "SEPARATOR") return ""
        return lookupDesktopId(id) || _matchByWmClass(id) || _matchByWebAppHost(id)
    }
}
