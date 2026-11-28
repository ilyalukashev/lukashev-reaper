# Lukashev Tools for REAPER

Scripts, JSFX and the **Lukashev Graphite** theme by Ilia Lukashev, installable and updatable through ReaPack.

## Install (once)

1. Install [ReaPack](https://reapack.com) if you don't have it.
2. REAPER: **Extensions → ReaPack → Import repositories…**
3. Paste this link and press OK:
   ```
   https://github.com/ilyalukashev/lukashev-reaper/raw/main/index.xml
   ```
4. **Extensions → ReaPack → Browse packages**, filter by "Lukashev" and install what you need.

Updates arrive with **Extensions → ReaPack → Synchronize packages**.

## What's inside

| Package | Type | Notes |
|---|---|---|
| LKSHV FX Browser | Script | Fast FX browser with plugin images, tags, follow-selected-track suggestions, drag & drop onto tracks/items. Needs **ReaImGui** (ReaTeam Extensions). |
| LKSHV Stem Matrix | Script | Compact dockable button matrix of all `_STM` tracks: click = mute, Cmd+click = solo. Needs **ReaImGui**. |
| LKSHV Mix Notes | Script | Paste client revision notes: they are split into a checklist by song, bullet and timecode; click a timecode to jump, tick notes off, flag them red / yellow / green. Saved in the project. Needs **ReaImGui**. |
| LKSHV Graphite - Toggle mixer input buttons | Script | Shows / hides the rec-mode and input-FX buttons in the mixer (Lukashev Graphite 49+). |
| LKSHV Phosphor Scope | JSFX | Analog CRT goniometer / X-Y / oscilloscope; works as embedded UI in TCP/MCP. |
| Lukashev Graphite | Theme | Minimal high-res theme based on Default 7. After install: Options → Themes. |

Toolbar icons (175+ hi-res icons, 100/150/200 %) are in `Extras/LG toolbar icons.zip`: unzip into
`<REAPER resource path>/Data/toolbar_icons/`.

## Releasing a new version (for me)

- Script / JSFX: edit the file, raise `@version` (Lua) or `version:` (JSFX), add a `changelog`, push.
- Theme: put the new `Lukashev Graphite NN.ReaperThemeZip` in `Themes/`, delete the old one,
  update `@version` and `@provides` in `Themes/Lukashev Graphite.theme`, push.

A GitHub Action rebuilds `index.xml` automatically after every push.
