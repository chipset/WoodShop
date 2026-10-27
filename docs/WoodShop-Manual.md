# WoodShop User Manual

WoodShop is a Mac application for designing furniture and cabinets from real boards, then turning the design into a cut list, shop drawings, a buying list and files for a CNC router (VCarve). It is a woodworking-focused alternative to general 3D modelers such as SketchUp: every object is a *board* with a species, a grain direction and a thickness, and joinery is real geometry that stays attached to the board.

This manual has three parts:

- **Part 1 – Getting started:** concepts, the screen, navigation, tools and shortcuts.
- **Part 2 – Reference:** every feature, by topic.
- **Part 3 – Projects:** step-by-step recipes for the most common woodworking tasks.

Throughout, `⌘` is the Command key, `⌥` is Option and `⇧` is Shift.

---

## Contents

**Part 1 – Getting started**
1. Installing and starting
2. Key ideas
3. The screen
4. Moving around the model
5. Tools and keyboard shortcuts
6. Typing measurements

**Part 2 – Reference**
7. Creating boards
8. Selecting, hiding and organizing
9. Moving, resizing and rotating
10. Copying, arrays, mirroring and components
11. Material, grain and wood movement
12. Joinery
13. Holes, pocket holes and hardware
14. Curves, arches, chamfers and roundovers
15. Face sketches
16. Parameters, presets and linked dimensions
17. Feature history, undo and previews
18. Checking your design
19. The Make window: cut lists, buying, sheets and CNC
20. Shop drawings, labels and assembly guides
21. Import and export
22. Saving, recovery and units

**Part 3 – Projects**
23. A simple shelf
24. A bookcase with dado joints
25. A drawer box
26. A table with mortise-and-tenon legs
27. A mitered picture frame
28. A face frame with pocket holes
29. A box with finger joints or dovetails
30. A cabinet cut from plywood on a CNC router
31. A tabletop with rounded edges and an arched apron
32. Importing a SketchUp model
33. Working out what lumber to buy

**Appendices**
A. Shortcut summary
B. File formats
C. Troubleshooting
D. Limits

---

# Part 1 – Getting started

## 1. Installing and starting

WoodShop is built from source with the Swift toolchain (Xcode or the Command Line Tools) on macOS 14 or later.

```
cd /Users/tm633717/source/wood
./build_app.sh        # builds WoodShop.app in this folder
open WoodShop.app
```

The app is ad-hoc signed. If you copy it to another Mac, macOS will refuse to open it the first time. Right-click the app, choose **Open**, then confirm.

To run the automated tests: `./test_app.sh` (or `swift test`).

When WoodShop opens with an empty model it shows a welcome panel with four starting points:

- **Choose a project preset…** – a cabinet, drawer box, shelf or workbench from dimensions you type.
- **Open a project…** – an existing `.wood` project.
- **New plywood panel** – a single sheet-good panel.
- **Try a parametric bookcase** – a bookcase whose size is driven by named parameters.

`⌘K` opens the command search at any time.

## 2. Key ideas

**Boards.** Everything in a model is a *part*, usually a board. A board is a box with a length, width and thickness, a species, a grain direction and a thickness axis. Cuts, holes, angles and curves are features of the board, not separate objects.

**Axes and units.** The model uses three axes:

| Axis | Meaning |
|---|---|
| **X** | Left–right |
| **Y** | Up (the vertical direction) |
| **Z** | Front–back (toward or away from you) |

The ground is the X–Z plane. Distances are stored in inches and can be shown in inches or millimeters (the **Metric** switch in the status bar).

**Faces.** Faces are named by axis and sign: `+X`, `-X`, `+Y (top)`, `-Y (bottom)`, `+Z`, `-Z`. You pick a face by clicking it with the Select tool; joinery tools then work on that face.

**Origin of a board.** A board's position is its minimum corner (smallest X, Y and Z). "Offset" values in joinery are measured from the board's minimum corner.

**Thickness, width, length.** For a board, WoodShop distinguishes the *thickness* (the thinnest dimension by default), the *grain/length* direction (normally the longest), and the *width* (what remains). You can change these under **Material & resizing**.

**Hardware.** Hinges, drawer slides, pulls and screws are *parts flagged as hardware*. They show in the model and the buy list but are left out of the cut list, sheet layout and CNC files.

**Assemblies and components.** Parts can be grouped into named assemblies (for example `Cabinet/Carcass/Left`). A *component* is a set of parts that share one definition; edit one and the others follow.

## 3. The screen

```
┌────────────┬──┬─────────────────────────────┬──────────────┐
│ Parts      │T │                             │ Inspector    │
│ browser    │o │       3D viewport           │  Part        │
│            │o │                             │  Machining   │
│            │l │                             │  History     │
│            │s │                             │              │
├────────────┴──┴─────────────────────────────┴──────────────┤
│ Status bar: message · distance box · Snap · Metric          │
└─────────────────────────────────────────────────────────────┘
```

- **Parts browser (left).** Lists every part and assembly with a search box (`Find a part or assembly`) and a filter (**All / Parts / Hardware**). Click a row to select; use the buttons for **Select all visible**, **Show all parts**, **End isolation**, and per-assembly **Select / Isolate / Hide**. Show or hide with `⌥⌘1`.
- **Tool palette (narrow column).** The five tools (Select, Move, Push/Pull, Rectangle, Tape Measure) and the command search.
- **Viewport (center).** The 3D model. A **Views** menu at the top left offers standard views and an orthographic switch. Editable dimension labels appear on the selected part.
- **Inspector (right).** Three pages for the selected part:
  - **Part** – name, material, dimensions, rotation, outline & curves, material and resizing options, wood movement, linked dimensions.
  - **Machining** – joinery, miters and bevels, pocket holes and edge profiles, existing joinery lists.
  - **History** – the part's feature history.
  Show or hide with `⌥⌘I`.
