# Dock — port notes

This dock is a port of the C++ Wayland dock at
`/run/media/tobiasmagnegraneberg/Developer/Developer/mock` (itself a rebranded
noctalia-dock). Everything below is about *why* the code looks the way it does —
specifically the parts that look wrong but are deliberate, and the two dead ends
that cost the most time.

Run it with `qs -c dock`. Configure via `config.json`.

---

## Blur: the facts that matter

This took the longest to get right. `Dock.qml` carries the full comment inline;
this is the summary.

### 1. `blurRegion` is in SURFACE-LOCAL coordinates

Setting `BackgroundEffect.blurRegion` to `Region { item: someItem }` emits the
region at that item's offset *inside* the surface. The dock's pill sits at an
offset, so niri received a region landing in empty space and **stopped blurring
altogether** — it looked exactly like "niri rejects client blur regions".

It does not. Confirmed by probe: an explicit `Region { x: 0; y: 0; width: 120;
height: 60 }` blurred the surface's top-left corner. So always give `x`, `y`,
`width`, `height` explicitly:

```qml
BackgroundEffect.blurRegion: Region {
    x: dockRoot._bgX                       // panelOffsetX - _osdGrowL
    y: dockRoot.panelOffsetY
    width: dockRoot._ready ? dockRoot._bgW : 0   // panelW + _osdGrowL + _osdGrowR
    height: dockRoot._ready ? dockRoot.panelH : 0
    topLeftRadius: dockRoot.rTL
    topRightRadius: dockRoot.rTR
    bottomRightRadius: dockRoot.rBR
    bottomLeftRadius: dockRoot.rBL
}
```

The `_ready` gate is load-bearing: this blur is a protocol-side effect on the
layer-shell surface, so opacity alone does not hide it — before the dock is
ready the region is collapsed to zero size. With both OSD growth values at 0,
`_bgX`/`_bgW` are exactly `panelOffsetX`/`panelW`, so the resting region is
unchanged.

### 2. `Region` is NOT one rounded rect — `blurRegion` being singular is a different fact

Two separate things get conflated here.

**Still true:** `BackgroundEffect.blurRegion` is a *single* object property,
not a list. In
`/usr/lib/x86_64-linux-gnu/qt6/qml/Quickshell/Wayland/_BackgroundEffect/quickshell-wayland-background-effect.qmltypes:19-28`
it is declared `name: "blurRegion"; type: "PendingRegion"; isPointer: true`, so
assigning a raw JS array is rejected (`Cannot assign multiple values to a
singular property`).

**Was wrong:** the claim that `Region` is "a rounded rect with `radius` and
four per-corner variants". It is not. `Region` is the C++ `PendingRegion`
(`quickshell-core.qmltypes:639-749`), with `defaultProperty: "regions"` (`:644`)
and `Property { name: "regions"; type: "PendingRegion"; isList: true }`
(`:724-732`). So a `Region` is a *composite*: it holds an ordered list of
sub-regions, combined pairwise according to the `shape` property
(`RegionShape::Enum` = `Rect` / `Ellipse`, `quickshell-core.qmltypes:1311-1324`)
and the `intersection` property (`Intersection::Enum` = `Combine` /
`Subtract` / `Intersect` / `Xor`, `:523-536`). A disjoint multi-rect union
**is** expressible:

```qml
Region {
    intersection: Intersection.Combine   // Subtract / Intersect / Xor
    Region { x: 0;   y: 0; width: 120; height: 60; radius: 16 }
    Region { x: 140; y: 0; width: 120; height: 60; radius: 16 }
}
```

Quickshell still tessellates whatever `PendingRegion` resolves to into plain
rectangles for `ext-background-effect-v1`, and niri consumes only the
resulting non-overlapping rect list (`region_to_non_overlapping_rects`,
`src/handlers/background_effect.rs:63-67`). The mock's hand-rolled
`Surface::tessellateShape()` (`mock/src/shell/dock/dock_instance.cpp:215-216`)
is the same operation, written out.

### 2a. Why the context menu needs a CLIENT region even though a rule exists

