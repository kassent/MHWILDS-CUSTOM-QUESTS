# Quartet · Custom Event Quests

**English** | [简体中文](README.zh-CN.md)

This repository contains **four custom event quests for Monster Hunter Wilds**, loaded through **REFramework + PermanentEventQuest**.

All four quests take place in **ST403, the Zoh Shia arena**. The collection includes a four-monster boss rush, a standalone Arch-tempered Arkveld hunt, a recreation of the Zero-type Omega encounter, and a harder boss rush with additional monster adjustments. This repository provides quest configurations and Lua scripts; REFramework and the plugin itself are not included.

## Quest List

All four quests require **HR 100** and support up to **4 players**.

| Quest ID | Name | Stars | Overview | Time Limit | Faint Limit |
|---|---|---|---|---|---|
| 10096 | Quartet of the End | ★10 | Zoh Shia → Tempered Gore Magala → Arch-tempered Arkveld → Zero-type Omega; standard boss rush | 60 minutes | 10 |
| 10097 | One Blade Holds the Pass | ★10 | Standalone Arch-tempered Arkveld, with adjusted unleash thresholds and energy crystals on ordinary ground | 50 minutes | 3 |
| 10098 | Planetary Cataclysm | ★9 | Standalone Zero-type Omega, with scene plants and adapted summon and ultimate-attack sequences | 50 minutes | 3 |
| 10099 | Quartet of Finality | ★10 | Harder boss rush with adjustments to motion speed, fire areas, rampage, and Arkveld mechanics | 60 minutes | 10 |

Quest names match the English display names in the quest files. “Standard” distinguishes 10096 from this repository's harder variant; it does not mean unmodified base-game difficulty.

## Gameplay and Script Differences

### 10096 · Quartet of the End

- Fight four main targets in sequence; defeating one starts the next encounter.
- Includes Nerscylla, scene plants, dialogue resources, and speaking NPCs for the Omega encounter.
- Adapts Omega's ultimate-attack center, charge position, explosion orientation and scale, summon positions, and circling animation to ST403.
- Does not include 10099's motion-speed increases, fire-area lifetime changes, rampage lock, or Arkveld health-threshold adjustments.

### 10097 · One Blade Holds the Pass

- Sets Arkveld's unleash eligibility and accelerated automatic elemental-charge health thresholds to **100%**.
- The original checks use strict “less than” comparisons: full health does not qualify, but taking damage does. The original AI still schedules the transformation; the script does not force the unleashed state at quest start.
- Attacks that normally create energy crystals can also request crystals on ordinary ground, without requiring the original encounter's special terrain sensors.
- The older implementation that directly writes `UNLEASH` at startup remains commented out and is not active.

### 10098 · Planetary Cataclysm

- Provides a standalone Zero-type Omega encounter in ST403.
- Includes Nerscylla summons, scene plants, dialogue, and speaking NPCs, with adapted ultimate-attack positions and circling animation.
- Retains this quest's existing mechanics without adding 10099's resource-parameter enhancements.

### 10099 · Quartet of Finality

Adds the following changes to the four-monster boss rush:

- **Motion speed:** 1.2× for Zoh Shia and Gore Magala; 1.3× for Omega.
- **Fire-area lifetime:** removes the natural lifetime countdown for Mustard Bomb fire areas. Original removal logic, such as cleanup during a subsequent cast, still applies.
- **Rampage lock:** breaking leg wounds no longer reduces Omega's rampage gauge to end that state. Other original exit conditions remain in effect.
- **Two Nerscylla:** configures two Nerscylla for the encounter's summon mechanic.
- **Arkveld enhancements:** uses the same 100% health thresholds and ordinary-ground energy-crystal logic as 10097.

## Installation and Usage

1. Install REFramework and a PermanentEventQuest build that supports the quest scripting APIs used here: `quest.on_load`, `quest.on_unload`, `quest.on_flow_changed`, and `quest.require_enemies`.
2. Merge this repository's entire `quests` folder into the game's `reframework/plugins/PermanentEventQuest/` directory. With MO2, preserve the same directory layout inside the mod and enable it.
3. Deploy each quest's `.raw.json`, `.ext.json`, and `.lua` files, together with `quests/scripts/quest_lib.lua`. Quest Lua scripts are managed by the plugin; do not place them in `autorun`.
4. In REFramework, open **Script Generated UI → Permanent Event Quest**, click **reload**, and select a quest at the event quest counter.

Updating files does not change a quest instance already in progress. After editing scripts, reload and enter the quest again. Resolve any quest-ID conflicts if another installed quest already uses **10096–10099**.

## Repository Structure

```text
PermanentEventQuest/
├── README.md
├── README.zh-CN.md
└── quests/
    ├── 10096.raw.json / 10096.ext.json / 10096.lua
    ├── 10097.raw.json / 10097.ext.json / 10097.lua
    ├── 10098.raw.json / 10098.ext.json / 10098.lua
    ├── 10099.raw.json / 10099.ext.json / 10099.lua
    └── scripts/
        └── quest_lib.lua
```

- **`.raw.json`:** quest targets, map, monster configuration, progression, and localized text.
- **`.ext.json`:** quest identifiers, rewards, and other extension settings.
- **`.lua`:** quest-specific runtime behavior.
- **`quest_lib.lua`:** shared enemy-injection, dialogue, and NPC utilities, plus enemy-ID-filtered package load/unload events.

Quest hooks are removed automatically when the quest script unloads. Resource-parameter changes separately save their original values and restore them through unload events. At quest end, the shared library also dispatches cleanup for subscribed packages that remain loaded. For multiplayer testing, use matching quest files, shared scripts, and plugin builds across all participants.
