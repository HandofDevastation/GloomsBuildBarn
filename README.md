# Gloom's Build Barn

A World of Warcraft addon that serves the **best-performing** and **most-popular**
talent build for every spec — per raid boss + difficulty, and per Mythic+ dungeon —
and applies them in-game. Builds are harvested weekly from the top Warcraft Logs
parses (US + EU) and baked into the addon, so it works with no internet access.

## Install

**Install it from CurseForge**, through WoWUp's addon search or the CurseForge
app. That is the source that can also UPDATE it.

> ⚠️ Do not install from this repo's URL. WoWUp can install a GitHub-sourced
> addon but cannot update one — its update path fetches the release asset
> without the right header and saves GitHub's JSON metadata as the .zip. Anyone
> who installed that way should uninstall and reinstall from CurseForge, or they
> will silently stop receiving the weekly build refresh.

Releases are still cut on GitHub as well; CurseForge is simply the one players
should track.

## Use

- Click the minimap button, or `/gbb` (or `/glooms`), to open the window for
  your class.
- Pick **Raid** (Heroic / Mythic toggle) or **Mythic+**, then an encounter.
- The detail panel ranks your class's specs by performance and flags the **top
  DPS spec** for that encounter. Hit **Best** or **Popular** to apply a build in
  one click — it switches spec first if needed, into a managed
  "Gloom's Build Barn" talent loadout, so your own loadouts are left alone.
- `/gbb status` — text smoke test: data date + builds for your current spec.

## How it stays fresh

- **Monday morning** — the backend re-harvests the top builds from Warcraft Logs.
- **Tuesday morning** — `BuildData.lua` is regenerated and a new release is cut
  to GitHub and CurseForge; your addon manager picks it up.

## Layout

- `GloomsBuildBarn.toc` — addon manifest.
- `Core.lua` — data loading, spec detection, apply, slash command.
- `BuildData.lua` — **generated**; the baked build table (do not hand-edit).
- `CHANGELOG.md` — **user-facing**, curated by hand. `manual-changelog` in
  `.pkgmeta` points the packager at it so release notes are not built from
  commit messages.
- `.github/workflows/release.yml` — packages + publishes to GitHub and
  CurseForge on a version tag.
- `.github/workflows/weekly-data.yml` — the Tuesday refresh; self-packages, so
  most releases come from here rather than a hand-pushed tag.