This is the reason `modules/common/widgets/ContextMenu.qml` commits a blur
region instead of relying on the compositor. The dock's right-click menu is an
xdg-popup **of a layer-shell surface**, and the rule that would blur it —
`window-rule { … popups { background-effect { blur true } } }`
(`~/.config/niri/config.kdl:236-253`) — never reaches it:

 - Popup rules for a layer surface come from that surface's
   `ResolvedLayerRules.popups`, not from any window rule:
   `src/layer/mapped.rs:616-623`, `for_each_popup`:
   `PopupKind::Xdg(_) => self.rules.popups`.
 - `ResolvedLayerRules` is computed *only* from `config.layer_rules`
   (`src/layer/mod.rs:65-122`, called with `config.layer_rules` at
   `src/handlers/layer_shell.rs:162-163`). `config.window_rules` is consumed
   exclusively by the xdg-shell/toplevel path
   (`src/handlers/xdg_shell.rs:1036-1040`, `:1368-1372`) — window rules are
   never evaluated for a layer-shell surface.
 - So `self.rules.popups` stays `ResolvedPopupsRules::default()`
   (`niri-config/src/window_rule.rs:107`), whose `background_effect` is
   `BackgroundEffect::default()` (`niri-config/src/appearance.rs:1071-1072`)
   with `blur: None` (`appearance.rs:1086`).
 - `src/render_helpers/background_effect.rs:117-122` then evaluates
   `let blur = if has_blur_region { effect.blur != Some(false) } else { effect.blur == Some(true) };`
   With `has_blur_region == false` and `blur == None`, the else-branch is
   **false** — niri renders no background effect for the popup at all.
 - Committing a non-empty client region makes `has_blur_region` true
   (`background_effect.rs:304-305`) and flips the branch to
   `None != Some(false)` → true.

No config knob is needed for this, and none exists: `Config.qml` deliberately
declares no `contextMenuBackdropBlur`. The blur is unconditional.

Side effect worth knowing: the same default rules struct also leaves
`geometry_corner_radius` at `None`, and `render_popups` passes
`entry.rules.geometry_corner_radius.unwrap_or_default()`
(`src/layer/mapped.rs:690`) — i.e. radius 0. niri is therefore *not* clipping
the menu's blurred backdrop to any corner radius; the region shape is the only
shape.

### 3. The layer rule is consulted in BOTH branches

The dock sets the layer namespace `"quickshell:dock"` and commits a client
`blurRegion`. niri does **not** ignore the layer rule's
`background-effect.blur` when a client region exists. From
`src/render_helpers/background_effect.rs`:

```rust
let blur = if has_blur_region { effect.blur != Some(false) }
           else                 { effect.blur == Some(true) };
```

So an explicit `blur false` in the layer rule vetoes the client's blur region,
and an explicit `blur true` enables blur even when there is no client region.
The nearby comment "default blur to true" describes a *default*, which an
explicit `false` overrides. The earlier conclusion here — that the client path
"takes over" and makes the rule irrelevant, so no niri config change is needed —
was wrong and is not to be reinstated.

Scope: this item is about the dock's own **layer surface**, where the
`layer-rule { match namespace="quickshell" … }` block genuinely is consulted.
It does **not** generalise to popups — see item 2a: a popup inherits the rules
of the layer surface that spawned it, and `window-rule` never applies there.

The region's geometry and the painted background come from the same bindings
(`_bgX`, `_bgW`, `panelOffsetY`, `panelH`, the four corner radii), so there is
no geometry gap between them by construction, and the region deliberately
tracks `_bgX`/`_bgW` so it follows the OSD growth.

### 4. The reported symptom has NOT been diagnosed

Reported symptom: "the blurred region looks slightly smaller than the dock
background".

This section previously carried measured tables — a "+10 device px straight
edge / +7.5 corner arc" shortfall attributed to a `blur.offset` transition
ramp, and a later re-measurement reading "~1-4 px / ~0 px" — together with
retraction blocks claiming the dual-path theory was refuted and that no niri
config change was needed. All of that has been deleted.

**Both sets of numbers came from synthetic probe surfaces, not from the user's
dock on their desktop.** They are not evidence about what the user sees and
they do not settle the symptom. The retraction was itself wrong on the config
question (see item 3). **No cause is known, and none should be stated.**

