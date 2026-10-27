# WoodShop

[![CI](https://github.com/chipset/WoodShop/actions/workflows/ci.yml/badge.svg)](https://github.com/chipset/WoodShop/actions/workflows/ci.yml)

A native Mac app for designing furniture and cabinets from real boards, then turning the design into the things you need to build it: a cut list, shop drawings, a lumber buy list, and flat DXF files for a CNC router (VCarve).

Think of it as a woodworking-focused alternative to general 3D modelers such as SketchUp. Every object is a *board* with a species, a grain direction and a thickness, and joinery is real geometry that stays attached to the board when you resize or move it.

> **Status:** an actively developed hobby project. The CNC output has not been verified in every VCarve version; always simulate in VCarve and check units, origin and depths before cutting.

## Download

Get the latest build from the [Releases page](https://github.com/chipset/WoodShop/releases).

1. Download `WoodShop-<version>-macOS.zip` and unzip it.
2. Drag **WoodShop.app** to Applications.
3. The first time, **right-click the app and choose Open**, then confirm. The app is not notarized by Apple, so a normal double-click is blocked on first launch.

Requirements: a Mac with Apple Silicon and macOS 14 or newer.

## What it does

**Design**
- Boards from standard lumber and sheet sizes, drawn rectangles, or ready-made presets (cabinet or bookcase, drawer box, shelf, workbench)
- Move, push/pull, rotate (including any angle), copy, paste and array, with typed distances (`3 1/2`, `90mm`) and snapping to neighboring boards
- Parameters and expressions (`shelf_height = cabinet_height / 2`), linked dimensions, and part history with undo
- Components, assemblies, mirroring, and construction guides

**Joinery**
- Dado, rabbet, groove, mortise and tenon, miters and bevels
- Pocket holes, finger joints and dovetails, shelf-pin and hinge-cup drilling patterns
- Chamfers and roundovers (full length or stopped), arches and curved boards, and sketched pockets or cut-outs on any face
- Shelf-in-dado joints that follow the shelf

**Make**
- Hardware (hinges, slides, pulls, knobs, braces, screws, shelf pins) shown as recognizable shapes and counted in the buy list
- Cut list and a buy list: rough board feet with planing allowance, a cut plan that allows for saw kerf, sheet counts and hardware counts
- Sheet nesting, with optional two-sided work and registration pins
- Machining review and assembly checks before you cut
- Shop drawings, part labels and assembly guides as PDF
- CNC export: one DXF per sheet and setup, with layers for outlines, pockets, drilling and through-cuts, plus PDF setup sheets

**Import and export**

| | Import | Export |
|---|---|---|
| 3D models | STL, OBJ, PLY, 3DS, DXF 3D faces, Collada DAE, KMZ, USD / USDZ (rectangular solids become real boards) | STL, OBJ, PLY, 3DS, DXF 3D faces, Collada DAE, USDZ |
| Flat outlines | SVG, DXF | SVG, DXF |

SketchUp `.skp` and AutoCAD `.dwg` are proprietary and not supported; use DAE or STL from SketchUp, and DXF for CAD.

## Documentation

- [Getting started: build a simple workbench](docs/Getting-Started-Workbench.md) – a 30-minute walkthrough
- [User manual](docs/WoodShop-Manual.md) – every feature, plus step-by-step recipes for common woodworking tasks

## Build from source

You need macOS 14+ and the Swift 5.9+ toolchain (Xcode or the Command Line Tools).

```sh
./build_app.sh        # builds WoodShop.app in the project folder
open WoodShop.app
```

Run the tests:

```sh
swift test            # or ./test_app.sh
```

## Releasing

GitHub Actions builds and tests every push (`.github/workflows/ci.yml`). To publish a release, push a version tag:

```sh
git tag -a v0.16.0 -m "WoodShop 0.16.0"
git push origin v0.16.0
```

The Release workflow runs the tests, builds the app with that version number, and attaches `WoodShop-0.16.0-macOS.zip` to a new GitHub release. Running the workflow by hand from the Actions tab does a dry run that only uploads the zip as a downloadable artifact.

## Project layout

```
Sources/WoodShop/   the app (SwiftUI + SceneKit)
Tests/              XCTest suite
Resources/          app icon
Tools/make_icon.swift   regenerates the icon
docs/               manual and getting-started guide
build_app.sh        builds and ad-hoc signs WoodShop.app
```

A few pointers for contributors:

- Boards are axis-aligned boxes (Y is up, units are inches) with an optional rotation about their center. Cuts, trims, drilling patterns, edge profiles and curved outlines are features of the board.
- Geometry is built from convex clipping and solid boolean operations in `Geometry.swift` and `SolidCSG.swift`; exports flatten each board in `Export.swift`.
- Project files are JSON (`.wood`) and decode older files; new fields are optional.

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Thomas McQuitty.
