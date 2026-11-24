# Settings tab: the local node console

**Question (owner, 2026-07-25):** the Settings tab "looks like a different app" next to
Contacts and Chats. The local node is a CIRCLE, not a hex, so the avatar stays round —
everything else was up for rework. What should it look like?

**Answer: variant A, "local node console". Shipped.** Variant B (A plus a trace spine down
the left gutter) was built, rendered, and **not** taken.

The prototype (`frontend/test/preview/settings_console_prototype.dart`) has been deleted —
variant A is now the real screen, so the prototype's copies would have rotted immediately.
The renders in this folder are of the REAL `SettingsScreen`.

## What was wrong, concretely

All from the pre-rework `settings_screen.dart`:

| Smell | Where | What Contacts/Chats do |
|---|---|---|
| Zero hexagons | whole file | everything is built on `hex_avatar.dart` |
| A tinted glass card per row | `_settingsTileShell` | opaque rows (playbook §1: glass = floating chrome only) |
| Stock Material glyphs + a chevron on all 8 rows | `ListTile(leading: Icon(...))` | no chevrons at all |
| Radius soup: 16 / 20 / 8 / circle | tiles, lang pills, logout button | hex + SPEC 26/16 |
| Hardcoded `Colors.white` ×2 | avatar badge, logout button | tokens only |
| 8 flat tiles then 4 loose `Padding`s | the `ListView` body | structured |

## What shipped

- **The local node is now literally the same object as the Contacts core.** `LocalNodeCore`
  (`lib/widgets/local_node_core.dart`) was extracted out of `contact_network_view.dart`'s
  private `_LocalReticlePainter` and is consumed by BOTH. It stays a circle on purpose —
  that shape difference is what marks it as the local node.
