# Gloom's Build Barn

A World of Warcraft addon that serves the **best-performing** and **most-popular**
talent build for every spec — per raid boss + difficulty, and per Mythic+ dungeon —
and applies them in-game. Builds are harvested weekly from the top Warcraft Logs
parses (US + EU) and baked into the addon, so it works with no internet access.

> Not on CurseForge or Wago by design — installed by repo URL only.

## Install (WoWUp)

1. In WoWUp, choose **Install from URL / Import** and paste:
   `https://github.com/HandofDevastation/GloomsBuildBarn`
2. WoWUp tracks new releases — updates land like any other addon.

## Use

- `/gbb` (or `/glooms`) — opens the window for your class.
- Pick **Raid** (Heroic / Mythic toggle) or **Mythic+**, then an encounter.
- The detail panel ranks your class's specs by performance and flags the **top
  DPS spec** for that encounter. Hit **Best** or **Popular** to apply a build in
  one click — it switches spec first if needed, into a managed
  "Gloom's Build Barn" talent loadout.
- `/gbb status` — text smoke test: data date + builds for your current spec.

## How it stays fresh

- **Monday morning** — the backend re-harvests the top builds from Warcraft Logs.
- **Tuesday morning** — `BuildData.lua` is regenerated and a new release is cut;
  your WoWUp picks it up.

## Layout

- `GloomsBuildBarn.toc` — addon manifest.
- `Core.lua` — data loading, spec detection, apply, slash command.
- `BuildData.lua` — **generated**; the baked build table (do not hand-edit).
- `.github/workflows/release.yml` — packages + publishes a GitHub Release on a version tag.