- **Toolbar.** **Add Stock** (plus), **Sketch**, **Machine**, **Make**, command search, and inspector toggle.
- **Status bar.** Shows hints and messages (such as "Pocket hole added."), the distance box while you move or push/pull, the **Snap** increment and the **Metric** switch.

## 4. Moving around the model

| To… | Do this |
|---|---|
| Orbit | Hold `⌥` and drag, or two-finger scroll on a trackpad |
| Pan | Hold `⌥⇧` and drag, or `⇧` + two-finger scroll |
| Zoom | Pinch, `⌘` + two-finger scroll, or the mouse wheel |
| Zoom to fit everything | `⌘0` (or `F` with nothing selected) |
| Zoom to the selection | `F` with a selection, or `⇧⌘F` |
| Standard views | The **Views** menu at the top left of the viewport (Isometric, Top, Front, Right), or `⌘K` |
| Perspective or flat | The **Orthographic** switch in the same menu |
| Dimension labels | The **Editable dimensions** switch in the same menu shows or hides the clickable size labels |
| Hide the selection | `H` (show all again with `⇧H`) |
| Isolate the selection | Right-click → Isolate Selection (end with **End isolation**) |

Right-click any part for its context menu. If several parts overlap under the cursor, the menu lists *Select overlapping part* so you can pick the one hidden behind.

## 5. Tools and keyboard shortcuts

**Tools** (also under the tool palette):

| Tool | Key | What it does |
|---|---|---|
| **Select** | `Space` | Click a part to select it. Click a flat face to select that face for joinery. `⇧`-click adds or removes parts. Double-click a machining feature to edit it. |
| **Move** | `M` | Drag a board or an axis handle. Hold `⇧` to move vertically. Arrow keys lock an axis (→ X, ← Z, ↑ Y, ↓ free). Type a distance and press Return. |
| **Push/Pull** | `P` | Drag a flat face to lengthen, widen or thicken a board. |
| **Rectangle** | `R` | Drag on the ground or on a face to draw a new board. Its thickness comes from the inspector. |
| **Tape Measure** | `T` | Click two points to measure. |

**Menu shortcuts**

| Shortcut | Action |
|---|---|
| `⌘N` | New project |
| `⇧⌘N` | Insert a woodworking project preset |
| `⌘O` / `⌘S` / `⇧⌘S` | Open / Save / Save As |
| `⌘Z` / `⇧⌘Z` | Undo / Redo |
| `⌘X`, `⌘C`, `⌘V`, `⌘A` | Cut, copy, paste, select all boards (these behave normally inside text fields) |
| `⌘F` | Find a part |
| `⌘K` | Search every command |
| `⌘B` | Add a board |
| `⌘D` | Duplicate |
| `⌘0` | Zoom to fit |
| `⌘L` | Open the Cut List / Make window |
| `⇧⌘P` | Parameters & History |
| `⇧⌘W` | Workshop |
| `⇧⌘J` | Shop planning |
| `⌥⌘1` / `⌥⌘I` | Show/hide Parts browser / Inspector |
| `Delete` | Delete the selection |
| `Return` | Rename the selected part (or apply a typed distance during a move) |
| `Esc` | Cancel the current operation, or deselect |
| Arrow keys | Nudge the selection by the snap increment (`⇧` ×8, `⌥` moves vertically) |

## 6. Typing measurements

Anywhere WoodShop asks for a length you can type naturally:

- `3 1/2`, `3-1/2"`, `3.5`
- `2' 3` (feet and inches)
- `90mm`, `9cm`
- A bare number means inches, or millimeters when the **Metric** switch is on.

While you are dragging with Move or Push/Pull, just start typing digits; the distance box in the status bar fills in. Press Return to apply or Esc to cancel. A leading minus (`-2`) goes the opposite way. With Move, the distance goes along X unless you have locked an axis with the arrow keys.

The **Snap** setting (1/32" to 1", or 0.5 mm to 25 mm in metric) controls how far dragged objects jump. Hold `⌥` while dragging in the face-sketch editor to ignore snapping. The Move tool also snaps to the edges and corners of neighboring boards ("snapped to edge" appears in the status bar).

---

# Part 2 – Reference

## 7. Creating boards

**Add stock.** Click **Add Stock** (the plus in the toolbar).

1. Choose a **Stock** size from the list (1×2 up to 4×4 dimensional lumber, 4/4 and 8/4 hardwood, 3/4, 1/2 and 1/4 plywood sheets, and hardware items).
2. Choose a **Material** (species).
3. Set the **Length**.
4. Click **Add Board** (or **Plywood panel** for a full sheet).

Lumber sizes are actual (dressed) dimensions, so a 1×4 is 3/4" × 3 1/2".

**Draw a board.** Choose the Rectangle tool (`R`), set the thickness in the inspector (**Draw a panel → Thickness**), then drag on the ground or on an existing face. Type an exact size while dragging if you like.

**Start from a preset.** `⇧⌘N` or **Choose a project preset…** creates a ready-made, parametric project:

| Preset | Parts created |
|---|---|
| **Cabinet / bookcase** | Left and right sides, bottom, shelf, top and an inset back |
| **Drawer box** | Two sides, front, back and an inset bottom |
| **Shelf** | A single shelf with side clearance |
| **Workbench** | Top, four legs and a lower shelf |

Enter the width, depth, height, material thickness and (where relevant) clearance. The parts are linked to named parameters, so you can resize the whole project later (section 16).

**Hardware.** Open **Add Stock**, pick an item such as *Hinge 3in butt*, *Drawer slide 18in*, *Bar pull 4in*, *Knob 1-1/4in*, *Corner brace 3in*, *Screw #8 x 1-1/4* or *Shelf pin*, and click **Add Board**. The part is brass or steel, flagged as hardware, and appears in the **Hardware** filter and the buy list. Each has a recognizable stand-in shape (a hinge with leaves and knuckles, a telescoping drawer slide, a pull on two posts, a knob, a flat brace with screw heads, a screw, a shelf pin) sized to the stock item; these are display models, not manufacturer geometry, and you can resize them like any part.

