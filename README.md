# SpektraLab for iPad — a personal port, in progress

A personal, unofficial port of [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)'s
spectral film simulation to iPad (and iPhone), built as an app called
**SpektraProbe**. It runs the original's C++/Metal film engine, **unmodified**,
on the iPad's GPU: a RAW goes through a virtual film negative and a print, with
its grain, halation and paper, in a second or two at full resolution.

> Not affiliated with or endorsed by SpektraLab or spektrafilm. For the
> finished macOS app, see the [original project](https://github.com/JamesQiu2005/SpektraLab).
> This branch, `ios-feasibility-probe`, is the iPad work; `main` is an
> untouched copy of the original.

## Status

| Phase | What | |
|---|---|---|
| 1 | The original Mac app builds from source (Xcode 27.1) | ✅ |
| 2 | Feasibility: the engine compiles for iPadOS with no source changes, and a 40.6 MP RAW renders at full resolution on an iPad | ✅ |
| 3 | Colour pipeline, post-processing adjustments, sRGB JPEG export | ✅ |
| 4 | The engine's film, camera, format, Scene Placement and print settings | ✅ |
| 5 | Saved edits, undo/redo, a photo library | ✅ |
| next | Crop and zoom, camera white balance, more adjustments and export options — see [Roadmap](#roadmap) | ⏳ |

## What the iPad app does today

**Library and editing**
- Import RAWs (or JPEG/HEIC/TIFF) **from Files or from Photos** (the original
  RAW when the photo has one); a **filmstrip** shows the library as each photo
  was last left, with Previous / Next.
- Edits **save automatically** per photo and come back after a restart; the
  photo itself is never written. **Undo / Redo**, one step per slider drag.

**The film** — the original's engine settings, with the Mac app's defaults
- **34 stocks** from the Mac app's own catalogue: colour negatives, slide films
  (scanned, no paper) and black-and-white films (printed on Ilford Multigrade).
- **Camera:** metering (Balanced, Center, Protect highlights / shadows, or
  off) and film exposure.
- **Film effects:** grain, halation and scatter, highlight boost, anti-halation
  layer, colour couplers, glare — each with its strength.
- **Film format:** 110, APS, 135, 120, custom and cine formats; grain and
  halation are sized in real micrometres on the chosen film.
- **Scene Placement:** the film's latitude against the scene's range, and
  highlight / shadow pull-backs that the engine solves (and refuses when it
  can't place them).
- **Print:** Print Effects and EDR.

**Colour, adjustments and export**
- **ProPhoto RGB throughout**, as in the Mac app, converted once per
  destination through the engine's CAM16 gamut mapping: Display P3 on screen,
  sRGB in an export.
- **Adjustments** with the Mac app's arithmetic: white balance (temperature,
  tint), exposure, contrast, highlights, shadows, black and white point,
  saturation — plus **vibrance**, which is new here.
- **JPEG export** in sRGB at full resolution, quality 10–100, with the camera's
  EXIF (no GPS), saved to Files and shareable to Photos or AirDrop.

## Measured on an iPad Pro 11-inch (M5)

A Leica M10-R DNG, 7840 × 5184 (40.6 MP), Portra 400:

| | |
|---|---|
| RAW decode into the engine | 0.6–1.0 s |
| Live preview after an edit (2420 px) | 0.13–0.5 s |
| **Full-resolution render** | **1.57 s** |
| Peak memory during it | 4,076 MB (4,699 MB at the app's busiest), of a 12,288 MB app limit |
| sRGB JPEG export with the negative already developed | 0.8 s |
| JPEG size at quality 95 / 60 | 19.7 MB / 9.8 MB |

The app asks for Apple's `increased-memory-limit` entitlement, which a free
Apple ID also receives.

## Roadmap

Still missing compared with the Mac app, roughly in order of importance:

1. **Crop, straighten, rotate, flip.**
2. **Before/after, zoom to 100 % and pan**, and a full-resolution view when idle.
3. **Camera white balance** in kelvin at the RAW decode, with a picker and
   presets; a lens-correction switch.
4. **More adjustments:** brightness, tone curve, colour balance, vignette;
   a **histogram**.
5. **Copy / paste / sync settings** across photos.
6. **Export options:** PNG and 16-bit TIFF, other colour spaces, resizing,
   recipes, **batch export**, a soft proof with a gamut warning.
7. **Digital Intermediate** printing and "Don't apply film simulation".
8. Film Edge and Date Back, half-frame pairs, settings, Simplified Chinese,
   an About page with the licences.

## Building

You need a Mac with Apple silicon and **Xcode 27**, an iPad or iPhone on
**iOS 18 or later** with Developer Mode on, and an Apple ID (a free one works;
its apps must be reinstalled every 7 days). The app is built for devices only,
not the Simulator.

```bash
xcodebuild -downloadComponent MetalToolchain   # once: Xcode's Metal compiler
engine/build-ios.sh                            # the engine, its kernels, the app's resources
open SpektraProbe/SpektraProbe.xcodeproj
```

In Xcode, choose your own team and a bundle identifier of your own under
**Signing & Capabilities**, pick your device, and press **Run**. Re-run
`engine/build-ios.sh` whenever the engine changes.

### Testing from the Mac

The app saves its numbers to `SpektraProbe results.txt` in its folder, and
takes launch arguments that run without anyone tapping:

| | |
|---|---|
| `--open <file>` | open a library photo |
| `--selftest <file>` | export it untouched, then adjusted |
| `--selftest-film <file>` | export it on Tri-X, Velvia, and Portra on 120 with EDR |
| `--selftest-library <file>` | check saving, undo, copies and the library |
| `--forget <file>` | drop a photo's saved edits |

```bash
xcrun devicectl device process launch --device <UDID> <bundle id> -- --selftest-library <file>
```

## Repository layout

| | |
|---|---|
| `SpektraProbe/` | **the iPad / iPhone app** (new) |
| `engine/build-ios.sh` | **the engine's iPadOS build** (new) |
| `engine/` | the original C++20 / Metal render engine — unmodified |
| `modern_UI/` | the original macOS app — unmodified; the reference this port follows |
| `windows_UI/` | the original's Windows work — unmodified |
| `ARCHITECTURE.md`, `AGENTS.md`, `API-SPEC-*`, `CONTRACT-*`, `PRD/` | the original project's design documents, kept for reference |

## Credits and licence

This is a fork of [SpektraLab](https://github.com/JamesQiu2005/SpektraLab) by
Hanze Qiu, a native C++/Metal port of
[spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea Volpato,
whose film process model, 28 measured colour profiles and print LUTs this app
renders with. The 4 black-and-white profiles are by Hanze Qiu. If you are
citing the science, cite spektrafilm.

| | |
|---|---|
| the iPad app, the engine and the original app | GPL-3.0-or-later |
| film and paper profiles, print LUTs | CC BY-SA 4.0 |
| metal-cpp | Apache-2.0 |

The licence texts are in [`license/`](license/).
