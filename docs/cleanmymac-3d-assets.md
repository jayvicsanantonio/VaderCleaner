<!--
Reverse-engineered reference of the visual / "3D-style" assets shipped in the
installed CleanMyMac 5 app, captured for VaderCleaner design comparison.
-->

# CleanMyMac 5 — Visual / "3D" Asset Reference

> **Source inspected:** `/Applications/CleanMyMac_5_MAS.app`
> **Version:** CleanMyMac 5.5.4 (build 50504.0.2605130801), Mac App Store edition
> **Method:** direct bundle inspection — `find`, `unzip`, USD crate magic-byte scan,
> `assetutil --info` on every `Assets.car`, and pixel/colour extraction via a small
> CoreUI exporter. All colours and dimensions below were read off the actual shipped
> renditions, not reconstructed from memory.

---

## 0. Headline finding: there are **no `.usdz` / USD / SceneKit 3D files**

The premise that CleanMyMac ships `.usdz` (or any runtime 3D model) assets does **not**
hold for the installed app. Verified exhaustively:

| Check | Result |
|---|---|
| `*.usdz / *.usdc / *.usda / *.usd` by extension | **0 files** |
| USD crate magic bytes (`PXR-USDC`) scanned across every file ≥1 KB | **0 files** |
| `*.scn / *.scnz / *.scnassets / *.dae` (SceneKit) | **0 files** |
| `*.reality / *.obj / *.gltf / *.glb / *.abc` | **0 files** |
| `RealityKit` / `SceneKit` linkage | not used for content models |

**What actually produces the "3D" look** is three things, none of which are 3D model files:

1. **Pre-rendered raster artwork** baked into Apple asset catalogs (`Assets.car`). The
   glossy, lit, perspective module icons are flat PNGs that were *rendered* in a 3D tool
   and exported to 2D. There is no geometry at runtime — just bitmaps at `@1x`/`@2x`.
2. **A Metal-rendered live animated background** — `CleanMyLiveBackground.framework`
   (a compiled binary; its shaders are embedded, plus a `default.metallib` ships with the
   ubiquitous-button bundle). This is the moving colour-field behind the main window.
3. **One Rive vector animation** (`TipsServiceUI.framework/.../main.riv`) and **one intro
   video** (`Features_IntroFlow.bundle/.../IntroVideo.mp4`).

So this document describes the **rendered raster artwork** that *reads* as 3D — its shape,
colour, lighting, and dimensions — which is the closest equivalent to "the 3D assets."

---

## 1. Where the artwork lives

CleanMyMac 5 is split into ~128 frameworks; each feature module carries its own
`Assets.car`. The visually significant catalogs:

| Catalog (framework / bundle) | Holds |
|---|---|
| `…/Resources/Assets.car` (app root) | App icon pieces, wiper-frame sequence, snowflakes |
| `MainAppUI.framework` | Wordmark, "Crafted by MacPaw", back-button chrome |
| `SmartCareModule.framework` | **`ModuleIcon` hero (1200×800)**, sidebar icons, intro-category icons |
| `JunkCleanupModule.framework` | System-junk / trash-bins / mail category + item icons |
| `ProtectionModule.framework` | Privacy / malware / permissions icons, Moonlock promo art |
| `PerformanceModule.framework` | Maintenance / login-items / launch-agents icons |
| `ApplicationsModule.framework` | Uninstaller / updater / leftovers icons |
| `SpaceLensUI.framework` | Treemap tile states (Default / Selected / Hover / Smaller Items) |
| `SharedResources.framework` | Malware-family glyphs, app fallbacks, health-monitor |
| `AssistantUI.framework` | Health-status states (Excellent → Critical) |

**Rendition format throughout:** PNG, `ARGB`, `srgb` colourspace, shipped at `@1x` and
`@2x`. Hero module icons are `600×400` (`@1x`) / `1200×800` (`@2x`); circular/badge
category icons are `200×200` / `400×400`.

---

## 2. The app icon — glossy magenta display + squeegee

**File:** `AppIcon.icns` (root) + `AppIcon_Assets/*` layers in the root `Assets.car`.

**Look & shape.** Apple "squircle" rounded-square tile on a near-white background
(`#FFFFFF` / off-white `#F7F5FC`). Centred is a stylised **iMac-style display** seen in
slight three-quarter perspective — a rounded-corner glossy panel on a thin neck and a wide
flat foot. A **silver/lavender squeegee** (cleaning wiper) lies diagonally across the top-
right of the screen, its blade catching a bright specular highlight. A faint circular
"c" / CleanMyMac monogram is embossed on the stand.

**Colour (sampled).**

| Region | Hex | Notes |
|---|---|---|
| Display, top | `#FF91D7` | bright bubblegum pink highlight |
| Display, body | `#B70193` | saturated magenta — vertical gradient top→bottom |
| Squeegee blade | silver→lavender | desaturated, high-gloss specular |
| Stand / foot | `#BDBCEF` | pale periwinkle/lavender |

