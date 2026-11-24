# Oath Tracker (WoW Forever - Interface 16001)

A lightweight, secret-value-safe **out-of-combat, single-target** Paladin Oath tracker designed specifically for **WoW Forever**.

## Core Features
- **Out-of-Combat Only:** Automatically hides and pauses scanning during combat (`PLAYER_REGEN_DISABLED`) and resumes immediately after combat ends (`PLAYER_REGEN_ENABLED`).
- **Single-Target Focus:** Tracks only the one friendly target you cast your Oath on (supporting WoW Forever `First Last` character names). Casting an Oath on a new target replaces the previous one.
- **20-Second Pre-Expiration Reapply Icon:** When **20 seconds or less** remain on your Oath—or if the Oath is missing, clicked off, or the target died—a compact **38x38 clickable Oath of Light icon** appears in the exact center of your screen (`CENTER`), even if the main status window is hidden. Clicking it immediately re-casts your Oath onto the tracked target.
- **Hideable Main GUI:** Click the **`X`** button in the top-right corner of the tracker window (or use `/oath hide`) to hide the main status box while keeping background tracking and the center reapply icon active. Type `/oath show` to bring it back.
- **Audible & Visual Alerts:** Verifies sound playback across WoW sound kits and classic `.ogg`/`.wav` file paths (`Master` / `SFX` / `Dialog`) and pulses the frame border when your Oath drops below 20 seconds or goes missing.
- **One-Click Reset:** Includes a **Reset** button directly on the tracker header to clear the tracked target at any time.

## Installation
1. Extract the `OathTracker` folder into your `Interface/AddOns/` directory.
2. Ensure the folder path is `Interface/AddOns/OathTracker/OathTracker.toc`, `OathTracker.lua`, and `README.md`.
3. Restart WoW or type `/reload` in-game.

## UI Controls & Slash Commands
- **Header Buttons:**
  - `Reset` — Clears the currently tracked target.
  - `S` — Toggles (and immediately tests) the audible alert.
  - `V` — Toggles the pulsing visual highlight on/off.
  - `X` — Hides the main GUI window (use `/oath show` to re-enable).
- **Slash Commands (`/oath`):**
  - `/oath show` — Re-enable and show the main tracker GUI.
  - `/oath hide` — Hide the main tracker GUI.
  - `/oath reset` — Clear the tracked target.
  - `/oath sound` — Toggle and test the alert sound.
  - `/oath visual` — Toggle pulse visual alert on/off.
  - `/oath scan` — Manually check the tracked target out of combat.
  - `/oath lock` — Lock or unlock dragging of the tracker frame.
