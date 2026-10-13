pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
// This config keeps its singletons in services/Apps/, so the sibling module is
// qs.services.Apps (AppSearch.lookupDesktopEntry / guessIcon come from there).
// The dock_icon_fix copy lives one directory up and imports plain qs.services.
import qs.services.Apps

// Icon resolution for dock items.
//
// Two jobs:
//
// 1. NAME -> FILE. The dock uses the icon the app itself exposes (the .desktop
//    `Icon=` value, falling back to its app id). Quickshell's icon provider
//    turns that name into an `image://icon/<name>` URL — but that is NOT a file
//    path, and it resolves nothing useful here: the active theme
//    (~/.local/share/icons/Colloid) ships almost no icons, so every icon falls
//    through to a name that decodes to nothing. A small index of the icon trees
//    is therefore needed to find the real file. This mirrors the mock's
//    IconResolver (mock/src/system/icon_resolver.cpp), which walks themes and
//    keeps hicolor last.
//
// 2. SVG -> PNG. Qt's SVG image plugin (libqsvg) implements only part of SVG
//    Tiny 1.2. Gradients carrying a `gradientTransform` matrix — used by
//    Colloid's zen.svg and terminal.svg — are mishandled: Qt logs "Could not
//    resolve property" at the closing </svg> and paints the icon partially or
//    not at all. There is no Qt setting for this, and it is a renderer defect,
//    so it cannot be configured away. Instead each SVG is rasterised once with
//    rsvg-convert (librsvg) — the same renderer family the C++ mock uses — and
//    Qt is handed a PNG, which it renders natively. The mock gets the same
//    effect by linking librsvg directly.
//
//    ImageMagick is NOT used. `magick` genuinely fails on exactly these
//    files (measured; the "SVG rasterisation" block below carries the full
//    evidence): exit 1 and no output file, because ImageMagick routes .svg to
//    its own internal MSVG/MVG coder, which cannot parse CSS paint-server
//    references such as fill="url(#gradient-0)". rsvg-convert succeeds on the
//    same input.
//
//    THE RULE: an Image is NEVER given an SVG URL. rasterOrBlank() is the only
//    sanctioned way to ask for icon artwork; it returns the PNG, or "" while the
//    conversion is still queued. Callers gate on rasterPending() during that
//    window, so the dock stays hidden instead of showing artwork Qt renders
//    wrong.