## 8. Selecting, hiding and organizing

- **Select** a part by clicking it in the model or in the Parts browser. `⇧`-click adds more. `⌘A` selects all visible boards.
- **Select a face** by clicking it with the Select tool. The status bar shows the face name and the Machining page shows joinery for that face.
- **Rename** with `Return` (or the Name field in the Inspector). Names appear in the cut list and drawings.
- **Hide** with `H`; **show all** with `⇧H` or **Show all parts**.
- **Isolate** the selection to work on part of a large model.
- **Assemblies.** Open the Workshop (`⇧⌘W`) → **Assemblies & Transforms** and use **Assign assembly** with a path such as `Cabinet/Carcass/Left`. **Select assembly tree** selects every part under a name. In the Parts browser each assembly has **Select**, **Isolate** and **Hide** buttons.
- **Part IDs.** Every part gets a shop number (for example *P003*) that appears in the cut list, labels and drawings.

## 9. Moving, resizing and rotating

**Move**
1. Choose Move (`M`).
2. Drag the board. It slides on the ground; hold `⇧` to lift it. Alternatively grab one of the colored axis handles that appear on the selected board.
3. Press an arrow key to lock an axis, type a distance and press Return.

You can also type exact position values under **Part → Position** (X, Y (up), Z) or nudge with the arrow keys (the snap increment per press).

**Move from a point.** The Move tool moves the board by the exact spot you grabbed, and snaps that spot to corners, edge midpoints and guide points on other boards. Grab a corner, drop it on another corner.

**Resize**
- Edit the size fields in the Inspector's **Dimensions** group (they are labeled by role and axis, such as *Thickness (Y)*, *Length (X)* and *Width (Z)*), or
- Use Push/Pull on a face, or
- Click the dimension label in the viewport.

If a board's size is driven by a parameter or a link the field is locked; use **Edit driving parameters…** or remove the link.

**Rotate**
- **Turn 90°** buttons (X, Y, Z) rotate the board's axes and keep its joinery attached.
- **About X / About Y / About Z** accept any angle for tilted boards, such as a slanted leg. A board that is rotated freely cannot use Turn 90°.

**Scale joinery with board.** In **Material & resizing**, turn this on if your dados, mortises and holes should grow or shrink proportionally when you change the board's size. Leave it off to keep machined sizes fixed (the usual choice).

## 10. Copying, arrays, mirroring and components

- **Duplicate** (`⌘D`) makes an offset copy with its links and joinery.
- **Copy / Cut / Paste** (`⌘C`, `⌘X`, `⌘V`). Each paste is offset so copies don't sit on top of each other. Linked joinery that belongs to a partner board not included in the paste is dropped.
- **Linear array.** Workshop → **Assemblies & Transforms** → **Linear array spacing**, then **Create N linear copies**. Use it for slats, spindles and evenly spaced shelves.
- **Circular array / rotate & copy.** **Rotate & copy** has **Rotate** and **Circular array** around a pivot (use **Use selection center** for the pivot).
- **Mirror** a part across an axis plane to make the opposite-hand piece; machining is preserved on an independent copy.
- **Scale** about a pivot bakes the result into an independent solid and removes affected dimension links, so use it sparingly.
- **Components.** Select parts and choose **Make linked component(s)** (or **Model → Make Component**). Copies share size, shape, material and machining; their placement stays independent. Use **Make unique** (**Model → Make Unique**) before editing one instance alone.

## 11. Material, grain and wood movement

In the Inspector's **Part** page:

- **Material** – species or sheet good (Red Oak, Hard Maple, Cherry, Walnut, Pine, Poplar, Plywood, MDF).
- **Material & resizing**
  - **Thickness axis** – which dimension is the board's thickness.
  - **Grain / length** – the direction the grain (or sheet grain) runs.
  - **Scale joinery with board** – see above.
- **Wood movement.** For solid wood, an estimate of seasonal movement across the board's width for a 4 % swing in moisture content (flat-sawn). Wide boards show a warning: use floating panels, elongated screw holes or breadboard ends, and do not glue wide boards across the grain.

Grain direction controls the texture drawn in the model and how the nester may rotate parts on a sheet (section 19).

## 12. Joinery

Select a **flat face** with the Select tool, open the **Machining** page of the Inspector, and use **Joinery on face …**.

**Common fields**

