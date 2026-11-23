# ShapeSmith user guide

A Vintage Story model creator targeting Godot 4.7.2.

## Run

Import `project.godot` in Godot and press F5. Use **File → Open…** (**Ctrl+O**) to
choose a standalone Vintage Story shape JSON.
You can also drag a `.json` file onto the window. **File → Open Recent** lists
the last ten files you opened or saved. Invalid files show a notice and leave
the current model intact.

Until a shape is open, the viewport shows a start panel: a new empty shape, a
new block (one 16×16×16 cube), **Open…**, and your recent files.

Notices (saved, could not open, and so on) appear in the bottom-right corner
of the 3D view and fade on their own; click one to dismiss it. The window title
shows the file name, with a **•** in front while there are unsaved edits. The
footer shows the file, its element and face counts, and the grid.

Press **Ctrl+Shift+P** (or **Edit → Command Palette…**) to find any command by
typing part of its name, then press **Enter**. The palette lists each
command's shortcut, and greys out commands that cannot run right now.

### Menus and shortcuts

- **File:** New, Open…, Open Recent, Import Shape… (**Ctrl+Shift+I**), Import
  Model (glTF, FBX)…, Save,
  Save As…, Export for Vintage Story…
  (**Ctrl+E**), Export UV Map…, Shapes…, Asset Paths…, Preferences…
  (**Ctrl+,**).
- **Edit:** Undo, Redo, Cut, Copy, Paste, Duplicate (**Ctrl+D**), Delete,
  Select All, Invert Selection (**Ctrl+I**), Rename (**F2**), Grid, Theme…,
  Command Palette….