Singleton {
    id: root

    // ─── Icon index (name -> real file) ───────────────────────────────
    //
    // Port of WayRun's icon theme resolver
    // (WayRun/core/src/system/icon/theme.rs). The previous version indexed
    // EVERY icon file on disk with a brute-force `find` and guessed an
    // icon's size from substrings of its path (`/scalable/`, `/48x48/`, ...),
    // which is fragile and unbounded. This version does what the icon theme
    // SPEC says:
    //
    //   1. read each theme's `index.theme` (Directories=, Inherits=, and each
    //      directory's Size/Type/MinSize/MaxSize/Scale)
    //   2. walk `Inherits` breadth-first from the active theme, hicolor last
    //   3. only ever list the directories the theme DECLARES
    //
    // That turns a 600k-line full-disk scan into a few dozen bounded
    // one-directory finds.

    // Icon theme roots, in lookup order. XDG default dirs plus the two
    // per-user ones; /usr/local/share/icons matches the spec default and
    // WayRun's data_dirs() fallback.
    readonly property var _roots: [
        (Quickshell.env("HOME") ?? "") + "/.local/share/icons",
        (Quickshell.env("HOME") ?? "") + "/.icons",
        "/usr/local/share/icons",
        "/usr/share/icons"
    ]
    // Flat rasters outside any theme. Not a root for index.theme: it has no
    // theme directories, only loose files.
    readonly property string _pixmaps: "/usr/share/pixmaps"
    // Pseudo-theme key for _pixmaps inside the lookup order. The trailing
    // slash cannot collide with a real theme name (theme names never contain
    // one), and needs no escape sequence in this file.
    readonly property string _pixmapKey: "pixmaps/"

    // "theme|root" -> { dirs: [{path,size,min,max,scale,ord}], inherits: [] }
    //
    // Keyed per ROOT, not per theme: a theme can be spread over several roots
    // and each root's index.theme describes only that root's copy. WayRun
    // pairs them the same way (chain_for builds Vec<(PathBuf, Option<ThemeIndex>)>,
    // theme.rs:212-239), and merging them changes which directories exist.
    property var _themeIndexes: ({})
    // Ordered theme names: active theme, then Inherits breadth-first, hicolor
    // last. Inheritance is read from the FIRST root that ships an index.theme
    // (index_for, theme.rs:174).
    property var _chain: []
    // Ordered { key, theme, root } pairs to search: chain order outer, root
    // order inner, then the /usr/share/pixmaps pseudo-pair. Built alongside the
    // listing scripts so the two can never disagree.
    property var _lookupPairs: []
    // "theme|root" -> { key -> [{path,tier,dist,ord,ext}] }, keyed by
    // lowercase icon name without extension.
    property var _themeFiles: ({})
    // Listing scripts still to run, one per Process invocation. Split into
    // chunks so no single one exceeds the argv element limit; see
    // _buildFileChunks().
    property var _fileChunks: []
    // The user's icon theme (from GSettings); the chain starts here.
    property string _activeTheme: ""
    property bool _indexReady: false

    // ─── Parsing (port of parse_index / split_list, theme.rs:29-114) ───

    function _splitList(value) {
        return String(value).split(",").map(s => s.trim()).filter(s => s !== "")
    }

    // One directory record per `Directories` entry. A missing `Size` leaves
    // the range fully open so the directory is never skipped.
    function _parseIndexTheme(text) {
        let order = []
        let inherits = []
        let section = ""
        let header = false
        const attrs = ({})

        for (const raw of String(text).split("\n")) {
            const line = raw.trim()
            if (!line || line.startsWith("#")) continue
            if (line.startsWith("[") && line.endsWith("]")) {
                section = line.slice(1, -1).trim()
                header = section === "Icon Theme"
                continue
            }
            const eq = line.indexOf("=")
            if (eq < 0) continue
            const key = line.slice(0, eq).trim()
            const value = line.slice(eq + 1).trim()
            if (header) {
                if (key === "Directories") order = root._splitList(value)
                else if (key === "Inherits") inherits = root._splitList(value)
            } else if (section !== "") {
                if (!(section in attrs)) attrs[section] = ({})
                attrs[section][key] = value
            }
        }

        const dirs = []
        for (const name of order) {
            const a = attrs[name] || ({})
            const num = k => {
                if (!(k in a)) return undefined
                const n = parseInt(a[k], 10)
                return isNaN(n) || n < 0 ? undefined : n
            }
            const size = num("Size") !== undefined ? num("Size") : 0
            const scale = num("Scale") !== undefined ? num("Scale") : 1
            const ty = "Type" in a ? a["Type"].toLowerCase() : undefined
            let min, max
            if (ty === "fixed") {
                min = size
                max = size
            } else if (ty === "scalable") {
                min = num("MinSize") !== undefined ? num("MinSize") : size
                max = num("MaxSize") !== undefined ? num("MaxSize") : size
            } else {
                const threshold = num("Threshold") !== undefined ? num("Threshold") : 2
                min = Math.max(0, size - threshold)
                max = size + threshold
            }
            if (size === 0) { min = 0; max = 65535 }
            // `ord` is the position in `Directories=`. WayRun sorts candidate
            // directories by rank with a STABLE sort, so equally ranked
            // directories keep declaration order — which decides the winner
            // before the extension ever matters.
            dirs.push({ path: name, size: size, min: min, max: max, scale: scale, ord: dirs.length })
        }
        // A body without [Icon Theme] yields an empty index; it is still
        // stored so the lookup can tell "no usable index" from "unknown".
        return { dirs: dirs, inherits: inherits }
    }

    // ─── Chain (port of theme_chain_from, theme.rs:184-201) ─────────────
    //
    // `seen` makes it cycle-safe, and hicolor is always appended last so it
    // stays the guaranteed fallback rather than an early hit.
    function _buildChain(start) {
        const chain = []
        const seen = ({})
        const queue = [start]
        let head = 0
        while (head < queue.length) {
            const theme = queue[head++]
            if (seen[theme]) continue
            seen[theme] = true
            const idx = root._indexFor(theme)
            if (idx)
                for (const inherited of idx.inherits) queue.push(inherited)
            chain.push(theme)
        }
        if (!seen["hicolor"]) chain.push("hicolor")
        return chain
    }

    // The parsed index.theme of `theme` from the FIRST root that ships one
    // (port of index_for, theme.rs:174), or null when no root has one.
    function _indexFor(theme) {
        for (const r of root._roots) {
            const idx = root._themeIndexes[theme + "|" + r]
            if (idx) return idx
        }
        return null
    }

    // The index of one SPECIFIC root, or null. Null means "no usable
    // index.theme here", which is not the same as "no such theme".
    function _indexAt(theme, r) {
        return root._themeIndexes[theme + "|" + r] || null
    }

    // ─── Phase 1: harvest every theme's index.theme ─────────────────────
    //
    // No `find` here at all: only index.theme files are read, so this is a few
    // dozen small cats.
    function _harvestScript() {
        let s = 't=$(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null'
            + ' | sed "s/^.//;s/.$//"); echo "@@THEME $t"; '
        for (const r of root._roots) {
            s += 'for d in "' + r + '"/*/; do [ -f "$d/index.theme" ] || continue; '
                + 'n=${d%/}; n=${n##*/}; echo "@@INDEX $n|' + r + '"; '
                + 'cat "$d/index.theme"; echo "@@END"; done; '
        }
        return s
    }

    Process {
        id: _indexProc
        running: false
        command: ["/usr/bin/env", "sh", "-c", root._harvestScript()]
        stdout: StdioCollector {
            onStreamFinished: {
                const indexes = ({})
                let theme = ""
                let body = []
                let name = null

                // Keyed by theme AND root: a theme is spread across roots and
                // each root's index.theme describes only that root's own copy,
                // so the two must not be merged.
                const flush = () => {
                    if (name !== null && !(name in indexes))
                        indexes[name] = root._parseIndexTheme(body.join("\n"))
                    name = null
                    body = []
                }

                for (const raw of this.text.split("\n")) {
                    const line = raw.trim()
                    if (line.startsWith("@@THEME ")) {
                        flush()
                        theme = line.slice(8).trim()
                    } else if (line.startsWith("@@INDEX ")) {
                        flush()
                        name = line.slice(8).trim()
                    } else if (line === "@@END") {
                        flush()
                    } else if (name !== null) {
                        body.push(raw)
                    }
                }
                flush()

                root._themeIndexes = indexes
                root._activeTheme = theme || "hicolor"
                root._chain = root._buildChain(root._activeTheme)
                console.log("dock IconThemeService: icon theme", root._activeTheme,
                            "chain", JSON.stringify(root._chain))
                root._fileChunks = root._buildFileChunks()
                root._startFiles()
                root._indexReady = true
            }
        }
    }

    // ─── Phase 2: list files inside DECLARED directories only ───────────
    //
    // One bounded find per declared directory (`-maxdepth 1`), plus one
    // depth<=2 scan per root for a chain theme with no usable index
    // (scan_theme, theme.rs:146-171) — a few hundred tiny finds spread over
    // the chain, versus the old full-disk index.
    //
    // `-H` (follow symlinks on the command line ONLY) is REQUIRED here: the
    // Colloid theme is a symlink farm at its top level
    // (Colloid/apps -> ../Colloid-Light/apps), so a declared directory can
    // itself be a symlink. Without -H find reports only the link itself and
    // the active theme yields nothing. -H stays bounded because the directory
    // is named explicitly and -maxdepth is 1, so it cannot walk a tree.
    //
    // Symlinks are matched as well as regular files: most of Colloid is
    // symlinks (foot.svg -> terminal.svg, 10B4_steam.0.svg -> steam.svg).
    // xpm is kept as a third extension even though WayRun uses svg/png only:
    // it costs nothing and preserves current behaviour.
    // The listing work is DATA, not a generated script per directory. Each
    // (theme, root, directory) triple becomes one
    // `theme|root|dir|tier|dist|ord|kind` line, and a small fixed shell
    // wrapper does the find.
    //
    // Size matters: /usr/share/icons/hicolor declares 649 directories, so a
    // script with the paths inlined came to >1 MB and `sh -c` REJECTED it —
    // MAX_ARG_STRLEN caps a single argv entry at 128 KiB, and the Process
    // failed with E2BIG, leaving the index empty and every icon on the
    // provider. The data form is ~40 bytes per entry, and
    // _buildFileChunks() additionally splits at a 48 KB budget, so the cap
    // cannot be hit again however large a theme's Directories list grows.
    function _wrapChunk(lines) {
        // set -f: the data is expanded unquoted, so globbing must be off.
        return "set -f\nIFS='\n'\nDATA='" + lines.join("\n") + "'\n"
            + "for spec in $DATA; do\n"
            + "IFS='|'; set -- $spec; th=$1; rp=$2; dp=$3; ti=$4; de=$5; od=$6; md=$7\n"
            + 'if [ "$md" = s ]; then f="$rp/$th"; d=3; else f="$rp/$th/$dp"; d=1; fi\n'
            + '[ -d "$f" ] || continue\n'
            + 'echo "@@DIR $th $rp $ti $de $od"\n'
            + "find -H \"$f\" -maxdepth $d \\( -type f -o -type l \\) "
            + "\\( -name '*.svg' -o -name '*.png' -o -name '*.xpm' \\) 2>/dev/null\n"
            + "done\n"
    }

    // Listing scripts, one per Process run, plus the lookup pairs they imply.
    // Built once from the chain and the parsed indexes, then drained by
    // _filesProc. Chain order outer, root order inner: the order WayRun
    // searches (chain_for, theme.rs:212-239).
    function _buildFileChunks() {
        // Stay well under MAX_ARG_STRLEN (128 KiB) for one argv element.
        const budget = 48000
        const chunks = []
        const pairs = []
        let pending = []
        let bytes = 0
        const flush = () => {
            if (pending.length === 0) return
            chunks.push(root._wrapChunk(pending))
            pending = []
            bytes = 0
        }
        for (const theme of root._chain) {
            for (const r of root._roots) {
                pairs.push({ key: theme + "|" + r, theme: theme, root: r })
                const idx = root._indexAt(theme, r)
                const declared = idx && idx.dirs.length > 0
                    ? idx.dirs.filter(d => d.scale <= 1)
                    : [null]
                for (const d of declared) {
                    let line
                    if (d) {
                        const rank = root._rankDir(d)
                        line = [theme, r, d.path, rank[0], rank[1], d.ord, "d"].join("|")
                    } else {
                        // No usable index.theme for THIS root: try name.<ext>
                        // one and two directories down, which covers every
                        // layout the spec allows (scan_theme, theme.rs:146-171).
                        // Depth 3 because that is how deep its inner loop
                        // reaches (<root>/<sub>/<inner>/name.ext); depth 2
                        // missed ~/<theme>/<size>/apps/<name>.png entirely.
                        line = [theme, r, "", 1, 0, 0, "s"].join("|")
                    }
                    if (pending.length > 0 && bytes + line.length + 1 > budget) flush()
                    pending.push(line)
                    bytes += line.length + 1
                }
            }
        }
        flush()
        // find_pixmap_icon (theme.rs:276-286): flat rasters outside any theme,
        // searched after every theme in the chain.
        pairs.push({ key: root._pixmapKey + "|" + root._pixmaps,
                     theme: root._pixmapKey, root: root._pixmaps })
        chunks.push('if [ -d "' + root._pixmaps + '" ]; then '
            + 'echo "@@DIR ' + root._pixmapKey + " " + root._pixmaps + ' 0 0 0"; '
            + 'find -H "' + root._pixmaps + '" -maxdepth 1 '
            + "\\( -type f -o -type l \\) \\( -name '*.svg' -o -name '*.png' -o -name '*.xpm' \\) "
            + "2>/dev/null; fi\n")
        root._lookupPairs = pairs
        return chunks
    }

    // Fold one chunk's output into the index. Chunks arrive one at a time, so
    // this MERGES rather than replaces.
    function _collectFiles(text) {
        const files = ({})
        for (const k in root._themeFiles) files[k] = root._themeFiles[k]
        let cur = null
        for (const raw of String(text).split("\n")) {
            const line = raw.trim()
            if (!line) continue
            if (line.startsWith("@@DIR ")) {
                const p = line.slice(6).split(" ")
                cur = { key: p[0] + "|" + p[1], tier: parseInt(p[2]),
                        dist: parseInt(p[3]), ord: parseInt(p[4]) }
                continue
            }
            if (!cur) continue
            const slash = line.lastIndexOf("/")
            if (slash < 0) continue
            const base = line.slice(slash + 1).toLowerCase()
            // lastIndexOf, NOT indexOf: reverse-DNS names are the common case
            // (org.gnome.Nautilus.svg), and cutting at the FIRST dot keys them
            // all as "org" so they can never match.
            // Matching is therefore CASE-INSENSITIVE, which is a deliberate
            // superset of WayRun (it stats `name.svg` verbatim): .desktop files
            // spell icons inconsistently and a real mismatch exists —
            // com.system76.cosmicstore vs com.system76.CosmicStore.svg. Same
            // for xpm, which WayRun's ICON_EXTS omits.
            const dot = base.lastIndexOf(".")
            const key = dot > 0 ? base.slice(0, dot) : base
            if (!(cur.key in files)) files[cur.key] = ({})
            if (!(key in files[cur.key])) files[cur.key][key] = []
            files[cur.key][key].push({
                path: line,
                tier: cur.tier,
                dist: cur.dist,
                ord: cur.ord,
                ext: dot > 0 ? base.slice(dot + 1) : ""
            })
        }
        root._themeFiles = files
    }

    function _startFiles() {
        if (root._fileChunks.length === 0) return
        _filesProc.command = ["/usr/bin/env", "sh", "-c", root._fileChunks.shift()]
        _filesProc.running = true
    }

    // ONE Process, reused chunk by chunk — the same pattern _rasterProc uses.
    // A SplitParser-free static Process cannot be created dynamically in a
    // Singleton (see the rasterisation notes), so the chunks are pumped
    // through this one by reassigning its command.
    Process {
        id: _filesProc
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._collectFiles(this.text)
        }
        onExited: {
            running = false
            if (root._fileChunks.length > 0) Qt.callLater(() => root._startFiles())
        }
    }

    // ─── SVG rasterisation ────────────────────────────────────────────
    //
    // Qt's SVG image plugin (libqsvg) implements only part of SVG Tiny 1.2.
    // Gradients carrying a `gradientTransform` matrix — used by Colloid's
    // zen.svg and terminal.svg — are mishandled: Qt logs "Could not resolve
    // property" at the closing </svg> and paints the icon partially or not at
    // all. No Qt setting changes this; it is a renderer defect.
    //
    // Fix: rasterise the SVG once with rsvg-convert (librsvg) — the same
    // renderer family the C++ mock uses — and hand Qt a PNG, which it renders
    // natively. The affected Colloid files are zen.svg and terminal.svg
    // (Colloid also ships foot.svg as a symlink to terminal.svg).
    //
    // ImageMagick is NOT usable here, and the code below never invokes it.
    // Measured on this box:
    //   magick -background none …/apps@2x/scalable/zen.svg out.png
    //     → exit 1, no output file. stderr:
    //       magick: unrecognized color 'url("#gradient-0")'
    //               @ warning/color.c/QueryColorCompliance/2476
    //       magick: non-conforming drawing primitive definition 'fill'
    //               @ error/draw.c/RenderMVGContent/4675
    //   terminal.svg fails identically (url("#gradient-2")).
    //   rsvg-convert on both: exit 0, valid 256x256 RGBA PNGs.
    //
    // magick is not broken in general (it converts utilities-terminal_su.svg
    // fine), and its librsvg delegate IS registered — `magick -list delegate`
    // shows: svg => 'rsvg-convert' --dpi-x %x --dpi-y %y -o '%o' '%i'. That
    // delegate is simply never spawned: ImageMagick hands .svg to its own
    // INTERNAL MSVG/MVG coder, whose MVG parser (draw.c/RenderMVGContent) is
    // what emits the errors above — it cannot parse CSS paint-server
    // references like fill="url(#gradient-0)". Forcing the coder
    // (`magick rsvg:zen.svg`) fails the same way, and policy.xml is not the
    // cause either: the {MSL,MVG,PS,SVG,URL,XPS} module restriction at
    // /etc/ImageMagick-7/policy.xml:143 is commented out.
    //
    // Related trap: /usr/bin/convert is NOT ImageMagick 6 — it reports
    // ImageMagick 7.1.2-31, the same binary as `magick` via the alternatives
    // system. Unlike `magick` it exits 1 but still leaves a small blank
    // 64x64 grey+alpha PNG behind (836 bytes for zen), i.e. it fails silently
    // with garbage output, which is worse than magick's loud failure.
    //
    // Implementation note: ONE statically-declared Process, no Repeater and no
    // dynamic creation. Repeater needs a visual parent and a Singleton has
    // none, so its delegates were never created; `new SomeProcess(...)` throws
    // because QML Process cannot be constructed that way. A plain Process is a
    // non-visual QtObject and needs no parent at all.
    //
    // The command creates the cache directory itself, so nothing depends on a
    // directory-ready flag.

    property var _rasterIndex: ({})
    property var _rasterPending: []
    // Filenames already present in the cache dir, read once at startup. Without
    // this the in-memory index starts empty on every launch, so the dock
    // rendered the SVG (and logged its warnings) before re-converting, even
    // though a perfectly good PNG was already on disk.
    property var _cachedFiles: ({})
    property string rasterDir: (Quickshell.env("XDG_CACHE_HOME") ?? (Quickshell.env("HOME") ?? "/tmp") + "/.cache") + "/quickshell/dock-icons"

    function _rasterKey(svgPath, size): string {
        return `${size}_${svgPath.replace(/[^a-zA-Z0-9]/g, "_")}`
    }

    // PURE: PNG path for an SVG URL, or "" if none yet. Must not mutate
    // state — it is called from a binding, and QML discards property writes
    // made during binding evaluation.
    function rasterFor(url, size): string {
        if (!url || !url.startsWith("file://")) return ""
        const path = url.slice(7)
        const lower = path.toLowerCase()
        if (!lower.endsWith(".svg") && !lower.endsWith(".svgz")) return ""
        const key = root._rasterKey(path, size > 0 ? size : 256)
        if (root._rasterIndex[key]) return root._rasterIndex[key]
        // Already rasterised in an earlier session?
        // MUST be a file:// URL. A bare filesystem path is resolved by Qt as a
        // qrc: resource path ("Cannot open: qrc:/home/..."), the PNG never
        // loads, and the dock silently falls back to the SVG — which is what
        // kept the QtSvg warnings appearing even with a warm cache.
        if (root._cachedFiles[key + ".png"]) return `file://${root.rasterDir}/${key}.png`
        return ""
    }

    // True while a raster for this exact (url, px) exists neither in this
    // session's index nor in the on-disk cache. Readiness gating uses it to
    // tell "still being made, keep waiting" from "nothing will ever arrive".
    function rasterPending(url, size): bool {
        if (!root._isSvgUrl(url)) return false
        const key = root._rasterKey(url.slice(7), size > 0 ? size : 256)
        if (root._rasterIndex[key]) return false
        return root._cachedFiles[key + ".png"] !== true
    }

    // A plain function, not a property: `readonly function` is not valid QML
    // (readonly applies to the property declaration), and qs fails the whole
    // config load on it.
    function _isSvgUrl(url): bool {
        if (!url || !url.startsWith("file://")) return false
        const lower = url.slice(7).toLowerCase()
        return lower.endsWith(".svg") || lower.endsWith(".svgz")
    }


    function requestRaster(url, size): void {
        if (!url || !url.startsWith("file://")) return
        const path = url.slice(7)
        const lower = path.toLowerCase()
        if (!lower.endsWith(".svg") && !lower.endsWith(".svgz")) return
        const px = size > 0 ? size : 256
        const key = root._rasterKey(path, px)
        if (root._rasterIndex[key]) return
        if (root._rasterPending.some(j => j.key === key)) return
        root._rasterPending = root._rasterPending.concat([
            { key: key, svg: path, out: `${root.rasterDir}/${key}.png`, size: px }
        ])
        root._pumpRaster()
    }

    // THE ONLY URL AN Image SHOULD EVER BE GIVEN.
    //
    // An SVG is returned as "" while its raster does not exist yet. Returning
    // the SVG instead — which is what every call site used to do with
    // `rasterFor(u) || u` — is precisely what let Qt's libqsvg load
    // gradientTransform artwork and log "Could not resolve property" at the
    // closing </svg>. Handing over a blank for a few hundred milliseconds is
    // strictly better than handing over artwork Qt paints wrong: the caller
    // gates on rasterPending() and stays hidden until the PNG lands.
    //
    // Non-SVG sources (PNG, XPM) pass straight through, so nothing regresses
    // for themes that ship rasters. requestRaster() is called here so the
    // conversion starts at the moment the URL becomes known, rather than
    // waiting for some later handler to notice.
    function rasterOrBlank(url, size): string {
        if (!url) return ""
        if (!root._isSvgUrl(url)) return url
        const px = size > 0 ? size : 256
        root.requestRaster(url, px)
        return root.rasterFor(url, px)
    }

    // Start the next queued job if the converter is idle.
    function _pumpRaster(): void {
        if (_rasterProc.running) return
        if (root._rasterPending.length === 0) return
        const job = root._rasterPending[0]
        _rasterProc.command = ["/usr/bin/env", "sh", "-c",
            `mkdir -p "${root.rasterDir}" && rsvg-convert -w ${job.size} -h ${job.size} "${job.svg}" -o "${job.out}"`]
        _rasterProc.running = true
    }

    Process {
        id: _rasterProc
        running: false
        function onExited(exitCode) {
            // Success is the exit code; rsvg-convert returns non-zero if it
            // cannot parse the SVG.
            if (exitCode === 0) {
                const done = root._rasterPending[0]
                const idx = {}
                for (const k in root._rasterIndex) idx[k] = root._rasterIndex[k]
                if (done) idx[done.key] = `file://${done.out}`
                root._rasterIndex = idx
            }
            if (root._rasterPending.length > 0)
                root._rasterPending = root._rasterPending.slice(1)
            running = false
            Qt.callLater(() => root._pumpRaster())
        }
    }

    Process {
        id: _cacheLister
        running: false
        command: ["/usr/bin/env", "sh", "-c", `mkdir -p "${root.rasterDir}" && ls -1 "${root.rasterDir}"`]
        stdout: StdioCollector {
            onStreamFinished: {
                const set = {}
                for (const raw of this.text.split("\n")) {
                    const line = raw.trim()
                    if (line.endsWith(".png")) set[line] = true
                }
                root._cachedFiles = set
            }
        }
    }

    Component.onCompleted: {
        _indexProc.running = true
        _cacheLister.running = true
    }

    // ─── Lookup ────────────────────────────────────────────────────────

    // Preference between equally-named files, decided by the DECLARED
    // directory's size range rather than by guessing from the path
    // (port of rank, theme.rs:116-126). The target is the row box source size:
    // an in-range directory first, then larger sizes for downscale headroom,
    // then smaller. Returned as [tier, distance] so tiers compare first.
    function _rankDir(d) {
        if (d.min <= 48 && 48 <= d.max) return [0, 0]
        if (d.size > 48) return [1, d.size - 48]
        return [2, 48 - d.size]
    }

    // Vector before raster, matching WayRun's ICON_EXTS order.
    function _extRank(ext) {
        if (ext === "svg") return 0
        if (ext === "png") return 1
        if (ext === "xpm") return 2
        return 3
    }

    // Best file among one (theme, root) pair's candidates for a name.
    // The order is the one WayRun searches in (find_in_theme, theme.rs:130-142):
    // directories sorted by rank with a STABLE sort — so directories of equal
    // rank keep their `Directories=` order — and, within the winning directory,
    // svg before png before xpm. Matching the declaration-order tie-break
    // matters: it is what decides between two equally ranked directories, and
    // preferring svg across directories picked a different file than WayRun
    // for emblem-pika (48x48 png, not scalable svg).
    function _bestEntry(bucket) {
        let best = bucket[0]
        let bestExt = root._extRank(best.ext)
        for (let i = 1; i < bucket.length; i++) {
            const e = bucket[i]
            const ext = root._extRank(e.ext)
            if (e.tier < best.tier
                || (e.tier === best.tier && (e.dist < best.dist
                    || (e.dist === best.dist && (e.ord < best.ord
                        || (e.ord === best.ord && ext < bestExt)))))) {
                best = e
                bestExt = ext
            }
        }
        return best
    }

    // Real file path for an icon name, or "" if nothing in the chain ships it.
    //
    // The search order is the chain (active theme, then its `Inherits`
    // breadth-first, then hicolor), and within each theme the icon roots in
    // order, then /usr/share/pixmaps last. The FIRST (theme, root) pair that
    // ships the name wins outright — there is no cross-pair size comparison,
    // because a theme's own artwork should never be shadowed by another root's
    // or an inherited theme's. If the whole chain misses, resolveIconUrl()
    // falls back to the generic executable glyph.
    function pathFor(name): string {
        if (!name || !root._indexReady) return ""
        const key = String(name).toLowerCase()
        for (const pair of root._lookupPairs) {
            const byName = root._themeFiles[pair.key]
            if (!byName) continue
            const bucket = byName[key]
            if (!bucket || bucket.length === 0) continue
            return root._bestEntry(bucket).path
        }
        return ""
    }

    function smartIconName(icon, appId): string {
        if (!icon) {
            const guessed = AppSearch.lookupDesktopEntry(appId)?.icon
                ?? AppSearch.guessIcon(appId)
            return guessed || appId || "application-x-executable"
        }
        if (icon.startsWith("/") || icon.startsWith("file://")) {
            return icon.startsWith("file://") ? icon : `file://${icon}`
        }
        return icon
    }

    // Candidate icon NAMES. The name the .desktop entry declares is the
    // strongest signal, so it goes first; reverse-DNS ids get camel/kebab
    // variants too, since themes key on different spellings.
    function dockIconCandidates(iconName) {
        if (!iconName) return []
        const lower = iconName.toLowerCase()
        const candidates = []
        candidates.push(iconName)
        if (iconName.includes(".")) {
            const parts = iconName.split(".")
            const last = parts[parts.length - 1]
            candidates.push(last)
            candidates.push(last.toLowerCase())
            candidates.push(last.replace(/([a-z])([A-Z])/g, "$1-$2").toLowerCase())
        }
        candidates.push(lower)
        candidates.push(iconName + "-launcher")
        return [...new Set(candidates)]
    }

    readonly property var genericIconCandidates: ["application-x-executable", "application-x-executable-symbolic"]
    readonly property string genericIconPathFallback:
        "/usr/share/icons/Adwaita/scalable/mimetypes/application-x-executable.svg"
    readonly property string genericIcon: "application-x-executable"

    // Icon NAME -> loadable URL. Absolute paths pass through; otherwise a real
    // file from the index is preferred, because iconPath() returns an
    // image://icon/<name> URL that decodes to nothing when the active theme does
    // not ship that name.
    function resolveIconUrl(name): string {
        if (!name) return root.resolveGenericIconUrl()
        if (name.startsWith("/") || name.startsWith("file://"))
            return name.startsWith("file://") ? name : `file://${name}`
        // A BARE NAME WAITS FOR THE INDEX, and is then served ONLY from it.
        // Quickshell.iconPath() is deliberately not consulted here: it is the
        // one source that cannot be rasterised, because it hands back
        // `image://icon/<name>`. Qt resolves that through the platform icon
        // engine — at fractional scale that is the apps@2x SVG, straight into
        // libqsvg, straight into "Could not resolve property" at the closing
        // </svg>. pathFor() searches the same theme chain, in the same
        // Inherits order, with hicolor last, and returns a REAL FILE that
        // rasterOrBlank() can turn into a PNG. So this is not a weaker
        // resolver; it is the same resolver minus the one branch that cannot
        // be rendered correctly.
        if (!root._indexReady) return ""
        for (const candidate of root.dockIconCandidates(name)) {
            const real = root.pathFor(candidate)
            if (real !== "") return `file://${real}`
        }
        return root.resolveGenericIconUrl()
    }

    // Last-resort glyph.
    //
    // It is served from the icon index, NEVER from Quickshell.iconPath().
    // iconPath() returns `image://icon/<name>`, which the rasteriser cannot
    // see through, so that URL reaches Qt's platform icon engine and is
    // rendered by libqsvg — at fractional scale that is the apps@2x artwork,
    // which is exactly what produced the "@2x/scalable/zen.svg: Could not
    // resolve property" warnings. The index searches the same themes in the
    // same order and yields a real file, so this is not a weaker lookup; it is
    // the same lookup that can be rasterised.
    //
    // Before _indexReady it returns "" rather than guessing. The dock's icon
    // gate already waits for IconThemeService._indexReady, so a blank here
    // costs no visible time — whereas the guess it replaces cost correctness:
    // every icon briefly showed the generic glyph, then swapped.
    function resolveGenericIconUrl(): string {
        if (!root._indexReady) return ""
        for (const candidate of root.genericIconCandidates) {
            const real = root.pathFor(candidate)
            if (real !== "") return `file://${real}`
        }
        // A real, absolute path, so rasterOrBlank() can rasterise it like any
        // other SVG. No image:// URL is returned on any path.
        return `file://${root.genericIconPathFallback}`
    }

}
