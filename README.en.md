# Reinforcement Radar

Displays the enemy reinforcement cooldown and its countdown during a Helldivers 2
mission.

Read-only. It does not modify game memory and does not affect other players.

**[中文说明](README.md)**

---

## Contents

- [Requirements](#requirements)
- [Installing](#installing)
- [What it looks like](#what-it-looks-like)
- [Display rules](#display-rules)
- [Repositioning and sizing](#repositioning-and-sizing)
- [Log](#log)
- [Documentation](#documentation)
- [Maintenance](#maintenance)

## Requirements

- **Bingus Shared Loader** v15 or newer (API 1)
- Supported Steam build **25480438** / EXE 1.8.46015.0

## Installing

1. Close Helldivers 2
2. Import `Reinforcement-Radar-*.zip` with Arsenal or HD2MM
3. Enable it, then Purge / Deploy
4. Keep Bingus Shared Loader enabled as well — one without the other does nothing

## What it looks like

### Ready to call

With the cooldown clear, a green `READY` appears.

![Ready](img/ready.jpg)

### Cooling down, more than two minutes left

A green countdown.

![Green countdown](img/green.jpg)

### Cooling down, one to two minutes left

Turns orange.

![Orange countdown](img/orange.jpg)

### Cooling down, under a minute left

Turns red.

![Red countdown](img/red.jpg)

### Reinforcement under way

While reinforcements are arriving the game freezes the shared cooldown, so the
panel hides entirely — showing a countdown at that moment would be misleading.

![Hidden while a reinforcement is under way](img/standby.jpg)

## Display rules

The panel sits on the right-hand side of the screen, a little above centre, with
no backdrop: the label is drawn straight onto the world.

| State | Shows | Colour |
| --- | --- | --- |
| Ready to call | `READY` | green |
| Cooling down, over 2 minutes left | `MM:SS` | green |
| Cooling down, 1–2 minutes left | `MM:SS` | orange |
| Cooling down, under 1 minute left | `MM:SS` | red |
| Reinforcement under way | nothing | — |
| Not in a mission | nothing | — |

## Repositioning and sizing

Every parameter lives in the `LAYOUT` table at the top of `src/hud.lua`; changing
one number is enough. On startup the log records the actual layout so it can be
checked against your resolution:

```
# HUD layout: screen=2560x1334 scale=1.235 panel=212x49 at 2317,724
```

## Log

`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\ReinforcementRadar.log`

## Documentation

- [Technical notes](docs/TECHNICAL.md) — architecture, coordinate system, read-only guarantees
- [Maintenance guide](docs/MAINTENANCE.md) — re-adapting after a game update, reading the log

*(Both are currently in Chinese.)*

## Maintenance

The author may not be able to maintain this project long-term due to academic
commitments, and would welcome community contributions.

This project was developed with the participation of DeepSeek V4.1 Flash.