**Defined palette swatches in the catalog** (`AppIcon_Assets/Color-*`):

| Swatch | Space | Value |
|---|---|---|
| Color-2 | Display P3 | `0.969, 0.961, 0.988` → ~`#F7F5FC` (off-white) |
| Color-3 | sRGB | `1, 1, 1` (pure white) |
| Color-4 | gray γ2.2 | `0.192` → ~`#313131` |
| Color-5 | gray γ2.2 | `0.078` → ~`#141414` |
| Color-6 | Display P3 | `0.966, 0.525, 0.751` → ~`#F686BF` (light pink) |
| Color-7 | Display P3 | `1.0, 0.391, 0.585` → ~`#FF6395` (hot pink) |
| Color-8 | Display P3 | `0.745, 0.004, 0.780` → ~`#BE01C7` (magenta-violet) |

> The icon's gloss is driven by `Gradient-1/2/3` (multi-stop, defined in-catalog).
> There is also a frame-by-frame **`WiperFrame_1…6`** sequence in the root catalog — the
> squeegee "wipe" animation used during cleaning, played as a sprite sequence (not 3D).

---

## 3. Smart Care hero — `ModuleIcon` (the big landing visual)

**File:** `SmartCareModule.framework/.../Assets.car` → `ModuleIcon` (600×400 / 1200×800).

This is the large centrepiece on the Smart Care screen and is essentially a **bigger,
fully 3D-rendered version of the app icon**, shown free (no squircle tile).

**Look & shape.** A glossy magenta computer display in three-quarter perspective, rounded
corners, thick glassy bezel, mounted on a **pale lavender pedestal stand** (`#BDBCEF`)
with a small embossed circular "c" badge. A **lavender-silver squeegee** rests
diagonally across the screen, top-left to lower-right, with a crisp specular streak along
its blade. Soft contact shadow under the foot. The whole object has a strong
top-light setup: bright rim along the top edge, deep saturated core, subtle reflections.

**Colour (sampled).**

| Region | Hex |
|---|---|
| Screen, top highlight | `#FF91D7` |
| Screen, lower body | `#B70193` |
| Squeegee accent | `#E305AB` (where it overlaps the pink) |
| Stand / pedestal | `#BDBCEF` |

**Gradient:** vertical, light pink `#FF91D7` at top → deep magenta `#B70193`/`#BE01C7`
at the bottom, i.e. the Color-6 → Color-8 ramp from §2.

---

## 4. Category icons — the shaped, lit "container" set

Every scan category renders as a `200/400 px` icon with a **distinct silhouette per
domain**, a **two-stop vertical gradient**, a **glassy/frosted inner glyph**, and a soft
drop shadow. They are flat PNGs that read as extruded/3D because of the baked lighting.

### 4a. System Junk — `system-junk_category_big`
- **Shape:** solid **circle**.
- **Gradient:** lime green top `#5CD746` → deep forest green bottom `#155B29`.
- **Glyph:** a frosted pale-mint **basket / bin with a lid**, an **×** debossed on its
  face (`~#7EB580` mid-tone), darker green stroke. Glassy translucent fill, top-lit.

### 4b. Trash Bins — `trash-bins_category_big`
- **Shape:** solid **circle** (same green gradient as System Junk: `#5CD746` → `#155B29`).
- **Glyph:** a pale-mint **open waste bin / tub** (`~#BBD8A5`), elliptical dark-green
  opening at top, gentle taper to the base, soft inner shadow.

### 4c. Privacy — `privacy_category_big`
- **Shape:** rounded **octagon** (stop-sign silhouette).
- **Gradient:** bright pink top `#FD66ED` → magenta-rose bottom `#B31C6E`.
- **Glyph:** a **shield** in pale lilac (`#F8BBFE`) with a white rim, a bold
  **check-mark** cut into it (darker magenta stroke). Reads as "privacy confirmed".

### 4d. Maintenance Tasks — `maintenance-tasks_category_big`
- **Shape:** a **downward-pointed banner / bookmark badge** (flat top, notched "V" base).
- **Gradient:** amber-orange top `#FCA106` → burnt red-orange bottom `#D34A25`.
- **Glyph:** a **crossed wrench + screwdriver**; the wrench is bright butter-yellow
  (`#FFE76F`) glossy, the screwdriver a darker recessed brown-orange behind it.

### 4e. Uninstaller — `uninstaller_category_big`
- **Shape:** **hexagon**.
- **Gradient:** sky blue top `#47B6F9` → deep azure bottom `#055EC4`.
- **Glyph:** a light-blue **broom / sweep "X"** with little debris dots, plus an
  overlapping **circular badge** (lower-right) carrying a darker-blue **×** (`#0550B3`)
  — i.e. "remove app".

> The category set is colour-coded by domain: **green = junk/trash, pink/magenta =
> privacy & security, orange = performance/maintenance, blue = applications.** Each shares
> the same recipe: domain shape + 2-stop vertical gradient + frosted top-lit inner glyph +
> soft shadow.

---

## 5. Protection / "all clear" art