- **Add:** Cube, Empty Group, Attachment Point, Cube from Selection Bounds.
- **View:** Perspective, Orthographic, Frame All (**Home**), Frame Selection
  (**F**), Isolate Selection (**/**), Render Mode, Lighting…, Attachment Point
  Labels, Reset Layout.
- **Animation:** New Clip, Duplicate Clip, Delete Clip, Play / Pause
  (**Space**), Insert Key (**K**), Delete Keys, Auto Key, Paste Mirrored
  (**Ctrl+Shift+V**), Insert Frame, Delete Frame, Add Marker, Graph Editor.
- **Help:** Keyboard Shortcuts, User Guide, Command Palette, About. **User
  Guide** opens this guide in the app, with its sections listed on the left and
  a search box that narrows them.

Keys **1** to **4** switch between the View, Model, Texture and Animation modes.
Single-key shortcuts are ignored while you type in a field.

To change a shortcut, open **File → Preferences… → Shortcuts**, select a
command, press **Change…** and then the new keys (**Escape** cancels,
**Backspace** removes the shortcut). If another command used those keys, it
loses them. **Reset All** restores every default. Preferences also sets the
autosave interval.

Use **File → New** (**Ctrl+N**) to start an empty model in Model mode, then
add elements with the hierarchy's **+** button or **Add → Cube**.
**Add → Attachment Point** adds a point to the selected element. **Save** opens **Save As**
for an untitled model. Creating a new document, opening another shape, or
closing the application prompts **Save / Discard / Cancel** when edits are
unsaved. Canceling Save As or a failed save keeps the current document open.

## Viewport

Use **Tools → Screenshot…** to preview and save the current 3D viewport as a PNG.
Capture omits editor panels and gizmo controls. Choose a transparent background
or the theme's solid viewport background, and optionally include the visible grid
and axes. The refresh icon ("Refresh preview") updates the current camera view and animation pose;
Save PNG opens a destination picker. The resolution dropdown offers the current
viewport size, 720p through 4K, and 1024/2048-square output. Custom resolutions
render directly at the chosen size; changing the aspect ratio changes framing.

- Left or right drag: orbit around the model. Hold **Shift** to snap to the nearest axis (front, back, left, right, top, or bottom). Release Shift to resume free orbit from that view.
- Middle drag: pan the orbit target.
- Mouse wheel: zoom.
- **Viewport → Perspective / Orthographic**: change projection without resetting the view.
- **Viewport → Frame Shape**: center and fit the loaded geometry.
- **Edit → Grid**: toggle the floor and axes independently, edit floor dimensions,
  or choose one-block, half-block, or one-shape-unit spacing.

One Godot world unit equals one Vintage Story block, or 16 shape units.
The default grid has **1 × 1 block squares** on a centered 15 × 15 block floor at Y = 0. The middle cell spans -0.5 to +0.5 on X/Z, with axis lines crossing its center. A display-only offset of (-0.5, 0, -0.5) centers the standard 0–16 shape footprint there; JSON coordinates remain unchanged.
Changing subdivisions changes only the grid, never the model scale.
**Dimensions…** accepts independent width and depth values from 1 to 255 blocks;
even values round up to keep a full center cell. High-contrast red X and blue Z
axes continue beyond the finite floor toward the horizon.

Nested cuboids, pivot rotations, scale, enabled faces, textures, UV mapping,
attachment points, and other shapes shown alongside (see Showing other shapes) are supported.
Load the shape JSON itself, rather than a
block/item definition referring to another shape.

The **Attachments** tab (Model mode, beside the Outliner) lists every
attachment point in the model with the element it is on; click one to select
that element and point. Add (to the selected element), duplicate, or delete
points there. Each point has a model-wide unique code,
position in shape units, and rotation in degrees. Select a point in the list
or click its viewport marker to edit it with the combined position/rotation
gizmo. Local/global space, snapping, Ctrl snap inversion, and Escape cancel
work as for shape transforms. **Edit shape** returns to the element gizmo.
Points follow their owners in Animation mode, where markers are previews.
Edits support undo/redo and save as Vintage Story `attachmentPoints` data.

Every element's points are labelled in the viewport, with a dashed line to the
element that owns them; the selected element's points are brighter. Click any
label to select that element and point. **View → Attachment Point Labels**
turns the other elements' labels off. Points are also listed in the outliner
under their element (⌖); click one to select it. **On element** moves the
selected point to another element: it keeps its place and direction in the
model, its code stays the same, and the move is one undo step.

**Shape Details → Rendering** starts collapsed and groups Render pass,
Shaded, and signed Depth offset. Other imported element rendering properties
are preserved in shape files. **Texture → Shader** (collapsed by default) exposes
an integer 0–255 glow slider directly below Face enabled,
face visibility, reflective mode, named wind-mode dropdowns for all vertices
or individual vertices, and wind data from 0–7 with mode-specific guidance.
Mode 8 is Fruit wind, not a frost toggle. Legacy frost flags and unknown
imported wind values are explained and preserved until explicitly edited or
reset. Disabled and missing face
directions stay available in the face selector; enabling a missing direction
creates its face. Reset buttons remove overrides, and all changes support
undo/redo. Shading and face visibility update immediately in the viewport.
Gradient shading, depth offset, random placement and color maps are stored
but not shown in the preview. The reflective mode panel describes each mode
and warns when wind shares the same face.

### How the Normal render mode matches the game

In the **Normal** render mode the viewport draws faces the way Vintage Story
does:

- **Face shading:** a face turned towards the sun is brightest, upward faces
  stay light, and faces turned away never drop below the game's floor.
  **Shaded** off keeps every side at full brightness.
- **Render pass:** each pass culls and blends as the game does. Opaque passes
  cut out see-through pixels; Blend No Cull, Transparent, Liquid and Top Soil
  blend them; the No Cull passes show both sides. **Auto** keeps soft edges
  and shows both sides.
- **Glow** brightens a face and keeps it lit at night.
- **Reflective modes** (Weak, Medium, Strong, Sparkly) add the game's
  glints, which change with the sun and as you move the camera. As in the
  game, **Mild** looks the same as Strong.

The **Lighting** button above the view (or **View → Lighting…**) sets the sun's
height and direction, the time of day (Day, Dusk, Night: use Night to judge
glow), the weather, and whether the game's shadows are on. **Wind preview**
sways faces that have a wind mode, at the chosen wind speed. These settings
are remembered and never change the shape. Unlit and Wireframe ignore them.

The preview is close to the game but not identical: the game's own fog, sky
colour, bloom and texture atlas are not reproduced, and see-through pixels in
Opaque passes are cut out at 25 % opacity.

The **View, Model, Texture, Animation** tabs share the viewport. Switching
tabs preserves the loaded model and camera.

## Model mode

Model mode edits the shape's cuboids. Select an element in the **Outliner** or
click it in the viewport, then use the gizmo tools in the tool bar at the top
left of the viewport:

- **Transform (W):** move and rotate.
- **Size (E):** drag faces to resize; hold **Shift** to edit the opposite face.
- **Scale (R):** scale the element.
- **Pivot (T):** move the rotation origin without moving the geometry.

The model inspector shows the same values as numbers: position, size, pivot,
rotation, scale and render pass. Local/global space and snapping are in the
tool bar; hold **Ctrl** to invert snapping and press **Escape** to cancel a drag.

Number fields accept expressions such as `8+4`. To change a value relative to
what is there, type `*2`, `/2`, `+4` or `-=4` and press **Enter** (a plain `-4`
is still a negative number). The coloured edge of each field matches the
gizmo axis: X red, Y green, Z blue.

At the top right of the viewport, the render-mode list switches between Normal,
Unlit and Wireframe, and the axis cube turns the camera: click an axis to look
along it. **F** frames the selection and **Home** frames the whole shape.
**/** hides every element except the selection, and pressing it again shows
them all; this is a preview and does not change the file.

### Hierarchy

Hierarchy rows alternate subtle background shades. Every element has a leading
eye toggle, a separate collapse toggle, and its indented name. The two toggle
columns stay fixed regardless of nesting depth. The eye toggle is used
to hide or show that element and its children. Child visibility flags are retained
when hiding a parent. Hidden elements cannot be picked in the viewport;
visibility is an editor preview setting and does not change the shape JSON.

The hierarchy, animation list, keyframe tracks, and texture-manager lists share
26-pixel rows. `ui/shared/editor_metrics.gd` defines this density and child indentation.

Use the outliner's **+** button to add a 4×4×4 cube under the selected
element. New cubes use the texture you last assigned to a face. In the
viewport, **Shift+A** adds one on the face under the pointer (as a child of
that element, sitting on the face), or at the centre of the view.

Drag a row to move it. Dropping on the middle of another row makes it a child
of that row; dropping on the top or bottom edge puts it before or after that
row, and a line shows where it will land. A folded row opens if you hover over
it while dragging. Moved elements keep their position in the world; hold
**Alt** while dropping to keep their numbers instead. With several elements
selected, dragging one moves them all.

Right-click a row for: **Add Child**, **Add Sibling**, **Duplicate**,
**Copy**, **Paste**, **Rename**, **Group Selection** (**Ctrl+G**), **Ungroup**
(**Ctrl+Shift+G**), **Reparent To…** (a searchable list), **Unparent**,
**Mirror…**, **Hide Others**, **Show All**, **Lock**, **Copy Path**, **Delete**
and **Delete, Keep Children**. Grouping puts the selected elements into a new
empty element in place of the first; ungrouping and Delete, Keep Children move
the children up a level. All of these keep every element where it is in the
world, and each is one undo step.

**Mirror…** reflects the selected elements across a plane (an axis and a
position, in shape units, in their parent's space). Each element's box, pivot
and rotation are reflected, the two faces across the axis swap, and every
face's texture is flipped, so it reads as a mirror image. Its children,
attachment points and animation keys mirror with it. To make a right-hand
copy of a left part, duplicate it, then mirror the copy. Mirrored elements
keep a positive scale, so they look the same in VSMC2 and in the game (VSMC2
cannot show an element with a negative scale).

The padlock beside each row's eye locks it (**Ctrl+L**): a locked element
cannot be picked in the viewport or moved with the gizmo, though you can
still select it in the outliner and edit its numbers. Locks, Hide Others and
Show All are editor settings; they are not saved in the file.

### Selecting several elements

**Ctrl+click** a row or an element in the viewport to add it to the selection
or remove it. **Shift+click** a row to select every row between it and the last
one you clicked. **Ctrl+A** selects every element in Model mode. The last
element you clicked is the active one: the inspector, gizmo and bright outline
follow it, and the other selected elements show a fainter outline.

With several elements selected, **Delete** removes all of them, and dragging
one of them onto another row moves all of them there, each keeping its place in
the world. Either is one undo step. Other actions act on the active element.

With several elements selected, the inspector shows the values they share
and "—" where they differ. Typing a value sets it on all of them as one undo
step. In Model mode the gizmo moves, turns and scales all of them together as
one undo step: each moves by the same distance, turns by the same angle about
its own pivot, or scales by the same factor. An element inside another selected
element moves with its parent only once. Size and Pivot act on the element you
clicked last; in Animation mode the gizmo keys only that element.

To rename an element, press **F2** (or **Edit → Rename**) and type the new
name in its outliner row. **Enter** renames it; **Escape** or clicking
elsewhere cancels. A name that is empty or already used is refused with a
notice.

### Undo and redo

Use **Edit → Undo / Redo**, **Ctrl+Z**, **Ctrl+Shift+Z**, or **Ctrl+Y**.
The shared history spans every shape edit (elements, faces, UVs, attachment
points, step parents and animations) as well as texture IDs and overlay
bindings, visibility, grid settings, camera projection, overlay preview, and
applied asset-path settings. Menu labels name the next action. UV drags
undo in one step; consecutive numeric changes to the same field are grouped.
Focused text fields retain their normal local text undo behavior. Orbiting,
selection, animation playback, and UV canvas navigation do not add history.

History retains up to 200 actions, fewer if they would use more than 64 MB. Editing after undo discards the redo branch.
A successful shape load starts a fresh history; a failed load preserves it.
The status marks document edits separately from preview/settings changes.
Undoing asset-path settings also restores the saved application configuration.

## Asset paths and panel layout

**File → Configure Asset Paths…** is available before loading a shape and is
also linked from Texture Manager. Configure one base path and an ordered list
of additional paths. Add, remove, and move entries up/down; Apply saves them to
`user://asset_paths.cfg`, and Cancel leaves the active settings unchanged.
These application settings survive shape reloads and future launches.

Use an extracted installation/mod folder, an `assets` folder containing domain
folders, a domain folder containing `textures`, or the `textures` folder itself.
The base root is searched first, then additional roots from top to bottom.
An explicit `domain:path` matches that domain; an unqualified path can match any
domain in each root. First match wins. The game's own folders (`game`,
`survival`, `creative` and the rest) are all the `game` domain, searched as the
game loads them: `survival` and `creative` before `game`, so their newer
textures win (the seraph's skin is the 64 × 152 one in `survival`). A shape
opened from `assets/game/shapes` finds them too. Nearby shape-pack and relative files are
fallbacks after configured roots. Paths changing while a model is open refresh
its textures immediately. Missing directories and duplicates are rejected on
Apply without replacing the current configuration.

Link File converts files inside recognized texture directories into portable
references such as `dragonology:entity/wyvern/adult/blue`; PNG extensions are
omitted. Overlay links use the same rule. External standalone images retain
their full paths. Directly linked, unconfigured texture roots remain available
for that shape session; register them in Configure Asset Paths to reuse them
across projects. A selected file shadowed by an earlier root is identified in
the manager so you can adjust precedence. Old absolute editor paths containing
`/textures/` can be recovered against configured roots after moving a project.

Drag the visible dividers to resize the hierarchy/animation list and texturing
sidebar. Default widths are approximately 260 and 360 pixels; minimum sizes
protect the viewport on smaller windows. Texture IDs, overlay layers, and the
composite preview use different surface colors in Texture Manager.

## Texture mode

1. Load a shape, switch to **Texture**, and open **Texture Manager…**.
2. **Add Texture** with an ID, then use **Link File…** to bind its base image. Existing
   shape texture IDs and paths appear automatically. **Configure Asset Paths…** enables
   `domain:path` lookup under a Vintage Story assets folder; paths near the
   shape and its sibling `textures` folder are also discovered automatically.
3. Add, remove, or reorder overlays. **Blend mode** supports Normal, Darken,
   Lighten, Multiply, Screen, ColorDodge, ColorBurn, Overlay, and OverlayCutout.
   **Preview overlays** temporarily bypasses the stack without deleting it.
4. Select an element in **Shape Hierarchy** or click a face in the viewport.
   A click selects; a drag still orbits. The inspector lets you choose a face,
   assign a texture ID, edit the UV start and end (U and V each), rotate the
   mapping, and set glow (0–255).
5. In **UV Editor**, left-drag inside the outline to move the UV rectangle,
   right-drag to pan, and wheel-scroll to zoom around the pointer. **Fit** resets
   the canvas view. Numerical UV bounds also allow resizing and flipping.

UVs use `textureWidth` / `textureHeight`, with `textureSizes` overrides per ID;
they are logical shape UV units, rather than necessarily image pixels. Image
sampling is nearest-neighbor, transparency is preserved, and lighting uses a
soft, neutral studio setup. Unassigned faces retain a neutral material; missing
assets use a pink checker and a diagnostic in the manager. Preview images are
limited to 2048 × 2048 pixels, and overlays are resized with nearest sampling
when their dimensions differ from the base.

Bindings support string paths, `#id` aliases, legacy `overlays` arrays, and VS
`base` / `blendedOverlays` composite definitions. Encoded `base++overlay~mode`
paths are understood too. Composite blending is a preview with standard color
math; byte rounding can differ slightly from the game. In Vintage Story,
composite texture definitions normally belong to block/item texture bindings.
The manager keeps those preview definitions with the in-memory shape. Saves
convert base-only definitions to texture-path strings, as required by game
shape files. Layered or otherwise modified composite definitions are rejected
before replacing the file; use a baked PNG or block/item texture definitions.
Variants, wildcard assets, connected textures,
and climate/season tints are outside this first implementation.

### The UV canvas

The UV editor shows the whole texture with every face that uses it, coloured
by direction (north and south blue, east and west red, up and down green). The
face you are editing is outlined, with an arrow pointing to its edge that
faces up on the model. Click another face's rectangle to select that element
and face. Zoom in far enough and a pixel grid appears. Turn **All faces** off
to see only the current face.

An orange outline marks faces that reach outside the texture.

Drag the handle between the face fields and the UV editor to give the canvas
more or less room; the zoom is kept.

**Selecting several faces:** **Ctrl+click** (or **Shift+click**) another
face to add it to the selection or remove it, or drag a box on empty canvas to
select every face it touches (with **Ctrl** or **Shift**, the box adds to the
selection). Selected faces are drawn in the accent colour. Dragging any of them
moves them all, as one undo step; rotate, mirror and texel sizing act on all of
them. A click on empty canvas, or picking another face, clears the extra faces.

The buttons under the header rotate the face's texture a quarter turn, mirror
its UV left to right or top to bottom, and **box unwrap** the selected
elements: each element's six faces are laid out as a cross (up and down on
top; west, north, east and south below), sized by the texel density, and
packed below the faces already on the texture. Each is one undo step.

**All faces**, snapping and **Fit** float in the canvas's top-right corner.
**Texel density** sits beside Box Unwrap: the grid button sizes
the selected faces' UVs to the texel size, keeping their origins, rotations and
flips; its **⋯** holds the texel size (shape units per image pixel, 0.5 by
default) and **Resize Every Face UV…**, which sizes every face in the model in
one undo step after asking.

### UV map export

**File → Export UV Map…** (or the download button above the UV editor) saves
a PNG of every face that uses one texture. Choose the scale (1× to 16×,
8× by default): each texture pixel becomes that many output pixels, so every
line lands on whole pixels. Each face is filled with its direction's colour
(north and south blue, east and west red, up and down green), with a border
drawn inside the face so neighbouring faces never overlap. You can also
include each element's name, a direction letter, an arrow pointing to the
edge that faces up on the model, and the texture underneath. **Separate files
per layer** also writes the fills, borders and labels as their own PNGs.

## Importing a glTF or FBX model

**File → Import Model (glTF, FBX)…**, or dropping a `.gltf`, `.glb` or `.fbx`
file on the window, turns a model from Blockbench, Blender or another tool
into a shape. The dialog says what the file holds (meshes, triangles, bones,
animations) and asks:

- **Shape units per metre:** 16 matches Blockbench and the game (a metre is a
  block). **Up axis:** Y for glTF and Blockbench; Z for some FBX files.
- **Put the model's origin at the centre of the block**, as most shapes are.
- **Parts that are not boxes:** voxelise them into cubes of the **voxel size**
  (merged into as few boxes as possible), or skip them.
- **Snap coordinates to whole shape units**, and whether to **import
  animations**.

Each node or bone becomes an element: a node holding a single cube becomes
that cube, others become groups the cubes sit in, turning at the node's
origin. Every mesh part that is a box (its corners and faces lie on one box,
flat planes included) becomes one element, rotated if the box is. Faces keep
their UVs as rectangles with the right rotation, and the model's images are
saved as PNGs next to the model file and linked. Animations are sampled at
30 frames a second into keys and thinned within the export tolerances.

**Open as New Shape** opens the result unsaved (Save asks where to put it);
**Merge into This Shape** continues with Import Shape's choices. Afterwards
a notice says whether everything converted exactly; if not, a report lists
each part that was voxelised, skipped or otherwise approximated.

Blocky models (Blockbench, or boxes in Blender) convert exactly. Organic
meshes are not boxes: voxelising follows them only roughly, and very
detailed parts are skipped (try a bigger voxel size).

## Showing other shapes

**File → Shapes…** (or the **Shapes…** button above the outliner) shows other
shape files with the one you are editing: a body under armour, a rider on a
mount, a backdrop. It works like VSMC2's shape manager and saves the same keys,
so a file can go back and forth between the two tools.

**Add Shape…** adds a file. Each of its root elements becomes its own row, so
you can place a saddle and a rider from the same file separately. The rows
marked ◆ are the roots of the shape you are editing. For another shape's row:

- **Shown**, **Opacity**, and **Solid** with a colour (to tell shapes apart).
- **Own clips:** off, it plays the clip with the same code as the clip you
  are previewing; on, choose which of its clips plays while your current clip
  plays.

Every row also has an **Origin** (**Attach to**): what the root follows. Its
button opens a list with a search box: the attachment points first (there are
usually only a few), then every element; type to narrow it and press **Enter**
for the first match. The clip list under **Own clips** and the step parent
list in the shape inspector work the same way.

- **Nothing:** it stays where its own file puts it.
- **Element:** it moves with an element of any shown shape, including while
  that element is animated.
- **Point:** it sits on an attachment point, turned the way the point is.
  **Mount offset** measures the point from the block's centre (8, 0, 8), as
  the game does for mounts.

The **Translation**, **Rotation**, **Scale** and **Pivot** below adjust the root
from there, like the game's item and seat transforms. A root that only has a
step parent follows that element when it is in a shown shape.

**Step parents** are game data on a root element (`stepParentName`, set in the
shape inspector under **Step parent**): when the game adds this shape to an
entity as an extra part (clothing or armour on a seraph, gear on a creature),
it hangs that root under the named element of the entity's own shape, so the
part moves with that element's animation. ShapeSmith saves the name and, when
the entity's shape is shown in the Shapes window, previews the part following
it. Choices that
would make shapes follow each other in a loop are greyed out; if a file has
one, the window says so and those shapes stay where their files put them.

**Open in Context…** edits the selected shape instead: the shape you were
editing becomes one of its shown shapes, and every origin is kept. Save first
or discard your changes when asked.

Files from ShapeSmith 1 (backdrops and attachments) and VSMC1
(`backDropShape`) are converted when you open them; save to keep the new form.

## Importing another shape

**File → Import Shape…** (**Ctrl+Shift+I**) merges another shape file into the
open one. You can also drop a `.json` onto the window and choose **Import…**.
The dialog asks:

- **Put it** at the root, or under the selected element.
- **Placement:** keep the elements where they are in their own file, or treat
  their numbers as relative to the new parent.
- **Animations:** merge into clips with the same code, add them as new clips,
  or skip them.
- **Texture size** (only when the files differ): rescale the imported UVs to
  this shape's texture size, or keep them with a `textureSizes` override.

Element names that are already taken get a number (Head → Head2), and the
imported animations and step-parent links follow. A texture ID with the same
path is reused; one with a different path gets a new ID (`#body` → `#body_2`).
Relative texture paths keep pointing at the same files. Attachment point codes
that clash are renamed too. A notice lists every rename, and the whole import
is one undo step.

## Saving

Use **File → Save** (**Ctrl+S**) or **File → Save As…** (**Ctrl+Shift+S**)
to write a `.shapesmith.json` working file. Saving an imported game shape first
opens Save As. A working file is still a valid game shape: its animations are
the baked game keys, so it plays correctly in Vintage Story and opens in VSMC2.
Your own keys and curves are kept under the `shapesmith` key (format version 2),
one track per element channel, and are what ShapeSmith edits when you open the
file again; a clip whose game keys already say everything (linear keys with no
eases, curves, markers or IK controller keys) is not stored twice. Files are
written like the game's own: tab-indented, with each pose, face and short list
on one line, and animation values to four decimals. Elements are tracked by ID, so if another tool renames or moves an
animated element, ShapeSmith tells you and keeps its keys under its old name.
Working files from earlier versions of ShapeSmith open as before and are
written in the new form when you save. Saving finishes pending edits and marks the
current history revision saved; undo/redo still works across that point.
The file is replaced only after a temporary sibling file has been written.
Unknown JSON fields and embedded animations are preserved; preview poses,
visibility, and transport settings are not written. Save As rebases local
texture paths while preserving named game asset references. Linked images
are referenced rather than copied. Composite bindings remain editor preview
data; game exports still require supported texture-path bindings.

Drag a `.png` onto the window to add it as a texture ID named after the file.

### Panels and layout

The left dock has **Outliner** and **Animations** tabs. Model and Texture mode
show the Outliner; Animation mode opens Animations, and you can switch to the
Outliner there too. In Texture mode the right sidebar has **Face** (the face
and UV editor) and **Textures** (the Texture Manager: texture IDs, base
images, overlay layers and a preview). The Texture Manager is no longer a
separate window, so you can keep editing while it is open.

Each mode remembers the tabs you chose and any panel you resized, between
sessions too. **Viewport → Reset Layout** (or *Reset Layout* in the command
palette) returns every panel to its default size.

### Autosave and backups

Every two minutes, unsaved edits are written to an autosave in the
application's user folder. Saving, opening another file, or closing normally
removes it. If ShapeSmith stops unexpectedly, the next launch offers to
**Recover** those edits (or **Discard** them). Recovered edits reopen as unsaved
changes to the original file. To change the interval, set
`interval_seconds` under `[autosave]` in `autosave.cfg` in the same folder.

Each time a save replaces a file, the previous version is copied to
`backups/<file name>-<number>/` in the user folder. The last five versions of
each file are kept.

## Animation

In Animation mode the left side has **Animations**, **IK** and **Poses** tabs; the
dope sheet lists the elements, so there is no Outliner tab there.

Select an authored keyframe to choose **Linear**, **Ease In**, **Ease Out**,
**Ease In/Out**, or **Hold** under each keyed position, rotation, or scale group.
The curve describes the transition to the next key in that group. Repeating
animations also apply the last key's curve across the loop boundary. Curve edits
support undo/redo. Enable **In-between keys** in the player to show dim, read-only
generated markers; selection, copy/paste, movement, and deletion operate on the
authored keys.

Use **File → Export for Vintage Story…** to produce a separate game `.json`.
The bake interval determines how often curves are sampled (1 frame gives the
highest fidelity). Original frame times are always retained. Reduction then
removes redundant in-between frames:

- **Auto** uses maximum per-axis errors of 0.01 shape units, 0.1 rotation degrees,
  and 0.001 scale units.
- **Custom** enables exact position, rotation, and scale tolerance inputs.
- **Off** retains every sampled in-between frame.

Tolerances measure error relative to the sampled bake, including interpolation
between its samples. Increasing the bake interval changes that reference; use 1
when accuracy matters. The preview and motion previews use the same baked keys as
export. Export merges generated keys into standard animations and removes the
working marker and curve metadata. Exporting preserves the working-file path and
does not mark unsaved edits as saved. Reopening a game export treats all its keys
as authored; use the working file to retain editable curves.

In-between markers and counts include only non-linear spans on the affected
shape tracks. Linear position and scale tracks retain their authored keys.
Vintage Story shares frame boundaries across tracks; when those extra boundaries
would change another rotation's shortest path, export retains the necessary
rotation support samples. These are reported separately and do not appear as
curve in-between markers.

Load a shape with an embedded `animations` array and switch to **Animation**.
The side list selects an animation; the bottom player provides Play/Pause, Stop,
first/last frame, single-frame stepping, and a draggable timeline or frame input.
Preview playback uses 30 FPS, with an adjustable play rate (0.25×–2×) and loop
override. The compact header contains an editable animation code labeled `code` and scrubber;
frame, loop, duration in frames, and play-rate controls sit in the bottom bar.
Changing duration updates `quantityframes` and the timeline range. Its minimum
is one frame beyond the last existing key, so shortening never deletes keys.
Drag the horizontal divider above the
player to change its height, or the vertical divider between track names and
keyframes to change the mini hierarchy width. Name rows and keys stay aligned
while resizing and scrolling.

Only the selected animation row shows a rename icon. The display name and code
are edited independently; both must be nonempty and unique, ignoring case and
surrounding whitespace.
Renaming an imported animation with an omitted code preserves its original
effective identifier. **New**, **Delete**, and **Duplicate** sit below the list.
New creates a 30-frame clip; duplicate copies all metadata and keys with a unique
name and code. All animation changes support undo/redo and normal Save/Save As.

The dropdowns beside the playback buttons on the left edit `onActivityStopped` (**Play Till End**, **Rewind**,
**Stop**, **Ease Out**) and `onAnimationEnd` (**Repeat**, **Hold**, **Stop**,
**Ease Out**). Imported numeric enum values are recognized too. These are game
activity/blend settings saved with the animation; the single-clip preview does
not simulate in-game crossfades. Play/Pause retains the current frame, and
non-repeat preview playback holds its final frame.
The dropdowns stay grouped with playback buttons at narrow widths; frame,
duration, loop, and play-rate controls wrap together when necessary.

Each shape keyframe has **Auto** under **Shortest rotation path**, enabled by default.
Editing a rotation compares all eight per-axis flag combinations and chooses
the shortest sampled orientation path, with a small smoothness preference.
Affected neighboring keys and the loop boundary update in the same undo step;
manual keys are preserved. Disable Auto for explicit spins or manual axis
flags. The per-key preference is saved in editor metadata, while standard VS
shortest-distance flags drive exported playback. Loading a file alone does not
rewrite existing flags. Gizmo rotations choose the nearest equivalent XYZ
Euler representation, including continuity through gimbal-lock crossings.

The player also shows a mini hierarchy beside aligned keyframe tracks. Click a
shape to inspect its authored properties at the current frame, or click a
diamond to select the shape and seek to that key. Frame details show position
offsets, rotation, scale/stretch, and the axes and values explicitly keyed.
Shortest-rotation flags and stored origin fields are shown too. Origin fields
are preserved but are not animated by this preview; the current upstream
playback implementation interpolates position, rotation, and stretch only.
See the [keyframe format](https://apidocs.vintagestory.at/api/Vintagestory.API.Common.AnimationKeyFrameElement.html)
and [upstream playback](https://github.com/anegostudios/vsapi/blob/master/Common/Model/Animation/Animation.cs).
The full details for collapsed descendants are available in the details tooltip.

Selecting one expanded diamond opens the right-hand keyframe inspector, showing its
shape and frame. Checkboxes indicate whether each X/Y/Z position, rotation, or
scale/stretch axis is explicitly keyed; unchecked axes are absent from the JSON.
Enable an axis to key it, disable it to remove that axis, or edit its value.
Shortest-rotation flags are editable too. Existing origin fields are displayed
as stored metadata, since the playback path does not animate them. These edits
update the preview and support undo/redo and normal saving, including pending
numeric text. Collapsed selections and multiple selected keys leave the inspector
empty. Selecting a
different animation or closing the inspector clears the selected marker.

Folding a shape is synchronized between the main hierarchy and mini hierarchy.
Collapsed rows display the union of their subtree's key timings: solid diamonds
include an own key, while hollow diamonds represent descendant-only keys.
Tracks and names share a scroll area so their rows stay aligned. Selected keys
have yellow outlines. Ctrl-click (or Command-click) toggles keys in the selection;
dragging empty timeline space draws a selection box, with Ctrl adding to the
current selection. Drag any selected key to move the whole group by the same
integer frame offset. Collapsed diamonds select and move every represented
element key. Moves preview during dragging and commit once on release, with
undo/redo and normal saving. Animation bounds clamp the whole group together;
collisions with an unselected key for the same shape reject the move without
overwriting data. Escape cancels a drag or box selection.

Moving, rotating or scaling a shape with the gizmo in Animation mode creates a
key at the current frame, or updates the key already there, while **Auto Key**
(the red ● beside the playback buttons) is on. Turn it off to try a pose
first: the change stays on screen until you press **K** to key it, and is
dropped when you change frame. **K** keys the selected shape's position and
rotation (and scale, if you changed it). Press **Delete** to remove the
selected keys. **Ctrl+C** copies the selected keys and **Ctrl+V** pastes them
at the playhead, in this clip or another one. **Ctrl+Shift+V** pastes them
mirrored: keys of a left element go to the right one (Left and Right, left and
right, and L and R as in ArmL, Arm_L or L_Hand swap), with position X and
rotation Y and Z flipped. Right-click the timeline for the same commands.

The **+** box at the end of a keyed shape's row opens rows for its Position,
Rotation and Scale, and their X, Y and Z, showing where each is keyed. Click
one of those rows, then press **K**, to key just that group at the playhead.
(The game stores the three axes of a group together, so keying one axis keys
all three.)

When two or more keys on different frames are selected, a bar with a handle
at each end appears under the ruler. Drag a handle to stretch or squeeze the
selected keys in time; the other end stays put. **Insert Frame** and **Delete
Frame** (in the Animation menu or by right-clicking the timeline) add or
remove a frame at the playhead, moving every later key and changing the
clip's length.

**Add Marker** puts a named marker on the ruler at the playhead, such as
"Contact" or "Lift". Click one to jump to it, drag it to move it, and
right-click it to rename or delete it. Markers are saved in the working file
but not in game exports.

The preview supports animation versions 0 and 1, sparse offset/rotation/stretch
tracks, nested transforms, cyclic keyframe interpolation, and per-axis
shortest-distance rotation flags. Translation uses shape units. Non-repeat end
behaviors default to holding the final frame; the Loop control overrides this
for preview. This is single-clip playback, without in-game activity blending,
animation events, attachment handling, or external animation/shape composition.

Selecting another animation clears the previous pose. Leaving Animation mode
stops playback and restores the model's rest pose; returning restores the selected
preview frame. Invalid animations show an error tooltip and remain selectable
for metadata repair or deletion; their playback controls are disabled. Shapes
without animations show an empty state with New available.

### Poses

The **Poses** tab (Animation mode) keys poses at the playhead, each as one
undo step. Its tools act on the selected parts, or on the whole model when
nothing is selected; the line at the top says which.

- **Pose library:** type a name and press **Save Pose** to keep the current
  pose for later, in this clip or any other. Select a saved pose and press
  **Apply Pose** (or double-click it) to key it; **Amount** applies it part of
  the way. **Delete Pose** removes it. Poses are saved in the working file.
- **Copy and paste:** a quick copy that is not saved. **Copy Pose**, move the
  playhead, **Paste Pose**. The line under the buttons shows what was copied.
  Use the library for a pose you want to keep.
- **Quick poses:** **Mirror Left ↔ Right** swaps left and right poses (ArmL and
  ArmR, LeftLeg and RightLeg), mirrored; parts without a side are mirrored in
  place. **Reset to Rest** keys the rest pose.
- **In-between:** set how far from the previous key to the next one, then
  **Key In-between**.

Every tool keys only the parts it actually changes, and only the values
(position, rotation, scale) that change: the game allows few animated
elements, so a part already in the pose is left without a key. Every tool says
what it keyed in a notice, or why it did nothing: for example
that a saved pose holds parts that are not selected, or that an in-between
needs keys on both sides of the playhead.

A typical use: select nothing (the whole model), pose the creature, **Save
Pose** as "Crouch"; later, in any clip, move the playhead and **Apply Pose**.
A pose saved with one part selected holds only that part, so applying it
changes only that part.

A warning appears when a clip animates more than 200 elements; the game
handles up to 230.

### IK chains

An IK chain lets you pose bones by a target: drag a foot's target and the
thigh and shin bend to reach it, or drag a head's target and the head turns to
look at it. Chains are in the **IK** tab (Animation mode).

1. Press **Add Chain…** and choose the kind:
   - **Two bones** (a leg or an arm): pick the upper and lower bone; the lower
     bone's tip reaches the target and the joint bends towards an optional
     **pole**.
   - **Three bones** (a hind leg: thigh, shin and the long foot bone): the tip
     reaches the target, the bones stay in the pole's plane and the knee points
     at the pole, so the leg keeps its zig-zag.
   - **Chain** (a tail or neck): pick the first and last bone; every bone in
     between joins the chain and bends a little so the tip follows the target.
   - **Aim** (a head or eye): one bone turns to point at the target.

   The selected element is taken as the lowest bone, with its parents above
   it. Name the controllers if you like.
2. An orange **target** (and a purple pole) appear. Click a marker to select
   it; its gizmo sits on it, and the bones follow while you drag. Targets and
   poles only move (the gizmo shows arrows only): the solver uses where they
   are, not which way they turn. In a clip,
   key the target: a chain only works in clips where its target is keyed.
3. **Strength** blends between IK and the bones' own keys (0 keys only, 1 IK
   only). To change it over time, set the slider and press **Key Strength** at
   different frames; **Clear Keys** removes this clip's strength keys. **On**
   turns the chain off, and the list below chooses the pole.
4. **Remove** deletes the chain and its controllers.

The game has no IK, so saving and exporting turn each chain into rotation keys
on its bones and leave the controllers out of the game data; the export tells
you how many keys it wrote. The bones are keyed only at frames where something
moves the chain: a key on its target or pole, on an element above it (a body
moving over a planted foot), or on its strength. The game plays straight lines
between keys and allows little animation data, so keys in between would add
nothing. For a smoother movement, give the target's keys an ease (Ease In,
Ease Out, Ease In/Out): the export writes eased spans as in-between keys, and
the bones are keyed at those too. **Bake to Keys** does the same in the
current clip as an undoable edit, if you want to keep editing the keys by
hand. Working files keep the chains and controllers.

Chains find their bones and controllers by name, so give them unique names
and keep them when renaming.

### Graph editor

**Animation → Graph Editor**, or the **Graph** switch under the timeline,
shows the selected element's channels as curves in place of the dope sheet:
X red, Y green, Z blue, with rotation lighter and scale darker. The
**Channels** list on the left shows or hides them: **X**, **Y** and **Z** for
one curve, the group's name (**Position**, **Rotation**, **Scale**) for all
three. The key tools run along the top. Dim dots are the game keys an export
writes (**Game keys** hides them).

- Click a key to select it (Shift adds more). **Frame** and **Value** show
  and edit it. Drag a key up or down to change its value, or sideways to move
  the element's key at that frame in time.
- Choose how a key moves on to the next one: **Constant** (holds, then
  jumps), **Linear**, or **Bezier** (a curve).
- Choose how its handles are set: **Auto** (smooth), **Auto Clamped**
  (smooth, but flat at a peak or dip, so it never overshoots), **Aligned**
  (both handles on one line), or **Broken** (each handle on its own). Dragging
  a handle makes an Auto key Aligned.
- **Use Preset** returns the selected keys to the clip's ease preset (the
  Linear, Ease In, Ease Out, Ease In/Out and Hold choices in the keyframe
  inspector), which the graph shows as their curves.
