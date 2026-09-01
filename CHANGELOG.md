# Gloom's Build Barn

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
