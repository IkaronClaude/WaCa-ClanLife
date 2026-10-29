# WaCa Clan Life

Living in the clan, in **Warrior Cats: Clans of the Forest** - time that passes, seasons and weather, the clan's
daily life - and a story system made for writers: new stories, scenes and dialogue as plain text files.

**Experimental.** Every part is off by default. **Quick start:** `config\clanlife.ini` `On = 1` turns the clan's life
on in one go (day / night, seasons and weather, rest, exhaustion, the clan loop, patrols, Gatherings - its `Parts`
list); each part's settings stay in its own file, and parts can also be turned on one by one there. Tell us how it
plays.

## Time and the world
- **Day / night** (`daynight.ini`): the sun crosses the sky, the light dims at night and the game's own night look
  blends in. A day takes `DayMinutes` real minutes; the time of day is kept with your save. Time stops while the
  story needs it - no race against the clock.
- **Seasons and weather** (`weather.ini`): newleaf, greenleaf, leaf-fall and leaf-bare follow the days, each with its
  own day length, light and tint. Weather comes in spells - overcast, rain and snow darken the light and thicken the
  fog; rain and snow fall around your cat, rain with its sound (the mod's own small content pak). Hunting and fishing
  get easier or harder with them (with WaCa Hunting).
- **Prey follows the season**: in leaf-bare only part of the mice, rabbits and birds are about, hardly any squirrels.
- **Rest** (`timeskip.ini`): when the night passes (sleeping, or a rest key if you set one - `RestKey`, none by
  default) a card in the game's style says so, and the season and weather move on.
- **Exhaustion** (`exhaustion.ini`): a resource, not a meter - only pounces and fights tire your cat (more late at
  night); walking and exploring cost nothing. Tired, your cat moves slower and hunts and fights worse. Sleep resets
  it.

## The clan's day
- **The clan loop** (`duties.ini`, `clanevents.ini`): morning and afternoon are duties - each time the deputy gives
  your cat a task: hunt (the catch goes onto the fresh-kill pile), patrol the border (clanmates walk with you, report
  to the deputy), training (a sparring fight - talk to your mentor afterwards) or free time. Do it and explore as long
  as you like - a done task never sends you home - then turn it in at its end point. Then the clan's event, if any (a
  clan meeting, called in the books' words from your clan's meeting place - `duties.ini [MeetingPlace]`; the Gathering).
  The **evening** is the clan together in camp: your clanmates join you, eat and
  **share tongues** - a short staged scene. At **night**, go to your den - your own or your rank's (apprentices',
  warriors' ...) - and your cat lies down and sleeps until morning; or the **night watch** at the camp's entrance. Tasks
  done raise your standing in the clan; missed ones lower it. The clan's day waits while a conversation or cutscene is
  up (a new game's intro), and its cards come one at a time. Which task comes is drawn from `duties.ini [Tasks]`
  chances - a task you just had is less likely next (`RepeatFactor`) - and a story day sets its own (`days.ini`
  `MorningDuties = Hunt:3, Patrol:1`) or fixes one (`MorningDuty = Hunt`).
- **The day at a glance**: while the loop runs, a panel like the game's own quest objective (left side of the HUD)
  shows the day and third, your task, where to go and how far along you are ("Prey 1/3"), then how to turn it in
  (`clanlife.ini [Hud]`).
- **Deputies and leaders lead the clan's day** (from `duties.ini MaxRank` on): each morning and afternoon the clan's
  meeting place is marked - go there and give out the tasks (the report key); the evening and the night follow as
  usual. Your rank is the game's own record: its rank quests in your save (WaCa Core's `player.rank`).
- **Turn-ins never get stuck**: reporting to the deputy (or your mentor) is a conversation with them - or the report
  key (`F`, `duties.ini ReportKey`) next to them. The deputy answers in his own words (`duties.ini [Talk]`: your
  report, or a reminder of your task) instead of the game's "nothing new for you".
- **Each clan's camp** is found from the game's own camp zone (`R-05`, `T-10` ...) - the loop knows when you're home.
- **Gatherings** (`gatherings.ini`): every few days the leader names the cats who go - your cat by chance, more likely
  with good standing and the leader's favour, never while banned. Going and staying behind are scenes the story
  builds on (rogues attack the camp while half the clan is away...).
