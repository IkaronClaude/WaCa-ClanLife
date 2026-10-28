# Nexus Mods page - WaCa Clan Life

<!-- Paste-ready text for the Nexus Mods upload form. Replace the TODO links once the pages exist.
     Suggested: upload as EXPERIMENTAL / early access - every feature is off until turned on in its ini. -->

**Name:** WaCa Clan Life (experimental)
**Version:** 0.8.0
**Category:** Gameplay
**Summary (short description, max 350 characters):**
Live in your clan: day and night, seasons and weather, the deputy's daily tasks, sharing tongues in the evening, night
watch, Gatherings, clan patrols - and a story system for writers: new stories, scenes and dialogue as plain text
files. Experimental, every part opt-in.

---

## Description
**WaCa Clan Life** turns the forest into a place where time passes and the clan has a daily life - and gives writers
a way to tell their own stories in it, without programming.

> **Experimental.** Every feature is **off by default** and turned on in its own settings file. Try them one at a
> time and tell us how they play - this is the part of WaCa that grows with your feedback.

### Time and the world
- **Day and night** - the sun crosses the sky, nights are dark, and time stops while the story needs it: no race
  against the clock.
- **Seasons and weather** - newleaf, greenleaf, leaf-fall and leaf-bare, each with its own light. Rain and snow fall
  around your cat, rain with its sound. Prey follows the season - leaf-bare is lean.
- **Rest** - your cat sleeps and the night passes, with a card in the game's own style.
- **Exhaustion** - only pouncing and fighting tire your cat. Walking and exploring are always free.

### The clan's day
- **The deputy assigns your task** each morning, noon and evening: hunt for the fresh-kill pile, patrol the border with
  clanmates, train with your mentor, or free time. Explore as long as you like - a finished task never drags you home.
- **Clan events**: meetings, and in the evening the clan **eats together and shares tongues**.
- **Night**: sleep, or keep **night watch** at the camp's entrance.
- **Gatherings**: the leader picks who goes - your standing and the leader's favour count. Not chosen? Someone has to
  guard the camp...
- **Your standing in the clan** rises with tasks done.
- **The clan's own patrols** head out to the border together.
- **Clanmates say new things** - by time of day, and by story day.

### For writers: your story, as text files
The fandom is full of talented writers - Clan Life is built so you can tell your story without programming:
- Scenes are simple lines: `Card: The full moon rises.`, `Dialogue: <a conversation of the game> @ Leader`,
  `Bond: 2 @ Deputy`, `If: LeaderFavour >= 5` ...
- Hang them on the clan's day: a story day's morning, the evening meal, the Gathering, the night watch.
- Story variables your scenes set and test, kept with each save.
- Your story is **your own mod** - a folder of text files that adds to the clan's life without editing anyone else's
  files, so many story mods can be installed together.

The full guide is in the README on GitHub (TODO: link).

## Requirements
- **UE4SS for Warrior Cats** - https://www.nexusmods.com/warriorcatsclansoftheforest/mods/2
- **WaCa Core** - TODO: Nexus link
- Recommended: **WaCa Hunting** (TODO: Nexus link) - the seasons, weather and your cat's tiredness then change the
  hunting odds.

## Installation
1. Install UE4SS for Warrior Cats and WaCa Core (see their pages).
2. Extract this zip into the game's folder (Steam > right-click the game > Manage > Browse local files):
   `Wrc\Binaries\Win64\ue4ss\Mods\WaCaClanLife` and `Wrc\Content\Paks\~mods\WaCaClanLife_P.*` exist afterwards.
3. Turn on what you'd like to try: `On = 1` in the files in `ue4ss\Mods\WaCaClanLife\config\` - start with
   `daynight.ini`, then `weather.ini`, then `duties.ini` (the clan's day; it needs day and night).

**Updating from the old all-in-one "WaCa ModKit" (0.7 or older):** remove it first (see WaCa Core's page) - including
`Wrc\Content\Paks\~mods\WaCaModKit_P.*`. Its clan-life settings files are this mod's - copy yours over.

**Uninstall:** delete `ue4ss\Mods\WaCaClanLife` and `Content\Paks\~mods\WaCaClanLife_P.*`. Your saves are fine.

Vortex: untested - install manually.

## Compatibility
- Tested with the Steam version of the game, October 2026 build.
- The game's saves are never changed by the mod: its own state (time, weather, story) lives in small files next to
  each save.

## Known issues
- Experimental: turn-ins by talking to the deputy / your mentor and the night watch are new - please report how they
  play.
- The clan's patrols walk out together, but NPCs don't yet *do* their jobs out in the territory.

## Source code & contributing
Open source (Apache 2.0): TODO: https://github.com/IkaronClaude/WaCa-ClanLife

**Contributions are very welcome - especially writing!** Stories, clan events, dialogue for the cats - send them as a
pull request, publish them as your own mod, or post ideas in the comments. Programmers: the scene runner, the clan
loop and the cats-moving-together tools are all open to build on.

## AI disclosure
Much of this mod's code and documentation was written with AI assistance (Claude, by Anthropic), directed,
play-tested and released by the author. The rain and snow are generated by scripts; the rest reuses the game's own
assets - no AI-generated art or audio.

## Permissions
Open source under the Apache License 2.0: use it, modify it, include it in modpacks, upload changed versions - keep
the licence and credit, and say what you changed. Story mods built on it: list it as a requirement.

## Credits
- UE4SS (RE-UE4SS team), CaptainJackalope (UE4SS for Warrior Cats on Nexus).

## Changelog
- 0.8.0 - first release as its own mod (from the all-in-one WaCa ModKit 0.7): the clan loop with turn-ins, clan
  events, Gatherings, patrols, dialogue by story day, content files for story mods.