### `no-malwares` (124×124)
- **Look:** a rounded **pink shield** (`#FC85D6`, glossy, light-pink rim) carrying a white
  check-mark, overlapping a pale-pink **document** with rounded text lines
  (`#FFF0FD`), garnished with little **sparkles**. Signals "no threats found".

### `MoonlockAppIcon` (84×84) and Moonlock promo art
- **Look:** Moonlock (MacPaw's security brand) mark — a **magenta-to-black angular
  "swoosh/arrow" glyph** on a white squircle tile (high-gloss pink `#FF00C8`-ish fading to
  a black lower-right wedge). Used in the Protection module's Moonlock promo tiles
  (`MoonlockTilePromo`, `MoonlockCleanupCompletePromo…`).

---

## 6. Space Lens (disk treemap) tiles

**File:** `SpaceLensUI.framework/.../Assets.car`.

Not 3D — these are the **flat treemap tile states** used by the disk-visualiser map:
`Default`, `Default_Hover`, `Selected`, `Selected_Hover`, `Smaller Items`,
`Smaller Items_Focused (+ _Hover)`, plus `Clouds_Default (+ _Hover)`, an
`Other-Items-Icon`, and `chevron` / `navigation-button-back|forward` chrome. The colourful
tile fills are generated/tinted at runtime per node, so the catalog only ships the
state overlays rather than coloured tiles.

---

## 7. Sidebar & status iconography (vector-style, flat)

- **Sidebar module icons:** `Sidebar_ModuleIcon_Active` / `_Inactive` per module, tiny
  (24×24 / 48×48), monochrome-tinted line glyphs — `Module=Smart Care, Active=On,
  HCM=Off.png` naming encodes state (Active + High-Contrast-Mode variants).
- **Health status set** (`AssistantUI`): `HealthStatusExcellent / Good / Fair / Poor /
  Critical / Unknown` — the dial/gauge states for the Assistant.
- **Smart Care intro categories:** `intro-category-quick-scan`,
  `-security-check`, `-system-tuneup` (32×32 / 64×64) — small flat category chips.
- **Malware family glyphs** (`SharedResources`): a full set —
  `malwares_adware / backdoor / botnet / dropper / exploit / installer / keylogger /
  miner / pua / ransomware / riskware / rootkit / spyware / stealer / trojan / virus /
  worm / other` — used in malware result rows.

---

## 8. The animated background & motion layer

- **`CleanMyLiveBackground.framework`** — compiled binary, **no asset files**; the moving
  gradient "aurora" behind the main window is drawn in Metal with shaders baked into the
  binary. This is the single biggest contributor to the app's "alive / 3D depth" feel and
  has **no extractable model or texture**.
- **`default.metallib`** ships in `CMM5UbiquitousButton_CMM5UbiquitousButton.bundle` — the
  shader(s) for the floating action button's glassy effect.
- **`main.riv`** (`TipsServiceUI`) — a Rive vector animation for the tips surface.
- **`IntroVideo.mp4`** (`Features_IntroFlow`) — onboarding video.
- **`WiperFrame_1…6`** + `Snowflakes1…3` + `EmitterMask` (root catalog) — sprite frames /
  particle masks for the wipe and seasonal effects.

---

## 9. Palette summary (extracted)

| Domain | Top stop | Bottom stop | Accent / glyph |
|---|---|---|---|
| Brand / Smart Care | `#FF91D7` | `#B70193` (→ `#BE01C7`) | lavender `#BDBCEF`, silver squeegee |
| Junk & Trash (green) | `#5CD746` | `#155B29` | mint glyph `#7EB580` / `#BBD8A5` |
| Privacy (pink octagon) | `#FD66ED` | `#B31C6E` | lilac shield `#F8BBFE` |
| Maintenance (orange) | `#FCA106` | `#D34A25` | yellow wrench `#FFE76F` |
| Applications (blue) | `#47B6F9` | `#055EC4` | badge × `#0550B3` |
| Off-white tile bg | `#FFFFFF` / `#F7F5FC` | — | — |

---

## 10. Takeaways for VaderCleaner

- If the goal is to **match CleanMyMac's look**, the realistic recipe is **not** runtime
  3D (`.usdz`/RealityKit). It is: render each module/category icon in a 3D/2.5D tool
  (Blender, C4D, etc.) with a **top-light, glossy/glassy material, single vertical
  gradient, soft contact shadow**, then **export to `@1x`/`@2x` PNG** and ship in an asset
  catalog — exactly what MacPaw does.
- The depth/motion on screen comes from a **Metal shader background**, not 3D geometry.
- Note that VaderCleaner *does* ship real `.usdz` files (`Resources/Models/*.usdz`),
  so its approach is genuinely more 3D than CleanMyMac's at runtime — a deliberate
  difference, not a gap to close.

> **Provenance:** every colour above was sampled from the decoded rendition pixels; every
> dimension/format from `assetutil --info`. Exported reference PNGs were written to
> `/tmp/cmm_assets/` during inspection (not committed).