- **The camp's walking cats are its named cats** (`walkers.ini`): the game walks a few nameless cats round camp; each
  third of the day they wear the camp's named cats in turn (look and name), that cat's placed self hidden meanwhile.
  Never the key cats (story characters, leader, deputy, medicine cat, the clan's services, queens, kits). Story lever:
  `Walk:<Name>` = 1 walks next, -1 never.
- **The clan's own patrols** (`patrols.ini`): clanmates gather in camp and head out to the border together.
- **New things to say** (`lines.ini`): lines per cat role and time of day, and **dialogue by story day** - a queen says
  one of three lines each day of a week, a new one each day, no repeats until all were said.
- **Clan activities** (`activities.ini`): clanmates sit, nap, sniff around or play-fight in camp; press G next to a story
  cat to spend time together and grow your bond.

## Writing stories (no programming)
Every config here is this mod's file **plus** `<YourMod>\content\<name>.ini` of every enabled mod - so a story mod is a
folder with `enabled.txt` and a `content` folder, and never edits anyone else's files:
- a section only you have is added (two mods' clan events both exist);
- a section several mods share gets the numbered keys of each **appended** (`Step1`, `Line1`, `Morning1` ...) - two
  mods can add beats to the same story day or lines to the same dialogue;
- a plain key is set by the later mod (logged); `Off = 1` in your copy of a section turns another mod's off.

**Scenes** are lines of steps, run one after another, each waiting for its end:
`Card: <text>`, `Gather: <n> @ Here|Pile` (the camp's nearest walking clanmates, in an arc facing you), `Groups:
Tongues|Prey` (the clan in small groups by their ties - `config/relations.ini` mates / pairs / friends / tensions; the
leader always sits with its mate and deputy unless a story event sets LeaderAway, apprentices together - who with whom by
chance, the story's levers `Pair: A & B` / `Part: A & B` override it; a group of 4 round prey now and then (BigPrey /
NoBigPrey force it); the camp's cats keep their names from load to load - the
game rolls new ones, Clan Life gives each cat back its first name per save), `Pose: <Sit|Lie|Sleep|Eat|
Sniff|Meow|Play|Groom> @ Gathered|Player|All|<who>` (the game's animations), `Release` (they go back),
`Dialogue: <id> @ <who>` (the game's own conversations and cinematics - ids in
`config\events-dialogues.txt`, written the first time you're in the world; who = Deputy, Leader, MedicineCat, Teacher,
Nearest or a story role), `Fade: <s>` / `FadeIn: <s>`, `Wait: <s>`, `Bond: <points> @ <who>`, `Emit: <event>`,
`Hook: <name>`, and story variables kept with the save: `Set: LeaderFavour = 2`, `Add: GatheringBan 1`,
`If: LeaderFavour >= 5, Rank >= 2` (the rest of the scene only then).

They go in at the loop's hook points:
- `duties.ini` `[Third.<Third>]` `Start1...` / `Event1...`, `[Assign.<Task>]` (how the deputy gives it), `[NightWatch]`;
- `clanevents.ini` `[Event.<Name>]` - `When` / `Chance` / `Day` / `Every` / `Once` / `Order` / `Require` + steps;
- `gatherings.ini` `[Announce]` / `[Chosen]` / `[NotChosen]` / `[Attend]` / `[StayBehind]`;
- `days.ini` per story day: `<Third>Start`, `<Third>` beats, `<Third>Duty`, `NightDuty = Hunt` for a night hunt,
  `Gathering = Yes`, `GatheringPick = Chosen`, and when the story moves on (`Advance = Always / Duties / Rank:Warrior` -
  until then the day repeats);
- `lines.ini` `[Dialogue.<Name>]` `Who` / `Days` / `Require` / `Case = Talk | Patrol` / `Line1...` (a grab bag: a new
  line each day, no repeats until all came).

Built-in variables: `Day`, `Rank`, `Standing`, `Gathering.Chosen`, `Gathering.Count`. The order of a third's end:
story beats (100), clan events (200 - `Order =`), `<Third>After` beats (300), the third's own event (350), the
`ClanThirdEnd` hook (400) - so a story scene can come before or after the clan eats together.

## For modders (Lua)
Inside this mod (`Scripts\`): `events.lua` (the scene runner, story variables, roles), `duties.lua` (the loop),
`follow.lua` (cats moving together: `Follow.Group`, `Follow.Travel`, holding back while the leader sneaks). The day at a glance is the sticky topic `clan.status` (`WaCa.Subscribe("clan.status", fn)`: day,
third, task, where, activity, goal, got / need, done, text) - draw it your own way (a day-clock dial ...) and set
`clanlife.ini [Hud] On = 0`. From any
other mod, use the events - WaCa Core carries them between mods: `DayStarted`, `HourChanged`, `SeasonChanged`,
`ClanThird`, `TaskAssigned`, `TaskTurnedIn`, `DutiesJudged`, `GatheringHeld`, `StoryVar` ... (all in WaCa Core's
[EVENTS.md](https://github.com/IkaronClaude/WaCa-Core/blob/main/docs/EVENTS.md)), and a scene's `Emit: <event>` step
calls your mod's code from a story file.

## Install
Needs **UE4SS for Warrior Cats** ([Nexus](https://www.nexusmods.com/warriorcatsclansoftheforest/mods/2)) and
**[WaCa Core](https://github.com/IkaronClaude/WaCa-Core)**. Extract the zip into the game's folder so that
`Wrc\Binaries\Win64\ue4ss\Mods\WaCaClanLife` and `Wrc\Content\Paks\~mods\WaCaClanLife_P.*` (rain and snow) exist - it
turns itself on. Uninstall: delete those. Your saves are fine; the mod's own state (time, weather, story) is in small
files next to them.

Coming from the all-in-one WaCa ModKit 0.7? Its `activities`, `clanevents`, `daynight`, `days`, `duties`, `events`,
`exhaustion`, `gatherings`, `lines`, `patrols`, `timeskip` and `weather.ini` are this mod's - copy yours over, and
delete the old `WaCaModKit_P.*` pak.

## Building the content pak
`tools\build_content.ps1` builds `dist\content\WaCaClanLife_P.pak/.utoc/.ucas` (the rain / snow look and the rain sound)
with Unreal Engine 5.7.4, headless: the sources are generated (`content\scripts\make_sources.py` - no third-party
files), the assets made in the content project `content\Wrc` (named like the game so the paths match) and cooked into
their own IoStore container. `tools\package.ps1` adds it to the zip.

## Contributing
Stories, clan events, dialogue lines, bug reports and pull requests are very welcome - see
[CONTRIBUTING.md](CONTRIBUTING.md). Writers: you don't need to code. Send your content files as a pull request, or
publish them as your own mod.

## AI disclosure
Much of this code and documentation was written with AI assistance (Claude, by Anthropic), directed, play-tested and
released by the author. The rain and snow are generated by scripts (no AI-generated art or audio); the rest reuses
the game's own assets.

## License
Apache License 2.0 (see LICENSE).
