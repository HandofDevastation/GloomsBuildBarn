# Gloom's Build Barn

## v2026.09.02

- Every spec's number at a glance: the line under the boss title now lists your
  class's other specs beside the top one, ranked, so finding out where a spec
  stands no longer costs a click each.
- Healers see healing, and only healing. The headline used to name the class's
  best damage spec whatever you were playing, so a healer opened the panel to a
  damage figure that had nothing to do with them. It now follows the spec you
  are in, and healing and damage numbers are never mixed on one line.
- Tanks are ranked on damage, like everyone else who is not a healer. Nothing in
  the harvested data can rank one tank build against another.
- A healing spec on a boss with no healing builds yet says so, instead of
  showing nothing.
- Fixed: the Undock button in the top right came up blank the first time the
  panel was opened after starting the game, and appeared only after closing and
  reopening it.
- Fixed: "Mean DPS" in the build details was actually the median. The label now
  says median.
- The talent glow pulses twice as fast while you hover a "Changes If Applied"
  block, which makes the affected talents easier to pick out of the tree.

## v2026.09.01.2

- Fixed (properly, this time): the "Changes If Applied" list still came up
  part-empty on the first open after starting the game — the ADDED line
  appeared while REMOVED and CHANGED stayed blank. All three lines are now
  written again on the following frame, which is what makes them appear.

## v2026.09.01.1

- Fixed: the "Changes If Applied" list could come up empty the first time the
  panel was opened after starting the game, showing the colored bars with no
  text in them. Switching boss or reopening the panel brought it back. The
  text is now drawn into a visible panel rather than a hidden one, so it
  appears on the first open.

## v2026.09.01

- Release notes are now curated rather than generated from commit history.

Build data continues to refresh automatically each week from the guild's logs.
