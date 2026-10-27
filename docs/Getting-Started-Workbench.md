# Getting Started: Build a Simple Workbench

In about 30 minutes you will design a workbench in WoodShop, size it to fit you, check it, and produce the lists you need to build it: a cut list, a lumber buy list and shop drawings.

You do not need any earlier experience with WoodShop. If a word is unfamiliar, the full manual (`WoodShop-Manual.md`) explains it.

## What you will build

A 5-foot workbench: a thick top, four square legs, and a lower shelf that rests on two stretchers. The starting dimensions are:

| Part | Qty | Thickness | Width | Length |
|---|---|---|---|---|
| Top | 1 | 1 1/2" | 30" | 60" |
| Legs | 4 | 3" | 3" | 33 1/2" |
| Lower shelf | 1 | 1 1/2" | 24" | 54" |
| Stretchers (you add these) | 2 | 1 1/2" | 3 1/2" | 54" |

Overall: 60" long, 30" deep, 35" high.

Notes on the design:

- The legs are twice the stock thickness (3" square), so you can laminate them from two pieces of 2× lumber or plane 4×4 posts down to 3".
- A solid-wood top this wide (30") is normally glued up from several boards. WoodShop models it as one board; when you build it, glue up boards edge to edge to the same finished size.
- The preset has no joinery. You will attach the top and stretchers with screws, pocket holes or bolts of your choice; section 9 shows how to add pocket holes.

## Before you start

1. Open WoodShop: double-click `WoodShop.app` (or `open WoodShop.app` from the project folder).
2. If it does not open on the first try, right-click the app, choose **Open**, then confirm. This is a one-time macOS security step for apps not from the App Store.
3. You will see an empty 3D view with a welcome panel.

---

## Step 1 – Create the workbench

1. Click **Choose a project preset…** in the welcome panel. (Keyboard shortcut: `⇧⌘N`.)
2. At the top of the sheet, click **Workbench** in the row of project types.
3. The fields change to the workbench's: **Width**, **Depth**, **Height** and **Material thickness**. WoodShop fills in 60", 30", 35" and 1 1/2".
4. Leave them as they are and click **Create project parts**.

Six boards appear. The view zooms to fit them.

> You can type measurements in any natural form: `60`, `60"`, `5'`, `1 1/2`, `38mm`. Bare numbers are inches, unless the **Metric** switch at the bottom right is on.

## Step 2 – Look around

Try these. Nothing you do while looking changes the design.

| To… | Do this |
|---|---|
| Orbit | Two-finger swipe on the trackpad, or hold `⌥` and drag |
| Pan | Hold `⌥⇧` and drag |
| Zoom | Pinch, or hold `⌘` and swipe |
| See everything | Press `⌘0` |
| Standard views | **Views** menu at the top left of the 3D view: Isometric, Top, Front, Right |

Look at the **Parts** list on the left. The workbench is a group of six parts: *Workbench top*, four legs (*Front left leg*, *Front right leg*, *Back left leg*, *Back right leg*) and *Lower shelf*. Click a name to select that part; it highlights in the model, and the **Inspector** on the right shows its details. Press `Esc` to deselect.

Each part also has a shop number such as `P001`. It appears in the cut list, labels and drawings.

## Step 3 – Choose the wood

The preset creates every part as plywood. For a solid-wood bench, change the material of each part.

1. Click *Workbench top* in the Parts list.
2. In the Inspector's **Part** page, open the **Material** menu and pick a species, for example **Hard Maple** for the top or **Pine** or **Poplar** for the frame.
3. Repeat for each of the other five parts.

(The Material menu changes one part at a time, so there is no shortcut when several are selected.)

The cut list and buy list use the material you choose, so do this before step 7.

## Step 4 – Make it fit you

A good bench height is about the height of your wrist when your arm hangs at your side, typically between 34" and 38". Everything on this preset follows named values, so you can change the whole bench at once.

1. Press `⇧⌘P` to open **Parameters & History**.
2. On the **Named Parameters** tab you will see the values created for your workbench:

   | Name | Meaning |
   |---|---|
   | `workbench_1_width` | Length of the top (left to right) |
   | `workbench_1_depth` | Depth of the top (front to back) |
   | `workbench_1_height` | Overall height, floor to top of the top |
   | `workbench_1_thickness` | Stock thickness: the top and shelf thickness, and half the leg width |

   (The remaining names, `back`, `clearance` and `inset`, are shared by all the presets and do not change anything on the workbench.)
3. Click in the **Expression** box next to `workbench_1_height` and type `37in`. With **Live model preview** ticked, the model updates as you type; the panel says how many parts are affected.
4. If you like what you see, click **Apply to entire design**. Otherwise click **Discard preview** or **Reset draft**.
5. Click **Done**.

The legs, the shelf and the top move to match. The shelf stays one quarter of the way up.

> The stretchers you add in step 5 are ordinary boards. Make your size changes **before** you add them, as this guide does, or move and resize the stretchers by hand afterwards.

## Step 5 – Add the stretchers

The preset's lower shelf only touches the legs along a corner edge, so nothing holds it up. Two stretchers solve that: each runs between the legs, under the shelf's front or back edge.

The values below are for the default sizes. If you changed the width, depth or height in step 4, use the formulas in the last column, where `t` is the stock thickness (1 1/2") and `h` is the height.

| | Length (X) | Height (Y) | Thickness (Z) | Position X | Position Y | Position Z |
|---|---|---|---|---|---|---|
| Front stretcher | 54" = width − 4t | 3 1/2" | 1 1/2" | 3" = 2t | 7 1/4" = h/4 − t | 1 1/2" = t |
| Back stretcher | 54" | 3 1/2" | 1 1/2" | 3" | 7 1/4" | 27" = depth − 2t |

To add the front stretcher:

1. Click the **+** (Add Stock) button in the toolbar.
2. Set **Stock** to **2x4**, **Material** to the species you used for the frame, and **Length** to `54`.
3. Click **Add Board**. The board appears beside the model.
4. In the Inspector's **Part** page, under **Position**, type the values from the table: **X** `3`, **Y (up)** `7 1/4`, **Z** `1 1/2`.

   A 2×4 starts lying flat. Stand it on its edge before positioning it: open **Rotation** in the Inspector and, on the **Turn 90°** row, click **X**. The board's Length stays 54", and it now stands 3 1/2" tall (Y) and 1 1/2" thick (Z), with its thin side facing front and back.
5. Press `Return` to rename it *Front stretcher*.

Repeat for the back stretcher: click **+** again, add another 2×4 at length `54`, turn it 90° with **Turn 90° → X**, set **X** `3`, **Y** `7 1/4`, **Z** `27`, and rename it *Back stretcher*.

> If you prefer, drag a stretcher with the **Move** tool (`M`) toward its place. Its corner snaps to the corners of the legs and shelf, and you can type an exact distance while dragging.

Now look at the model from the front (Views → Front). Each stretcher fills the gap between two legs, and the shelf's front and back edges butt against them.

## Step 6 – Check the design

WoodShop can check for parts that collide or sit too close.

1. Press `⌘L` to open the **Make** window.
2. In the list on the left, under **ASSEMBLY**, click **Assembly checks**. (If a section is collapsed, click its heading to open it.)
3. Click **Check all woodworking parts**.

An empty result means no parts overlap. Intended contact, such as the shelf touching the stretchers, is allowed. If it lists a problem, the message names the parts involved; close the window and correct their size or position.

## Step 7 – Get the cut list

1. In the Make window, under **PARTS & MATERIALS**, click **Cut list**.
2. Read the table. For the default bench in pine it looks like this:

   | Qty | Material | Thickness | Width | Length | Parts |
   |---|---|---|---|---|---|
   | 4 | Pine | 3" | 3" | 33 1/2" | the four legs |
   | 1 | Pine | 1 1/2" | 24" | 54" | Lower shelf |
   | 2 | Pine | 1 1/2" | 3 1/2" | 54" | Front stretcher, Back stretcher |
   | 1 | Pine | 1 1/2" | 30" | 60" | Workbench top |

3. To see where a row lives in the model, right-click it and choose **Select Parts in Model**.
4. Click **Save CSV…** if you want a spreadsheet copy.

## Step 8 – Find out what to buy

1. In the Make window, click **Buy list**.
2. Set **Board length** (96" for 8-foot boards), **Saw kerf** (1/8" for a typical blade) and **Waste %** (start at 15%).
3. **Rough lumber** tells you how many board feet to buy for each thickness. WoodShop adds 1/8" of thickness, 1/4" of width and 1" of length per board for planing and trimming, then adds your waste percentage.
4. **Cut plan** shows which pieces are cut from which board.

> The cut plan keeps each size of board separate; it does not share one board between different widths. Treat it as a safe upper estimate. If you rip a wide board into narrow ones, you can buy less than it shows.

5. Click **Save Buy List CSV…** to keep the list.

## Step 9 – Add joinery (optional)

The workbench is complete as a design. To add joinery, select a face with the **Select** tool (`Space`), then open the Inspector's **Machining** page. Two common choices:

**Pocket holes to attach the stretchers to the legs**

1. Click the *Front stretcher*, then click its underside. The status bar shows `-Y (bottom)` when you have it. (Orbit below the bench with `⌥`-drag to reach it.)
2. In the **Machining** page, open **Pocket holes & edge profiles**, and choose **Pocket Hole**.
3. Set **Run along** to the stretcher's length direction (X), **From end** `1`, **Across pos.** `3/4` (the middle of the stretcher's 1 1/2" thickness), **Bore** `3/8`, **Angle** `15`, **Length** `1 1/2`.
4. Click **Add Pocket Hole**. The bore starts 1" from the end and angles toward it, so the screw enters the leg. Switch **Exit toward the + end** off and click **Add Pocket Hole** again for the other end, then repeat both for the back stretcher.

**Roundover on the top's edges**

1. Click the *Workbench top*, then click its top face (`+Y (top)`).
2. Open **Pocket holes & edge profiles** and choose **Edge Profile → Roundover**.
3. Set **Edge shared with** to one of the neighbouring faces, set **Radius** to `1/4`, and click **Add Roundover**. Repeat for each of the four top edges.

Joinery appears under **Existing joinery** (or **Existing edge profiles**) in the Machining page, with a delete button on each item. The cut list notes joinery on any part that has it, and a part with different joinery gets its own row.

## Step 10 – Make drawings and save

1. **File → Export Shop Drawings (PDF)…** creates a PDF with views of the whole workbench, the cut list, and detail pages for the boards.
2. Press `⌘S` and choose a name and folder to save the project. A `.wood` file is created. Next time, use **File → Open Recent**.

WoodShop also saves a recovery copy of unsaved work every 15 seconds; if it ever closes unexpectedly, it offers to restore it the next time you open it.

---

## Quick check: did it work?

- The Parts list shows 8 parts (6 from the preset plus 2 stretchers).
- The cut list's total quantity is 8, and the board feet at the bottom of the cut list match what you expect (about 45 board feet, finished size, for the default pine bench).
- Assembly checks reports no problems.
- Undo (`⌘Z`) returns you through each of your changes one at a time.

## Common questions

**The preset's parts are all plywood. Is that a mistake?**
No, it is the default material for presets. Change each part's material in step 3.

**I changed the height and the stretchers did not move.**
The stretchers are separate boards, not part of the preset. Re-enter their **Position Y** with the new `h/4 − t` and, if you changed the width or depth, their length and Z positions with the formulas in step 5.

**A field in the Inspector is greyed out.**
That dimension is driven by a parameter. Use **Edit driving parameters…** under the part's dimensions, or change the value in `⇧⌘P`.

**I can't find the underside face.**
Hold `⌥` and drag to orbit below the bench, or choose **Views → Front**, then click under the stretcher. The status bar shows the face you selected.

**The Material menu is missing steel and brass.**
Those are used only for hardware (hinges, slides and so on). Add hardware from the **+** menu's Stock list.

## Where next

- Add a vise, drawers or a tool well: see **Part 3** of the manual, *A drawer box* and *A table with mortise-and-tenon legs*.
- Prepare plywood parts for a CNC router: see *A cabinet cut from plywood on a CNC router*.
- Import a design from SketchUp: *Importing a SketchUp model*.
- Every command is searchable: press `⌘K` and type what you want to do.