| Field | Meaning |
|---|---|
| **Type** | Dado, Rabbet, Mortise, Groove or Tenon |
| **Runs along** | The direction (of the two in the face's plane) the cut travels |
| **Offset** | Distance from the near edge across the cut. Turn on **Measure offset from far edge** to measure from the other side |
| **Width** | Width of the cut across its direction |
| **Depth** | How deep it goes into the board (for a tenon: **Tenon length**, how far it sticks out) |
| **Length** | Length along the run. `0` means full length (dado, groove, rabbet) or full width (tenon) |

**Types**

- **Dado** – a channel across the grain (for shelves). Length `0` runs it edge to edge.
- **Groove** – a channel along the grain (for panels and drawer bottoms).
- **Rabbet** – a step along an edge; use offset `0`.
- **Mortise** – a rectangular pocket for a tenon. With a length, it is centered on the board.
- **Tenon** – material that sticks out of the end face you selected. The cut list and flat export include the extra length.

After clicking **Add Dado** (etc.) the cut appears in the list under the tool with a trash can to delete it. **Existing joinery** below lists every cut with editable fields (**Offset**, **Width**, **Depth**, **Run start**, **Length**) and **Apply / Reset / Delete**.

**Matching joints.** Use **Machine…** → **Fit a dado to a shelf** (or Workshop → CNC & Joinery → **Fit a shelf into receiving boards…**). Pick the shelf and the receiving boards; the dado follows the shelf's thickness and position automatically, even if you move the shelf later.

**Miters and bevels.** Select the end face, expand **Miter or bevel**, and set the **Angle**, the axis to **Tilt about**, and whether the **Long point** is on the far edge.

- Tilt about the board's *thickness* axis for a miter (the cut angle shows in the face plane).
- Tilt about the *width* axis for a bevel.
- Existing angled cuts appear under **Existing miters & bevels**, with **Remove angled cut**.

**Corner relief (dogbones).** For CNC pockets with square inside corners, **Machine…** → **Add dogbones** previews and applies relief sized to your cutter diameter.

**Finger joints and dovetails.** Workshop → **CNC & Joinery** → **Finger joints & dovetails**: choose the number of fingers, depth, clearance and an optional dovetail taper angle (0–20°). Select two boards of equal width and click **Create joint on selected board(s)**; the second board gets the complementary sockets on the opposing face. Position the boards as they will be assembled first.

## 13. Holes, pocket holes and hardware

**Drilling patterns** (shelf pins, hinge cups, handles, bolt circles)

1. Select the part (and a face if you want a specific face).
2. Click **Machine** in the toolbar, then **Add shelf pins** or **Add hinge cups**; or open Workshop → **CNC & Joinery** → **New editable drilling pattern…**.
3. Set the hole **diameter**, **depth** (or **Through**), the columns and rows, the spacing, and margins. Options include a **circular bolt pattern** and a **head recess** (counterbore or countersink).
4. Click **Add drilling pattern**.

Patterns stay editable in the **Editable patterns** list. The built-in recipes use common values: shelf pins are 5 mm holes at 32 mm spacing; hinge cups are 35 mm. The hinge preset values are reasonable starting points; always check against the hardware you actually bought.

**Hardware templates.** The **Hardware** page in the Make window stores reusable patterns (for example a specific hinge plate) with a part number, a source link and a unit cost. Apply one to the selected parts and it creates a drilling pattern.

**Pocket holes.** Select the face the screw enters from (usually the underside or inside face of a rail), open **Machining**, expand **Pocket holes & edge profiles**, choose **Pocket Hole**, and set:

| Field | Meaning |
|---|---|
| **Run along** | Which direction the bore travels (toward the end of the board) |
| **Exit toward the + end** | Which end the angled bore heads toward |
| **From end** | Distance from the end of the board to where the bore enters |
| **Across pos.** | Position across the board |
| **Bore** | Bore diameter (3/8" is typical) |
| **Angle** | Angle from the face (15° is typical) |
| **Length** | Length of the bore |

Click **Add Pocket Hole**. In the cut list the board shows an extra joint. In flat exports the opening appears as a shape with a note that pocket holes are made with a jig, not on the router.

## 14. Curves, arches, chamfers and roundovers

**Chamfers and roundovers.** Select a face, open **Pocket holes & edge profiles → Edge Profile**:

1. Choose **Chamfer** or **Roundover**.
2. Choose **Edge shared with**: the neighboring face that, together with your selected face, defines the edge.
3. Set the leg or radius.
4. Click **Add Chamfer / Add Roundover**.

By default the profile runs the full length of the edge; turn off **Full length of the edge** and give a **Start** and **Length** to make a stopped chamfer or roundover that ends with a square end, like a stopped router cut. Partial profiles follow the board when you resize or turn it. A radius of half the board's thickness or width rounds the whole edge. Existing profiles are listed (under **Existing edge profiles**) with a trash can. In flat CNC output, the outline is the full blank and a note reminds you the profile needs a separate setup (router bit or sanding).

**Curved boards.** The Inspector's **Outline & curves** group and the **Edit curves…** button open the *board shape* editor. It works in the board's face plane:

- Pick the **Depth axis** (the axis through the board's thickness).
- Draw with **Draw lines**, close with **Close face**, or use **Rectangle**.
- **Curve next edge** and **Arc next edge** turn straight edges into curves; drag the handles to shape them.
- **Add point on next edge**, **Remove point** and **Undo point** edit the outline.
- **Apply shape** commits it.
- Presets include **Rounded corners**, **Oval**, **Arch** and **Curved rail**.

Curved edges are exported to CNC files as accurate polylines (maximum deviation 0.001 in).

## 15. Face sketches

For a pocket, groove or through-cut of any shape on a face:

1. Select the part and face, then click **Sketch** in the toolbar (or **Sketch a curve or pocket on this face…**).
2. Choose a shape (rectangle, rounded rectangle, slot, chamfered rectangle, ellipse or free path) and draw it, typing exact dimensions.
3. Choose the cutting mode: **Pocket**, **Through-cut** or **Groove** (open curves are grooves).
4. Optionally add constraints and fillet or chamfer corners.
5. Save the sketch. It appears in the part's feature history.

A through-cut follows the board's thickness if you change it later. Hold `⌥` while dragging to ignore snapping.

## 16. Parameters, presets and linked dimensions

**Parameters.** Open **Parameters & History** (`⇧⌘P`). A parameter is a name and an expression such as `cabinet_width = 600mm` or `shelf_height = cabinet_height / 2`. Parameters can use other parameters and units.

- **Add parameter** creates one. **Add cabinet parameters** creates the standard cabinet set.
- Bind a board dimension, position or a joint's depth, width or offset to an expression (**Bind expression**), choose **Drive** to say which property, and **Apply to entire design**.
- **Live model preview** shows the effect before you commit. **Discard preview** abandons it.

**Preset projects** are already bound to parameters, so changing `width` or `thickness` regenerates the whole cabinet.

**Linked dimensions.** In the Inspector, **Linked dimensions** lets one board's size follow another's:

1. Choose the **Source board**.
2. Pick the **Source** axis and the **Target** axis.
3. Set an **Offset** and click **Link dimension**.

For example, make a shelf's width follow the cabinet's inside width minus 1/16". **Unlink** removes the link. WoodShop refuses edits that would make a linked board or joint invalid.

**Editing a dimension in the viewport.** Click a dimension label on the selected part. A dialog accepts a new value, shows how many parts will update, and lets you **Preview** then **Apply**.

## 17. Feature history, undo and previews

- `⌘Z` and `⇧⌘Z` undo and redo almost everything, including multi-part edits.
- The **History** page of the Inspector lists a part's features in order (cuts, drilling patterns, operations and angled cuts). You can suppress a feature (**Feature enabled** off), reorder it, edit it (**Edit feature**) or delete it. **Preview to here** shows the part as it was after that step; **Resume full history** returns to normal.
- The **Parameters & History** window also has a project history with **Restore this revision**.
- Edge profiles (chamfers and roundovers) are applied after all history steps; they are listed in their own group rather than in the sequence.

## 18. Checking your design

**Assembly checks** (Make → *Assembly checks*): set a **Minimum clearance** and click **Check all woodworking parts**. WoodShop reports real intersections between parts and places with too little clearance. Intentional contact (a shelf in a dado) is allowed. **Compare selected hole axes** checks that holes in two parts line up.

**Part relationships** keeps parts aligned as the design changes: pick a **Reference** part and anchor, a **Dependent** part and anchor, and click **Keep this relationship**. Select or remove relationships from the list.

**Machining review** (Make → *Machining review*) lists errors and warnings before CNC export: overlapping pockets, features too narrow for your cutter, angled cuts that need another setup, tenons, parts that exceed the sheet. Errors block the export; warnings need a click on **Warnings reviewed**.

## 19. The Make window: cut lists, buying, sheets and CNC

Open it with `⌘L` or the **Make** toolbar button. The left list groups pages:

**CNC job:** Prepare job · Sheet layout · Machining review · Export to VCarve
**Parts & materials:** Cut list · Materials & cost · Buy list · Offcuts · Hardware
**Assembly:** Assembly checks · Part relationships · Labels & assembly
**Project:** Documents & recovery

### Cut list
One row per distinct part size, grouped by species, with thickness, width, length, quantity and a summary of any machining. Parts with different joinery do not share a row. Hardware is excluded. **Right-click** rows to **Select Parts in Model**, **Isolate Parts in Model** or **Copy Selected Rows**; use **Copy CSV** or **Save CSV…**. Footer totals give board feet of solid lumber (finished size) and square feet of sheet goods. Blank sizes include tenons.

### Buy list
Answers "what do I buy?":

- **Rough lumber:** by species and rough thickness in quarters (4/4, 5/4, 6/4, 8/4…), with allowance for planing (+1/8" thickness, +1/4" width, +1" length) and your **Waste %**.
- **Cut plan:** parts packed onto boards of your chosen **Board length** with the **Saw kerf** allowed for. Parts longer than the board get a board of their own length.
- **Sheet goods:** number of sheets (nested with your sheet size and spacing).
- **Hardware:** count of each hardware item you added.

**Save Buy List CSV…** or **Copy Buy List CSV** exports it.

### Materials & cost
Enter your own prices (per board foot, per square foot, edge banding per foot), rough allowance per side, edge-banded edges and grain-match groups per part. Totals use the actual nested sheets and offcuts.

### Sheet layout
Set the **Sheet stock** (length, width and **Part spacing**). Parts are nested onto sheets of the same material and thickness. Click a part in the layout to select it in the model. **Grain direction matters** is the default: parts keep their grain along the sheet length. Select a part and turn on **Allow selected part to rotate 90° on the sheet** (Workshop → CNC & Joinery) if grain does not matter for it.

**Two-sided work.** Choose which face is the CNC top (**Use positive thickness face as CNC top**). Turn on **Add registration drilling** to add pins for flipping the sheet accurately.

### CNC job (the five steps)
1. **Choose parts** – all woodworking parts, or only your selection.
2. **Choose stock & cutter** – open **Choose / edit setup…** to save a reusable setup: material, sheet size, actual thickness, part spacing, fit clearance, millimeters or inches, registration pins and the cutters (name, type, diameter, flute length). The cutter is used to check features.
3. **Review sheet layout.**
4. **Review machining.**
5. **Export & open in VCarve** – see below.

### Exporting to VCarve
Finish the **Prepare job** steps first (the export button stays disabled until a saved setup with a cutter is chosen and there are no errors; tick **Warnings reviewed** if any warnings remain). Then click **Export VCarve Job…** at the bottom of the Make window, and choose a folder. WoodShop creates a new, dated job subfolder containing one DXF per sheet and setup (top, bottom, side), previews, parameters, setup notes and a cut list. Single-file **Single DXF…**, **SVG…** and **STL…** exports of the current layout are also available.

DXF layers:

| Layer | Meaning |
|---|---|
| `OUTLINE` | Outside profile; the final through-cut |
| `POCKET_<depth>` | A pocket at the depth in the name |
| `…DRILL`, `…COUNTERBORE` | Holes and recesses; depth in the layer name |
| `…COUNTERSINK`, `…DOVETAIL` | Need the matching form tool |
| `CUTOUT_THROUGH` | Inside through-cuts |
| `SHEET`, `LABELS` | Reference only; leave out of toolpaths |
| `TENON`, `REFERENCE_OUTLINE` | Shoulder alignment references; leave out of toolpaths |

In VCarve: import each TOP DXF with matching units and origin (bottom-left, X0 Y0), set stock thickness, create toolpaths from the cutting layers, add tabs, simulate and post. For BOTTOM files, flip the sheet about its length (X) axis and do not mirror the vectors again. Cut the final outside profile after both faces are done. The **Open in VCarve** page lists these steps and the layer guide.

## 20. Shop drawings, labels and assembly guides

- **Export Shop Drawings (PDF)…** (File menu, or **Shop drawings PDF…** in Make): assembly views, the cut list, and a detail page per board showing its joinery and drilling dimensions.
- **Export Part Labels (PDF)…**: sticky-label sheets with each part's number and name.
- **Export Assembly Guide (PDF)…** and **Export Exploded Assembly (PDF)…**: step-by-step pictures. Edit the steps in Make → *Labels & assembly*.
- **Documents & recovery** (Make) has buttons for the exploded assembly, shop drawings and labels PDFs, a **VCarve validation package**, and a large-project performance report. The shop schedule and nested-parts CSVs are on the **Materials & cost** page, and the hardware schedule on the **Hardware** page.

## 21. Import and export

**Import** (File → **Import 3D Model or Outline…**):

| Kind | Formats |
|---|---|
| 3D models | STL, OBJ, PLY, 3DS, DXF (3D faces), Collada DAE, KMZ (the model inside it), USD, USDA, USDC, USDZ |
| Flat outlines | SVG, DXF (lines, polylines, circles) |

What happens on import:

- DAE, KMZ declare their units; other 3D formats ask you to choose **Millimeters** or **Inches** and whether the **Z axis points up** (the usual convention for SketchUp, CAD and 3D printing).
- Each separate closed solid becomes its own board, named after its group or layer.
- A solid that is just a rectangular block becomes a real **board**: its thinnest side is the thickness, its longest side is the grain direction, and the species comes from its name when it contains one (for example "Walnut shelf" or "Maple leg"). Untick **Turn rectangular solids into boards** in the import dialog to keep every solid as a generic shape. Shaped solids (with notches, curves or holes) stay as shapes.
- WoodShop welds vertices, repairs inconsistent face direction and closes small seams.
- **Skipped:** open surfaces, shapes thinner than 1/32", and shapes with more than 25,000 triangles. The status bar says how many.
- Flat outlines become boards using the thickness set in the Rectangle tool.

**Export 3D** (File → **Export 3D Model**): STL, OBJ, PLY, 3DS and DXF 3D faces (each in millimeters or inches), plus Collada DAE and USDZ (which carry their own units). The DAE carries a color per species. 3DS cannot store parts above 65,535 vertices and says so instead of writing a broken file.

**Flat export:** DXF and SVG of the sheet layout (File → **Export Flat DXF for VCarve…**).

SketchUp's own `.skp` and AutoCAD's `.dwg` are proprietary and are not supported. To exchange with SketchUp, use DAE or STL; for CAD use DXF.

## 22. Saving, recovery and units

- **Save** (`⌘S`) writes a `.wood` project file. The previous version is kept; **File → Restore Previous Saved Version** brings it back (and can be undone).
- **Open Recent** (File menu) lists your last ten projects.
- **Autosave recovery.** Every 15 seconds an unsaved project is saved to a recovery file. After a crash or force-quit, WoodShop offers to recover it on the next launch.
- If a project file changes on disk after you opened it, saving is blocked to protect the other copy; use **Save As…**.
- **Units.** Toggle **Metric** in the status bar. Everything is stored in inches, so switching never loses precision.
- **Workspace.** Which panels are open, the part filter, units and the saved CNC setup are remembered between launches.

---

# Part 3 – Projects

Each recipe lists the steps in the order to do them. Dimensions are only examples.

## 23. A simple shelf

1. `⇧⌘N` → **Shelf**. Enter width 36", depth 10", thickness 3/4". Create.
2. Or by hand: **Add Stock** → *1x12* → Material *Pine* → Length *36* → **Add Board**.
3. Rename with `Return` (*Shelf*).
4. Select the board and open the **Part** page; confirm **Y (up)** reads 3/4".
5. Add cleats or supports: **Add Stock** → *1x2*, Length 8, **Add Board**, then Move (`M`) and drop the corner onto the shelf's corner (it snaps).
6. Open the cut list with `⌘L` to confirm sizes.

## 24. A bookcase with dado joints

There are two routes.

**Route A – the parametric bookcase (dados included).**
1. On an empty model click **Try a parametric bookcase** in the welcome panel (or **Create parametric bookcase** in **Parameters & History**).
2. You get left and right sides each with three dados, plus a bottom, a shelf, a top and a back. Click each part and open **Machining → Existing joinery** to see the dados.
3. Open **Parameters & History** (`⇧⌘P`). The defaults are `cabinet_width` 600 mm, `cabinet_height` 720 mm, `cabinet_depth` 300 mm, `thickness` 18 mm, `back_thickness` 6 mm, `dado_depth` = thickness / 3, `bottom_height` 70 mm and `shelf_height` = cabinet_height / 2. Change any value and the parts and dados follow. Use the **Metric** switch to see inches.

**Route B – the cabinet preset (plain butt joints, then add your own dados).**
1. `⇧⌘N` → **Cabinet / bookcase**. Set width 30", height 72", depth 11", material thickness 3/4", back thickness 1/4". **Create project parts.** This makes two sides, bottom, shelf, top and an inset back, all linked to parameters.
2. To cut a dado for the shelf: select a side, click its inside face (`+X` on the left side, `-X` on the right), **Machining → Joinery on face → Dado**. Set **Offset** to the shelf's height, **Width** 3/4", **Depth** 1/4", **Length** 0, **Add Dado**. For a dado that follows the shelf automatically, use **Machine… → Fit a dado to a shelf** and pick the shelf and the two sides.
3. To add another shelf: select the *Shelf*, `⌘D`, then change its **Y** position.
5. **Make → Assembly checks** to look for collisions.
6. Open the **Buy list** and **Cut list**. Export **Shop Drawings (PDF)…**.

## 25. A drawer box

1. `⇧⌘N` → **Drawer box**. Enter outside width 18", depth 20", height 6", material 1/2", clearance 1/16" per side.
2. You get two sides, a front, a back and an inset bottom board. The preset uses plain butt joints. To let the bottom sit in a groove, select each side, front and back, click the inside face, **Joinery on face → Groove**, with **Width** matching the bottom's thickness, **Depth** 1/4" and **Offset** 1/4" from the lower edge.
3. To add dovetail joints, select the front and a side and use Workshop → **CNC & Joinery → Finger joints & dovetails**. Choose 3 fingers, depth equal to the thickness, **Dovetail taper** on, angle 8°. **Create joint on selected board(s)** (select exactly two boards of equal width).
4. Add a bar pull: **Add Stock** → *Bar pull 4in* → **Add Board**; Move it to the drawer front.
5. Add slide hardware the same way (*Drawer slide 18in*), one per side.
6. **Buy list → Hardware** shows two slides and one pull.

## 26. A table with mortise-and-tenon legs

1. Legs: **Add Stock** → *4x4* → Length 28 → **Add Board** (four times with `⌘D`), or use a pair of 2×2s.
2. Aprons: **Add Stock** → *1x4* or a 3/4" × 3" board, Length 32 (long aprons) and 18 (short aprons). Place them between the legs with the Move tool, snapping corners.
3. Cut a **tenon** on each apron end: select the end face (for example `+X`), **Machining → Joinery on face → Type: Tenon**. Set **Tenon length** 1", **Width** 1/2" (the tenon thickness), **Offset** so it is centered (for a 3/4" apron, offset 1/8"), **Length** 0 for full-width or 2" for a shorter tenon. **Add Tenon**.
4. Cut the **mortise** in the leg: select the leg face the apron meets, **Type: Mortise**, **Width** 1/2", **Depth** 1 1/8" (a bit deeper than the tenon), **Length** 2", **Offset** to center it. **Add Mortise**.
5. Use `⌘D` and **Mirror** (Workshop → **Assemblies & Transforms → Mirror**) to build the opposite corners.
6. Add the top: **Add Stock** → *1x12*, Length 48, three boards edge-to-edge. Fasten with figure-8 fasteners or elongated screw holes; check **Wood movement** on the top (it warns when movement is large).
7. Run **Assembly checks** to verify tenons seat fully.

## 27. A mitered picture frame

1. Add four 3/4" × 1 1/2" boards: two 20" long, two 14" long (**Add Stock** → *1x2* and set lengths).
2. Arrange them in a rectangle with the Move tool.
3. For each end: click the end face and expand **Miter or bevel**. Set **Angle** to 45°. **Tilt about** offers the two axes lying in the end face; choose the one that is the board's *thickness* axis (for a board lying flat that is Y) for a miter. Turn **Long point on far edge** on or off so the long point lands on the outside of the frame (check the result in Top view; if the corner leans the wrong way, toggle it). Press **Add Angled Cut**.
4. Check the corners in Top view (the heads-up display, or `⌘K` → Top View).
5. Add a rabbet for the glass and back: select the inside face, **Type: Rabbet**, **Width** 3/8", **Depth** 3/8", **Offset** 0, **Add Rabbet**. Do this on all four boards.

## 28. A face frame with pocket holes

1. Add the stiles (vertical) and rails (horizontal) from 3/4" × 1 1/2" boards.
2. For each rail, select the face that will be hidden (the back face), open **Machining → Pocket holes & edge profiles → Pocket Hole**.
3. Set **Run along** to the board's length direction, **From end** 1 1/2", **Across pos.** to half the board's width (3/4" on a 1 1/2" rail) for a single hole, **Bore** 3/8", **Angle** 15°, **Length** 1 1/2". Click **Add Pocket Hole**.
4. Repeat at the other end and for each rail.
5. In the Parts browser the rail's **Existing joinery** list now has *Pocket Hole* entries; delete any you do not want.

## 29. A box with finger joints or dovetails

1. Four sides from 1/2" stock, two 12" long and two 8" long, of equal height (5").
2. Position the boards as an assembled box.
3. **Workshop → CNC & Joinery → Finger joints & dovetails**: set **Fingers** to 5, **Depth** to 1/2" (the board thickness), **Clearance** 0 (or 0.005" for a snug fit).
4. Select two adjacent boards of equal width and click **Create joint on selected board(s)**. The second board gets the complementary sockets.
5. Repeat for each corner.
6. For dovetails, turn on **Dovetail taper** and set 8°. Check the CNC notes: tapered cuts need a dovetail bit or a 3D setup, and the DXF layer shows the opening.

## 30. A cabinet cut from plywood on a CNC router

1. Create the cabinet with `⇧⌘N` → **Cabinet / bookcase**; set the real sheet thickness (measure it; 3/4" plywood is often 23/32").
2. Add any shelf-pin holes (**Machine → Add shelf pins**) and hinge cups (**Add hinge cups**) to the right parts. Verify the hole sizes against your hardware.
3. Add dogbones for square corners: **Machine → Add dogbones**; enter your cutter diameter, **Preview**, **Apply relief**.
4. Open `⌘L` → **Prepare job**.
   - Step 1: **Use all parts**.
   - Step 2: **Choose / edit setup…** — name the setup, set your sheet size (for example 96 × 48), actual thickness, part spacing (at least the cutter diameter), and add your cutter. Click **Use this setup**.
   - Step 3: **Inspect sheets & machining faces**. Check that nothing is on the edge of a sheet.
   - Step 4: **Inspect issues & edit features**. Fix errors; tick **Warnings reviewed** after reading warnings.
5. Open **Export to VCarve** and run **Export VCarve Job…**. Pick a folder.
6. In VCarve: import the TOP DXF for sheet 1 with the units shown, origin bottom-left. Assign toolpaths per layer: pockets from `POCKET_*` layers, drilling from `*DRILL*`, outside profile last from `OUTLINE` with tabs.
7. If a sheet has a BOTTOM file, flip the sheet about its length and follow its setup PDF.

## 31. A tabletop with rounded edges and an arched apron

**Rounded tabletop edge**
1. Select the tabletop board and click its top face.
2. **Machining → Pocket holes & edge profiles → Edge Profile → Roundover**. Choose **Edge shared with** the neighboring face you want to round, set **Radius** 1/4", click **Add Roundover**.
3. Repeat for the other three edges.

**Arched apron**
1. Select the apron board and click **Edit curves…** (Inspector, Part page → **Outline & curves**).
2. Choose the **Arch** preset (or draw the curve: **Arc next edge** on the bottom edge and drag the handle).
3. **Apply shape.**
4. The exported DXF contains the curve as an accurate outline.

**Chamfer** for a lighter detail: same steps with **Chamfer** and a leg of 1/8".

## 32. Importing a SketchUp model

1. In SketchUp, **File → Export → 3D Model…** and choose **COLLADA File (.dae)** (best: it keeps components and units) or STL.
2. In WoodShop, **File → Import 3D Model or Outline…** and pick the file.
3. For DAE, units come from the file. For STL or OBJ choose **Millimeters** or **Inches** and keep **Z axis points up** ticked.
4. Each closed solid becomes a board. Open surfaces and zero-thickness items are skipped with a message.
5. Check sizes with the Tape Measure (`T`).
6. Rename the boards, set their species, and add joinery.

SketchUp users can also export WoodShop designs: **File → Export 3D Model → Collada DAE** and import it with SketchUp's **File → Import**. The DAE declares inches and carries a color per species.

## 33. Working out what lumber to buy

1. Finish the design and give every board its species.
2. `⌘L` → **Buy list**.
3. Set **Board length** (8' = 96"), **Saw kerf** (1/8" is typical), **Waste %** (15 % is a sensible start; use 25 % or more for figured wood or beginners).
4. Read **Rough lumber**: for each species and thickness it gives board feet to buy.
5. Read **Cut plan** to see how pieces share boards; pieces listed together on one line come from one board.
6. **Sheet goods** gives the sheet count; **Hardware** gives the fastener, hinge and slide counts.
7. **Save Buy List CSV…** for your shopping list. For cost, open **Materials & cost**, enter your prices, and read the estimate.

---

# Appendices

## A. Shortcut summary

| Keys | Action |
|---|---|
| `Space` `M` `P` `R` `T` | Select, Move, Push/Pull, Rectangle, Tape |
| `⌥`-drag, `⌥⇧`-drag | Orbit, pan |
| Pinch / `⌘`+scroll | Zoom |
| `F`, `⇧⌘F`, `0` | Zoom to selection / selection / fit |
| `H`, `⇧H` | Hide, show all |
| Arrow keys | Lock axis (while moving) or nudge |
| `Return`, `Esc`, `Delete` | Rename or apply, cancel, delete |
| `⌘Z`, `⇧⌘Z` | Undo, redo |
| `⌘C` `⌘X` `⌘V` `⌘A` | Copy, cut, paste, select all |
| `⌘D`, `⌘B` | Duplicate, add board |
| `⌘K`, `⌘F` | Command search, find part |
| `⌘L` | Make window |
| `⇧⌘N`, `⇧⌘P`, `⇧⌘W`, `⇧⌘J` | Presets, parameters, workshop, shop planning |
| `⌥⌘1`, `⌥⌘I` | Parts browser, inspector |

## B. File formats

| Purpose | Format | Read | Write |
|---|---|---|---|
| Project | `.wood` (JSON) | ✓ | ✓ |
| 3D models | STL, OBJ, PLY | ✓ | ✓ |
| | 3DS | ✓ | ✓ |
| | DXF (3D faces) | ✓ | ✓ |
| | Collada DAE | ✓ | ✓ |
| | KMZ | ✓ | – |
| | USD / USDZ | ✓ | USDZ |
| Flat outlines | SVG, DXF | ✓ | ✓ |
| CNC | DXF layers + PDF setup sheets | – | ✓ |
| Documents | PDF (drawings, labels, guides), CSV (cut list, buy list, schedules) | – | ✓ |
| SketchUp `.skp`, AutoCAD `.dwg` | – | – | – |

## C. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| "That cut falls outside the board." | The offset/width/length places the joint beyond the board. Check the units and the face you selected. |
| Size fields are greyed out | The dimension is driven by a parameter or link. Use **Edit driving parameters…** or **Unlink**. |
| "That change would make a linked board or joint invalid." | A link or parameter produced a negative or zero size. Adjust the source or the offset. |
| Export blocked | Open **Machining review**. Errors must be fixed; warnings must be marked reviewed. |
| Parts "exceed the sheet size" | Increase the sheet size in setup, or shorten/split the part. |
| Import skipped shapes | The file contained open surfaces, shapes under 1/32" thick, or more than 25,000 triangles. Close/thicken them in the source program or simplify. |
| Import appears sideways | The file's up axis is different from the choice you made; undo and re-import with **Z axis points up** toggled. |
| Pocket-hole or chamfer is not in the DXF as a toolpath | These are shop operations (jig, router bit), not router toolpaths. The DXF carries the outline or opening and a note. |
| Cannot save: "changed on disk" | Another program changed the file. Use **Save As…**. |
| Joint disappears after pasting | Linked joinery (mating dados) needs its partner board. Paste both boards together, or add the joinery again. |
| App will not open on another Mac | Right-click → **Open** once (the app is not notarized). |

## D. Limits

- Boards are boxes with machined features. You cannot sculpt arbitrary surfaces; curved outlines, chamfers, roundovers, arches and imported solids cover the common cases.
- Chamfers and roundovers stop with a square end when they are partial; they do not run out in a curve.
- Hardware shapes are simple stand-ins, not manufacturer geometry.
- Round holes are drawn as many-sided polygons in the 3D view; CNC exports use accurate circles.
- Imported solids must be closed; the importer rejects open surfaces.
- SKP and DWG files are not supported (use DAE/STL and DXF).
- The VCarve output has not been verified in every VCarve version. Always simulate in VCarve and confirm units, origin and depths before cutting.
- WoodShop is a design aid. Check dimensions, hardware and joint strength against your own judgment before cutting material.