The one durable lesson: this cannot be settled from a synthetic surface or from
a screenshot of the live dock — the wallpaper is a smooth gradient, so blurred
and unblurred are numerically indistinguishable in a `grim` capture. Any future
work must measure the user's real dock on their real desktop.

**Still load-bearing, and independent of all the above:** `blurRegion` must be
in SURFACE-LOCAL coordinates (anchoring to an item stopped blur entirely);
`blurRegion` is a singular property and assigning a list fails; and opacity
does not reach the compositor, so the region is collapsed to zero width/height
until `_ready`. That is what makes the pre-ready dock invisible — niri's
`if rects.is_empty() { return None; }` short-circuits before rendering any
effect, regardless of the layer rule. Do not "simplify" the `_ready` gate away.

---

## Deliberate deviations from the mock

### `dock.activeIconShift` (default `10`)

Lifts the **focused** window's icon along the axis pointing away from the screen
edge (up for a bottom dock, down for top, right for left, left for right), in
`DockAppButton.qml`, composed into the icon's existing bounce `Translate`.

The mock does **not** do this. Its item layer keeps everything at `restMainPos`
(`updateVisuals` `dock_items.cpp:1058-1059`), `syncDockItemRestPositions` is a
pure read (`:1387-1394`), and `applyHoverIconVisual` pins the icon's centre
(`:114-127`) — which is reproduced here by `transformOrigin: Item.Center`. The
only translation the mock applies is the neighbour spread, gated on
`pointerActive` (`updateHoverZoom` `:1325-1339`, zeroed at `:1342`).

Set `dock.activeIconShift` to `0` for strict mock behaviour.

### Icon fallback walks other themes

`services/IconThemeService.qml` indexes the icon trees on disk once and serves
`file://` URLs. Needed because `Quickshell.iconPath()` returns a truthy
`image://icon/<name>` for names the active theme does not ship — the active
theme here (`~/.local/share/icons/Colloid`) contains only `index.theme` and
`zen.png`, so `foot` rendered blank until this was added. Mirrors the mock's
`IconResolver` (`mock/src/system/icon_resolver.cpp`), which walks themes then
hicolor.

**If the blur ever disappears, check the `BackgroundEffect.blurRegion` block
first.** That has been the cause every time, and it looks like an unrelated
regression.

---

## Known gaps

- **Spread-clamp bounds.** Ours are `[0, rowMainSize]`; the mock passes
  `[mainPad, rowMainSize - mainPad]` (`dock_items.cpp:1338-1340`). Ours is more
  permissive, so it is not a visible bug, but the clamp does not bite exactly as
  the mock's does.
- **Not interactively verified.** Drag-reorder, click-to-launch, window cycling,
  the desktop-actions menu and smart-auto-hide reveal were checked by static load
  and rendering only — exercising them needs real pointer input.