- Drag on empty space to box-select keys (Shift adds); click it to move the
  playhead. The wheel zooms time (**Ctrl**:
  values), middle-drag pans, **Frame All** fits everything, and **Normalize**
  scales every curve to the same height.

The game only plays straight lines between keys, so curved spans are written
as extra keys when you save or export, within the export tolerances. Each
graph edit is one undo step.

### Motion paths

Animation mode's Motion Path toggle previews translucent copies of the actual
shapes at surrounding frames, omitting the solid current-frame model. Previous
frames are red and future frames blue in both shape and path previews.
Its popup switches between ghost shapes and center paths, and selects one shape,
the selected shape with its descendants, or the entire hierarchy. A slider sets
the frame window, capped at the current animation's length. The default is Motion
Path with ten frames (or the animation length when shorter). Other settings control
opacity, and optional fading by frame distance from the playhead. Windows stay
within the clip boundaries; sampling does not change the document or live pose.

### How playback is computed

Animation playback uses Vintage Story's two interpolation stages: compile each
element at the shared animation frames, then interpolate those compiled poses.
This includes loop boundaries, Hold, shortest-axis flags, animation versions,
and parent transforms. Automatic shortest-path selection scores this same
evaluator. The preview plays one clip; entity animation state machines and
simultaneous clip blending are outside the player UI.

## Interface and themes

The header stays 36 pixels tall, with File at the left and the brand centered
independently of menu width. Resizing grows the workspace instead of scaling
the interface. The default palette uses charcoal chrome, blue accents, and a
subtle checkerboard behind the 3D scene. Checker cells stay 20 screen pixels
wide during navigation.

**Edit → Theme** provides live theme editing in a compact, resizable window
with scrolling color properties. Dark Blue, Graphite, Forest, Light, and Vintage
presets can be customized with grouped color pickers. Apply saves the palette
in the user preferences; Cancel or closing the editor restores the applied
colors. Reset previews the default theme. Import and export share versioned
JSON themes. Model textures and lighting remain independent.

## References

Official tool reference: [VSMC2](https://github.com/anegostudios/vsmc2).
Shape transform reference:
[Vintage Story ShapeElement](https://github.com/anegostudios/vsapi/blob/master/Common/Model/Shape/ShapeElement.cs).
Animation reference:
[Vintage Story Animation](https://github.com/anegostudios/vsapi/blob/master/Common/Model/Animation/Animation.cs).
Composite reference:
[Vintage Story CompositeTexture](https://github.com/anegostudios/vsapi/blob/master/Client/Texture/CompositeTexture.cs).
