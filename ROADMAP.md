# Clan Life - what's in, what comes later

## 0.8 - the first release: the fundamentals
The clan's day works end to end, and everything on it is a hook point for stories:
- time: day / night, seasons, weather, prey by season, rest (time skips), exhaustion as a resource;
- the clan loop: the deputy assigns a task per third (hunt, patrol, training, free time), explore freely, turn it in
  at its end point (the fresh-kill pile, a talk - or the report key - with the deputy or the mentor), the clan's
  events (meetings, eating together and sharing tongues), the night (sleep or night watch), standing in the clan;
- the day at a glance on the HUD (`clan.status`), one switch to turn it all on (`clanlife.ini`);
- Gatherings (the leader's pick, attending / staying behind), the clan's own patrols heading out together;
- writing without code: scenes (cards, the game's conversations and cinematics, fades, bonds, story variables,
  conditions), story days, clan events, dialogue by day (grab bags) - all as content files any mod can add to;
- for programmers: the scene runner's hooks, `follow.lua` (cats moving together), the cross-mod events.

## Later - as their own mods, on top of Clan Life
Each of these builds on the hooks above and is best as a separate mod, so players pick what they want and the base
stays small:
- **Story packs** (content mods): stories with their own day counters and sync points with the main story, standalone
  starts (start as a warrior, a warrior name at creation, start with someone in your party), quest choices, summaries.
  Groundwork in place: content files, story variables, `days.ini`.
- **Cutscenes from text**: scenes staged from the game's own animations, places and camera moves ("clan meeting",
  "apprentice ceremony", "cat walks in", "camera sweep") - a library of reusable building blocks for writers.
- **The cast**: fixed named cats with fixed looks for every role, mods adding new roles (extending the game's
  `ENarrativeRole` - every read path surveyed), "Silverpelt [Warrior]" names in dialogue.
- **Murmurings**: what the clan thinks of its leader and of recent events, changing every day.
- **Apprentice duties**: moss for the medicine cat, old bedding out, water moss for cats too weak to move.
- **NPCs doing their jobs**: patrols actually walking the border, hunters bringing prey back, patrol encounters.
- **The party = who you're out with**: the hunting / patrol cats of the day as the combat party.
- **A day-clock dial** (Cult of the Lamb style) instead of the objective panel - `clan.status` has everything it needs.
- **Fresh kill without hunger**: the pile deposit as a daily duty, not a hunger meter.
- **A story fixer** (low priority): a screen to unstick a story by hand.

Ideas and pull requests for any of these are very welcome - see CONTRIBUTING.md.