- **Not portable by nature** (the mock's own builds stub these too): IPC
  (`dockShow`/`dockHide`/`dockToggle`/`dockReload`), XDG activation tokens, and
  moving windows between outputs. Blur differs in kind: the mock sets a blur
  region via the protocol, which is what the block above now reproduces.
- Tooltips are absent by request. The mock's `TooltipManager` is a stub anyway
  (`tooltip_manager.cpp:59-62` — a boolean flip and a log line, no surface).

---

## Config keys added during the port

`Config.qml` is the single source of truth — a key needs three edits: the
property declaration, an entry in `serializableProperties`, and (if it should be
overridable per output) an entry in `overridableKeys`.

`crossAxisPadding`, `marginEnds`, `marginEdge`, `concaveEdgeCorners`,
`activeScale`, `inactiveScale`, `activeOpacity`, `inactiveOpacity`, `showDots`,
`showInstanceCount`, `showRunning`, `enabled`, `shadow`, `launcherPosition`,
`launcherIcon`, `launcherCustomImageColorize`, `bounceOnLaunch`,
`bounceDurationMs`, `bounceStyle`, `reserveSpace`, `layer`, `activeMonitorOnly`,
`smartAutoHide`, `shadowDirection`, `shadowAlpha`, `monitorOverrides`,
`activeIconShift`.

Defaults mirror `DockConfig` in `mock/src/config/config_types.h:154-204`.

`config.json` mirrors `~/.config/mock/config.toml`, which is what the mock
actually runs — those differ from the struct defaults (`icon_size 80`,
`item_spacing -5`, `background_opacity 0.2`, `radius 30`,
`magnifyScale 1.5`, `shadow = false`).

**Note:** newly declared keys do not appear in `config.json` until something
triggers a save — `Config.qml` only writes on `setNestedValue()`. Add them by
hand the first time. A key needs three edits to be fully live: the `property`
declaration under `options.dock`, an entry in `configSchema` (the real
persistence list that drives snapshot/restore), and — if it should vary per
output — an entry in `overridableKeys`.
## Right-click context menu settings

`config.json` is **machine-rewritten** by `Config._snapshot()` on every
`setNestedValue()`, which re-serialises the whole tree with
`JSON.stringify(…, null, 4)`. Comments are therefore not supported and any
added would be silently stripped on the next save — the keys below are
self-describing instead.

All keys live in `dock.appearance`. Every numeric key defaults to `-1`, which
means **"not configured"**: the use site (`ContextMenu.qml`) then falls back to
the Appearance token or to the value the menu used before the key existed, so
leaving a key at `-1` keeps the menu pixel-identical. Colour keys default to
`""`, meaning "use the theme token". Colour format: `RRGGBB` / `RRGGBBAA`,
leading `#` optional, plus `rgb()` / `rgba()`.

| Key | Type | Default | What it does |
| --- | --- | --- | --- |
| `contextMenuBackgroundColor` | string | `""` | Card fill. Empty = `Appearance.colors.colSurfaceContainer`. Alpha is honoured; the ambient shadow fades with it. |
| `contextMenuBorderColor` | string | `""` | Card outline colour. Empty = `Appearance.colors.colSurfaceContainerHighest`. |
| `contextMenuTextColor` | string | `""` | Row label and monochrome icon tint. Empty = `Appearance.m3colors.m3onSurface`. |
| `contextMenuSeparatorColor` | string | `""` | Reserved for row separators. Empty = `Appearance.colors.colOutlineVariant`. Currently **inert**: the dock's `menuModel` has no separator rows, so nothing draws with it. Kept declared so a future separator has a key waiting. |
| `contextMenuBorderRadius` | int | `-1` | Card corner radius in px. Empty = `Appearance.rounding.normal` (12). One key, four corners — a floating popup has no edge-concave mode, so per-corner keys would be dead weight. Shared by the painted card and the blur `Region`. |
| `contextMenuBorderWidth` | real | `-1` | Card outline thickness in px. Empty = 1. Set `0` for no outline. |
| `contextMenuItemHeight` | real | `-1` | Row height in px. Empty = 32. |
| `contextMenuItemRadius` | real | `-1` | Corner radius of a row's hover/ripple highlight. Empty = `Appearance.rounding.small`. |
| `contextMenuMinWidth` | real | `-1` | Minimum card width in px, so short labels do not produce a cramped popup. Empty = 140. |
| `contextMenuTextSize` | real | `-1` | Row label font size in px. Empty = `Appearance.font.pixelSize.small`. |
| `contextMenuIconSize` | real | `-1` | Row icon size in px. Empty = `Appearance.font.pixelSize.normal`. |
| `contextMenuItemHoverColor` | string | `""` | Row hover tint. Empty = `colPrimary` at 85% transparency. |
| `contextMenuItemRippleColor` | string | `""` | Row click-ripple tint. Empty = `colPrimary` at 70% transparency. |

Deliberately **not** configurable: the card's inner `padding`, the popup's
`visualMargin` and `ambientShadowWidth` (they define the popup's implicit size
and the geometry the blur `Region` tracks — a user value there desyncs the
blurred backdrop from the painted card), the open/close animation tokens (they
follow `theme.animations` globally), and `closeOnHoverLost` /
`closeOnFocusLost` / `noSmoothClosing` (behavioural wiring the dock's callers
drive, not a look-and-feel preference).

A key needs three edits to be live: the `property` declaration on `dockOpts`,
an entry in the matching `configSchema` group, and a hand-written entry in
`config.json` (nothing appears until something triggers a save). A key present
in `config.json` but **absent from `configSchema` is silently dropped on the
next save** — `_hydrate()` only copies keys listed in the group.