- **Hex-leading opaque rows** at the same 44px hex / left offset 12 / 12px gap that the Chats
  list and the Contacts classic list already use (the owner's row-parity rule). No cards,
  no dividers, no chevrons — the row is the affordance.
- **The glyphs inside the hexes are drawn, not Material** (owner: *"dont forget to also change
  whats inside those hexes"*). `ConsoleGlyphPainter` draws all nine in one 24-unit design
  space at a single 1.6 stroke weight with round caps, which is what makes a hand-drawn set
  read as instrument line-work instead of clip art.
- **Section captions** (`PREFERENCES` / `SECURITY` / `SESSION`) copy the type of the
  already-shipped Appearance sub-screen (`appearance_screen.dart` — its `COLOR THEME` /
  `CHAT BACKGROUND` labels) so the root and the screen it opens speak one dialect.
- **The Appearance row keeps the real `AppearancePreview`**, hex-clipped and deliberately
  oversized: the miniature paints its own radius-12 border, and at anything near the hex's
  size that border cuts visible arcs across the interior.

## Two defects the RENDER caught that the code review did not

1. **Light theme merged Delete Account and Log out into one alarm block.** Both rows had a
   5% wash, and on the light themes `primary` is nearly the same ember as `error`, so the two
   washes ran together and logging out looked as destructive as deleting your account. Fixed:
   the filled wash is now reserved for `ConsoleRowEdge.danger`; `accent` is edge-only.
   Pinned by `settings_console_test.dart`.
2. **Variant B's spine collided with the lit row edges.** The rail sits at x=6 and the
   danger/accent edges are a 3px border at x=0 — in the SESSION block they fight for the same
   gutter. B also carries no information: on the Contacts board a trace means "this contact
   connects to your node", which is real, whereas a Settings rail connects rows to nothing.
   **If B is ever revisited, that gutter conflict is the thing to solve first.**

An earlier B render also dropped the rail straight through the centred `LOCAL NODE` caption,
because the elbow derived the core centre from the block's mid-height rather than the avatar.
Leaving via the west tick is the fix.

## Renders

Real `SettingsScreen`, 390×844, English, top of page + the SESSION block:

- `settings-console-cosmic-top.webp` / `settings-console-cosmic-session.webp`
- `settings-console-light-top.webp` / `settings-console-light-session.webp`
- `settings-console-blue-top.webp` / `settings-console-blue-session.webp`

## Still open

- The Appearance / Privacy / Blocked **sub-screens** still use glass cards. The root now
  speaks console; those screens are the next seam. Not in scope for this round.
- The old floating "person" badge over the avatar is gone — tapping the core opens your user
  card instead. Worth watching whether that reads as tappable on a device.

## Addendum — variant B re-rendered on the shipped console (2026-07-25)

The owner asked to see the other option again after A shipped. B was rebuilt as
*the real console plus a rail*, composing the production `SettingsConsoleRow` /
`SettingsSectionCaption` / `LocalNodeCore` widgets so only the painter was throwaway. The
prototype has been deleted; these renders are the record:

- `spine-cosmic-top.webp` / `spine-cosmic-session.webp`
- `spine-light-top.webp` / `spine-light-session.webp`

**The earlier "the spine collides with the lit edges" verdict was too harsh and is corrected
here.** With the elbow leaving the core's west tick (instead of dropping from the south tick
through the centred caption), B renders cleanly. In the SESSION block the 3px danger edge at
x=0 and the rail at x=6 read as two parallel verticals ~6px apart — doubled, slightly busy,
but not merged. That is a real cost, not a defect.

The stronger argument against B is not visual:

- **The rail carries no information.** On the Contacts board a trace means "this contact
  connects to your node" — it is a real relationship, and the node count never lies. A
  Settings rail connects rows to nothing; it is decoration wearing the costume of the app's
  one load-bearing idiom. That cheapens the idiom everywhere else it is used.
- **It encloses the page.** A full-height vertical line down the left gutter indents and
  boxes the content, which is most noticeable in the light themes.

If B is ever adopted anyway, the two things to decide first are (a) what the rail *means*,
and (b) whether the danger edge moves, since a doubled left gutter is the price otherwise.

## Round: B was built and shipped — SUPERSEDED, see "FINAL" at the bottom (2026-07-25)

> **This section is history.** The bus described below was deployed and then reverted on
> device. Variant A is what ships. Kept because the reasoning and the traps are still worth
> reading, and because a future attempt at the wiring needs to know what was already tried.

The owner took B and, asked what the rail *means*, gave the answer that settles it:

> "hexes looking like a honeycomb so the rail is highlighting the honeycomb in a
> technological way, my idea was to create something that looks like inside a computer —
> honey shapes, a technologically used honeycomb shape connected by lines, which is to
> visualize the technological transfer of information from the local node — the user's
> avatar — to other contacts. In the settings, it is supposed to be connected to each line
> coming from the avatar as if it were connected to it."

So the rail is **the local node's own bus**. The app reads as the inside of a computer:
hexes are the honeycomb, lines are traces, information flows out of the local node. Every
settings row is a FACET OF YOUR OWN NODE, so wiring each one back to the core is literally
true — which was the test my earlier "it means nothing" objection failed. Objection
withdrawn.

**This does NOT contradict the "no bus / no shared-rail wiring" rule on the Contacts board.**
That rule exists so the honeycomb can never imply a contact-to-contact relationship that does
not exist; there, every drawn line must be one real user→contact edge and the node count must
not lie. Settings has exactly ONE node and the rows are its parts. The rule and the bus are
different claims. This is written into `settings_console.dart`'s header too, because a future
agent citing that rule would otherwise delete the spine.

### The doubled gutter, resolved by merging the two signals

Rather than a red 3px border at x=0 sitting beside a grey rail at x=6, **the bus itself lights
up**: `ConsoleRowEdge.danger` paints that row's rail and stub in `error` at 1.6px/0.95 alpha,
and the left border is gone entirely. The wiring carries the warning instead of running
parallel to it.

**Only `danger` lights the bus.** Log out sits directly beneath Delete Account, and on the
light themes `primary` is nearly the same ember as `error` — lighting both painted one
continuous bright rail across the two rows, which is exactly the merged-alarm-block bug from
the first round relocated from the border to the bus. Log out is marked by its tinted hex and
title alone, and the bus terminates at it with an end cap.

Renders of the shipped result: `bus-cosmic-top.webp`, `bus-cosmic-session.webp`,
`bus-light-top.webp`, `bus-light-session.webp`. Harness: `tool/preview/settings_preview.dart`.

### Open: one trunk vs a literal fan

The owner's words say "each line coming from the avatar", which could mean N rays fanning from
the core to each row rather than one trunk with stubs. He approved the trunk from a render, so
that is what shipped, but the fan is a **modest** change, not a big one: Settings has ~12
children and does not need laziness, so swapping the `ListView` for a `SingleChildScrollView` +
`Column` inside a `Stack` lets one full-height painter draw real rays with measured row
positions. Cost is that swap plus two existing tests that assert `find.byType(ListView)`
(`settings_screen_scroll_physics_test`, `settings_screen_version_footer_test`). The reason the
fan was reverted on Contacts does NOT apply here — that failure was N rays converging on a 34px
rim at 100 contacts; nine rows render fine.

## FINAL: the bus was REVERTED on device (2026-07-25)

**Variant A — the console WITHOUT the spine — is what ships.** The bus was built, shipped as
`2b646c1`/`18c97a9`, deployed, and then reverted after the owner saw it on his physical phone:

> "now when i see it on the phisical phone i noticed the other option was a better choice
> please revert it to the previous one"

No hedging on this one: it was rendered, reviewed, tested, deployed, and still wrong once it was
in a hand. **That is the whole argument for the device pass.** Every screenshot in this folder is
390×844 at 2× on a desktop monitor; none of them reproduce a real phone at arm's length, where
the full-height rail reads heavier and more enclosing than it does in a render. The earlier note
in this file flagged "it encloses the page" as a risk — the renders were not enough to settle it,
and the device was.

### What was reverted, and what was kept

Reverted by restoring `settings_console.dart`, `settings_screen.dart` and
`settings_console_test.dart` to their exact `a342640` contents — byte-identical to a build the
owner had already approved, which is a stronger guarantee than hand-unpicking the diff. Gone:
`ConsoleSpinePainter`, `ConsoleSpineHead`, `kConsoleSpineX`, `terminatesSpine`, the
bus-lighting test. The 3px lit left edge on marked rows is back, since the bus is no longer
there to carry the warning.

**Kept deliberately:** `tool/preview/settings_preview.dart` (the harness mounts the real screen
and is useful for every future round), all the renders in this folder, and this document. The
bus renders (`bus-*.webp`, `spine-*.webp`) stay as the record of what was tried.

### If anyone revisits the wiring

The owner's "inside a computer" rationale is still correct and still worth reading — the idea was
sound, the execution on a real screen was not. Two things a future attempt must beat:

1. **A full-height vertical rail is too heavy at phone scale.** Something shorter, dimmer, or
   segmented per section might work where a continuous trunk did not.
2. **The literal fan was never rendered.** His words were "each line coming from the avatar",
   which may mean N rays from the core rather than one trunk with stubs — that is a genuinely
   different picture and it was never put in front of him. Cost is a `ListView` →
   `SingleChildScrollView` + `Column` swap plus two tests that assert `find.byType(ListView)`.

Do NOT simply re-apply `2b646c1`. It was judged on a device and rejected.
