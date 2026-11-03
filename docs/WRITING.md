# Writing stories for WaCa - a guide for writers

You don't need to program to add to the clan's life. A **story pack** is a folder of plain text files. WaCa Clan
Life reads them, along with every other pack, and plays what they describe: clan events, story days, cutscenes,
dialogue, Gathering scenes and roles of your own.

This guide covers everything a pack can say. The example pack in `examples/WaCaStoryPackExample` uses all of it, so
copy it and change things.

## 1. A pack is a folder

```
Mods/
  MyStoryPack/
    enabled.txt          (empty - it switches the pack on)
    content/
      clanevents.ini     events that happen in the clan
      days.ini           the story as days
      events.ini         your own roles ([Cast])
      cutscenes.ini      cutscenes (needs WaCa Cutscenes)
      gatherings.ini     what happens at / around a Gathering
      lines.ini          dialogue: murmurs, lines by day
      start.ini          where a new cat's story begins (day, level, a warrior name)
      roles.ini          your own specialisations for the player's cat (needs WaCa Hunting)
      shapes.ini         how a cutscene's cats stand (needs WaCa Cutscenes)
      places.ini         named spots a cutscene can play at (needs WaCa Cutscenes)
      roster.ini         custom cats: a cat renamed and re-dressed (needs WaCa Looks)
      duties.ini         duties of your own in the clan's day (the deputy gives them like hunting or patrols)
```

Use only the files you need. A pack never edits anyone else's files; everything adds on (section 9).

## 2. Clan events (`clanevents.ini`)

An event is a short scene that happens at a time of day, by chance or when something happens:

```ini
[Event.LonerVisit]
When = Evening          ; Morning / Noon / Evening / Night, or Event:<name> (see below)
Chance = 25             ; % on a day it could happen
Once = 1                ; only ever once in a save
Day = 3                 ; not before story day 3 (optional)
Require = SawLoner = 0  ; conditions (section 5)
Step1 = Cutscene: LonerVisit
Step2 = Set: SawLoner = 1
```

`When = Event:<name>` reacts to something that happens in the game or in another mod:
- `HuntCaught` - your cat caught prey;
- `FellThroughIce` - your cat fell through thin ice;
- `GatheringHeld`, `KitsBorn`, `MateChosen`, and any other event a mod sends.

A mod can run an event by name from Lua: `WaCa.Emit("ClanEvent", "<name>")`. A story can force or block one
with the variable `Event:<Name>` (`Set: Event:ClanMeeting = 1` = it happens, `-1` = it doesn't). There are also `Every = N`
(every N days from `Day`) and `OnlyDay = N`.

## 3. Steps - what a scene does

A scene is `Step1`, `Step2` ... in order, as many as you need. Each is `Kind: what [@ who]`:

| Step | What it does |
|---|---|
| `Card: <text>` | a line of text in the middle of the screen (`{DAY}` = the day) |
| `Cutscene: <Name>` | plays a cutscene (section 6); the scene waits for it |
| `Lead: <place> @ <who>` | a cat walks your cat somewhere - it comes to you, waits if you fall behind; places: `Den:<the game's den name>` (`Den:Apprentice's den`), `Zone:<code>`, `Pile`, a cat's name |
| `Dialogue: <id> @ <who>` | one of the game's own conversations (ids in `events-dialogues.txt`) |
| `Bond: <points> @ <who>` | your bond with a cat grows (or shrinks) |
| `Party: <story cats>` | who fights beside your cat from now on (`Party: Toadfrost, E:RiverClanDeputy`; `Party: none` = the game's own) - kept with the save |
| `Set: <var> = <value>` | sets a story variable (section 5) - `Set: X = Day + 2` works too |
| `Add: <var> <n>` | adds to one (`Add: LeaderFavour 2`) |
| `If: <conditions>` | the rest of the scene only if they hold - or, with `Else` / `EndIf` steps after it, the steps up to `Else` (or `EndIf`) only; `Else` ... `EndIf` when they don't (not nested) |
| `Skip: <days or a skip's name>` | time passes on purpose: the world fades, a card says what changed; a skip of your own is `[Skip.<Name>]` in your pack's `timeskip.ini` - `Days`, `Pile` (the fresh-kill pile's value after it), `Card`. The day's hunt / patrol is set aside (not missed); a skip runs no duties - the story check warns about any you put on one |
| `Newcomer: <clanmate>` | a new cat joins the clan, taking after that clanmate (8c) |
| `Activity: <name> @ <who>` | that cat does one of `activities.ini`'s activities now (Sit, Nap, Sniff ...) - your cat can join it with the Join key |
| `Choice: <variable> = <question>; <answer 1>; <answer 2> ...` | the player picks an answer on the game's own answer menu (the quest dialogue's: up to four answers - the mouse, Up / Down + Enter, or the number keys); `<question>` as `Name: ...` puts Name on the speaker's plate; the variable gets the answer's number - then `If: <variable> = 1` ... |
| `Wait: <s>`, `Fade: <s>`, `FadeIn: <s>` | a pause; the screen fading out / in |
| `Pose: <pose> @ <who>` | a cat plays a pose (Sit, Growl, Hiss, Sniff ...) |
| `Emit: <event>` | sends an event other mods (or your own `When = Event:`) hear; `Emit: <event> = <value>` sends a value with it (`Emit: SetSpecialisation = Herbalist` - WaCa Hunting gives your cat that role for this save) |
| `Hook: <name>` | a mod's own Lua code runs here, and the scene waits for it (the mod announces the hook - WaCa Core's API.md "A part in a story"); a hook no mod handles is skipped |
| `Gather: <n> [@ Here\|Pile]` | n clanmates come and stand facing your cat - an audience |
| `Groups: Tongues\|Prey` | the clan sits in small groups by their ties (sharing tongues in 2s and 3s, prey in 2s-4s); your cat joins one |
| `Pair: A & B` / `Part: A & B` | from now on those two sit together / never together (kept with the save; `Set: Pair:A & B = 0` lifts it). A paired cat across camp comes to the groups too |
| `Release` | the gathered cats go back to their places |
| `Freeze: On` / `Freeze: Off` | the clan's clock stands still (a story point - no time pressure) / runs again |

## 4. Who - naming cats

- **Parts of your clan:** `Leader`, `Deputy`, `MedicineCat`, `Nearest` (the nearest clanmate), `Player`.
- **A cat by its name:** `Lionstar` - any cat in the world, a newcomer or a kit of yours too (the nearest of that name).
- **A story role:** `E:RiverClanDeputy`.
- **Your own role:** `S:<role>`, given a cat in `events.ini`:

```ini
[Cast]
S:herbalist = Mossfeather      ; a cat of the clan, by name
S:loner = Rogue:Quill          ; a cat who isn't in the world - brought in for each scene that asks for it
S:envoy = Clan:ShadowClan      ; another Clan's cat (Clan:<Clan>.<Part> for its leader / deputy ...)
```

Your scenes then say `@ S:herbalist`, and your cutscenes say `B = S:loner`. A role played by another Clan's cat
(`Clan:ShadowClan`) is a cat made up from the save's cats the first time; it is kept with the save, so your envoy is the
same cat in every scene after.

## 5. Conditions and story variables

`Require = ...` and `If: ...` take conditions, comma-separated, all of which must hold:

```
Day >= 3, Pile < 50, Season = Leaf-bare, LostKit = 1, Day <= LostKit.Until
```

Operators: `=  !=  <  <=  >  >=`. The right side can be a number, a word (`Season = Greenleaf`) or another variable
(`Day <= LostKit.Until`).

**Built in:** `Day`, `Season`, `Weather`, `Pile` (the fresh-kill pile, 0-100), `Standing` (your standing in the clan),
`Rank`, `Gathering.Today`; the Gathering sets `Gathering.Chosen` and `Gathering.Count`.

**Your own:** any name you `Set` or `Add` - they are kept with the save. A variable that was never set reads 0.

## 6. Cutscenes (`cutscenes.ini`, needs WaCa Cutscenes)

```ini
[Cutscene.LonerVisit]
Place = Here                ; Here (in front of your cat), Pile, Zone:<code>, a place of yours (places.ini) ...
Shape = Facing              ; Facing (A vs B), Circle, Meeting, Pair, Ceremony ...
A = Leader, Player
B = S:loner
Beat1 = 0 WalkIn: B
Beat2 = 0 Camera: Wide
Beat3 = 4 Camera: Two = A1 & B1 ~2
Beat4 = 5 Say: B1 = I'm only passing through.
Beat5 = 11 Camera: Portrait = A1
Beat6 = 12 Say: A1 = You may shelter by our border tonight.
Beat7 = 17 Pose: B1 = Sit
Beat8 = 23 End
```

Every beat is `<seconds from the start> <Action>`. The full list of actions, cameras and shapes is in WaCa Cutscenes'
README. Your pack can add its own spots and its own ways for the cats to stand:

```ini
; places.ini - stand there in game and press WaCa Cutscenes' WhereKey for the line
[Place.ReedBank]
At = -45300 4200 637
Yaw = 60

; shapes.ini - marks in cm from the place's middle (forward, side), one capital letter per group
[Shape.Vigil]
V1 = 0 -150
V2 = 0 0
V3 = 0 150
W1 = -220 0
FaceV = Forward
FaceW = V
```

WaCa Cutscenes checks every cutscene when it loads: a place, shape, action or camera shot that doesn't exist - or a
part spelt a letter off (`Leadr`: "did you mean Leader?") - is listed in UE4SS.log (`cutscene check:`).

Cast slots take the same names as section 4. They also take `Rogue`, `Rogue:<Name>` and `Clan:<Clan>`: cats brought in
for the scene and gone after it. A named rogue (`Rogue:Quill`) looks the same in every scene it is in.
Give it a look of your own in your `cutscenes.ini`:

```ini
[Rogue.Quill]
From = Toadfrost      ; start from this cat's look
FurValue = 1          ; then any of the game's own look fields
```

## 7. Story days (`days.ini`)

The story as days. Each `[Day.N]` sets that story day's beats per third (`Morning`, `Noon`, `Evening`, `Night`, as many
numbered as you need: `Morning2`, `Morning3` ...). It can also set the day's duties, season and weather.

`Advance` says when the story moves on. Until it holds, the story day repeats. `Like = M` copies a day you already
wrote. The full key list is at the top of Clan Life's `config/days.ini`.

A pack can add to a day Clan Life (or another pack) already writes: numbered beats (`EveningAfter1`) go after its own,
`Events = HerbCouncil` makes your clan event happen that day. Story days are off unless the player turns them on
(Clan Life's `config/days.ini` `[Days] On = 1`) - the story check warns when your pack writes days while they're off.
When a day begins, the log lists everything it holds (`days: story day 2 holds: events HerbCouncil; Morning; ...
EveningAfter1`). A mod can move the story with `WaCa.Emit("SetStoryDay", n)`.

`Advance = If: <conditions>` moves on once story variables hold (`If: ShelterQuill > 0` - the player has answered).

### 7b. A story of your own (`story.ini`)

A pack's `content/story.ini` is a story of its own, beside the main one: `[Story]` with `Name` and `Priority` (lower
plays first), then its own `[Day.N]` - the same keys as `days.ini`. It has **its own day counter**: every calendar day
each story is judged on its own `Advance`, and a story that isn't ready repeats its day - the stories never read each
other's day numbers, so a pack can be longer or shorter than the main story. Its beats play after the main story's in
each third; the day's duties, season and weather stay the main story's. Where every story is, is kept with the save.

`Sync = <Name>` on a day makes it a meeting point: that story waits on that day until every story that declares the
same `Sync` is on its own day for it and ready, then they all go on together. There is no limit to the wait - one story
repeating its day while another catches up is the normal case. The log says who waits for whom
(`days: the main story waits at the sync point Apprentice (its day 2) for The herbalist's lessons (day 3, ...)`).
`Owns = Morning` (any thirds, comma-separated) with `MorningDuty = <duty>` lets your story's day take that third's
task from the main story - your own duty from `duties.ini` too. When two packs own the same third, the one with the
lower Priority wins and the log names the conflict.

`Goal = <text>` on a day puts your story on the HUD that day - a panel with its Name and the goal, under the clan's
day (gone on a day without one). The same day it is a line in the pause menu's QUEST tab (SIDE QUESTS): the mouse
over it shows the goal on the detail panel, with `Place = <text>` (optional) under the story's name.

Not built yet: holding the game's own quests at a sync point.

The example pack's `story.ini` is a three-day story whose second day waits for the loner question to be answered.

## 8. Dialogue (`lines.ini`)

- **Murmurs**: what the clan says as your cat walks past. A set of lines, said when its conditions hold:

```ini
[Murmur.LonerTalk]
Require = SawLoner >= 1
Who = All                   ; or Elder, Warrior, Apprentice, Queen ... (the cat's role), a cat's name, E:<role>,
                            ; or your own role S:herbalist (the cat [Cast] gives it)
Line1 = That loner smelled of the Thunderpath.
Line2 = {LEADER} was kind to let him rest - kinder than I'd have been.
```

  `{PLAYER}`, `{LEADER}`, `{DEPUTY}` and `{NAME}` are filled in. Each cat says a different line every day, and
  nothing repeats until all of them have been said.
- **Dialogue by days**: `[Dialogue.<Name>] Who / Days / Require / Line1..` gives the game's filler lines for given cats
  on given days. `Who` is a role the game has filler lines for (`RiverClanQueen`, `ThunderClanWarrior` ...), not a
  cat's name - the story check lists them if you name one it doesn't know. Story dialogue always plays, even with Clan
  Life's extra chatter (`[Lines] On`) off; the log says why an entry isn't said today (`not said today: its Require
  doesn't hold ...`).

## 8b. Where a new cat starts (`start.ini`)

A story that begins later than the game's own start says so:

```ini
[Start]
Day = 13            ; the story day a new cat begins on
Level = 8           ; its level, reached through the game's own EXP (its stats grow the game's way)
Name = Warrior      ; the creator asks for the cat's whole warrior name (with WaCa Looks)
Party = TheRegretfulWarrior     ; story cats (their roles) who fight beside this cat - kept for it every session
Step1 = Card: Your first day as a warrior.
```

It applies once, and only to a NEW cat (level 1, no rank quest done): a cat someone is already playing never
changes when they install your pack. A patrol's own companions fight beside the cat while the patrol lasts, then the
start's party again. Not possible yet: a start rank (the game counts its rank quests).

## 8c. Your own cats and specialisations

- **A cat of your own** (`roster.ini`, needs WaCa Looks): change a cat of the save - by the name it has now
  (`[Cat.Troutwing]`) or by its story role (`[Narrative.TheMistrustfulLeader]`, whoever plays it in that save):
  `Name = Mossfeather` renames it, look keys (`Fur = #7B8A5A`, `ScarEarId = 6` - only values the game's own cats use)
  dress it. Every key is in WaCa Looks' `rosters/Example.ini`. Your scenes and `[Cast]` then use its new name.
- **A new clanmate** (no file needed): the scene step `Newcomer: <clanmate>` brings a grown cat into the clan that
  takes after that clanmate - its look, its rank and the end of its name, a new first part from the game's own names
  (`Newcomer: Nightheart` -> e.g. Emberheart). It stands about the camp from then on and is kept with the save; other
  mods: `WaCa.Emit("Newcomer", "<clanmate>")`, event `NewcomerJoined(name, like)` after.
- **A specialisation for the player's cat** (`roles.ini`, needs WaCa Hunting): `[Role.Herbalist]` with `Hunt`, `Fish`,
  `Combat`, `Guard` multipliers (1 = no change). A scene gives it to the cat for that save:
  `Emit: SetSpecialisation = Herbalist`.

## 8c2. A panel on the HUD (`events.ini`)

While part of your story runs, a panel in the game's quest look can say what your cat is about - it comes and goes with
your story variables:

```ini
[Panel.LostKit]
Title = Mosskit is lost
Where = The territory
Activity = Bring her home:
Goal = Catch prey - its smell will draw her out
Show = LostKit = 1            ; up while this holds
Count = KitsFound             ; optional: a story variable shown as Count/Need, with Need = 3
Done = LostKit = 2            ; optional: the check mark (else Count >= Need)
```

## 8d. Duties of your own (`duties.ini`)

A duty the deputy gives out like hunting or a patrol - a round of places your cat visits in order, each marked on
screen and on the map, then turned in:

```ini
[Duty.HerbRound]
Title = Herb round
Points = Den:Medicine Cat's den; Pile; S:herbalist     ; a den by its name, Pile, Zone:<code>, a cat / role, X Y Z
PointName1 = The medicine den                           ; what each point is called on the HUD
Card1 = The den smells of marigold and old cobweb.      ; a card when it's reached
Chance = Morning:1, Noon:1                              ; how likely, next to the clan's own duties
MinRank = Apprentice                                    ; (and MaxRank)

[Task.HerbRound]
TurnIn = MedicineCat                                    ; Pile, Partner, a role, None
```

## 9. Several packs together

Every pack adds to the same files without editing them:

- **New sections** simply exist side by side.
- **The same section in two packs:** numbered keys (`Step1`, `Line1` ...) are added after each other, so two packs can
  both add beats to `[Day.10]`.
- **Replacing another pack's section:** say so with `Replaces = <Pack>/<Section>` in yours, and yours takes its place
  whole.
- **Turning one off:** `Off = 1` in your copy of it.
- **Conflicts:** two packs setting the same plain key differently (say `Chance`) without `Replaces` is a conflict. It
  is reported in UE4SS.log (`CONFLICT`) and once on screen, so nobody wins silently.

## 10. The story check - your proofreader

When the game starts, every story file is read the way the scenes will be. Anything that would go wrong in play is
listed in `UE4SS.log` (`story check:`) and in `Saved/WaCaStoryCheck.txt`, with a line on screen:

- a step kind it doesn't know (`Crad:`);
- a cutscene nobody defines;
- `S:<role>` with no cat in `[Cast]`;
- a condition it can't read (`Pile >< 3`);
- a variable nothing ever sets, which is usually a typo (`SawLonr`);
- a `[Dialogue.*]` `Who` the game has no lines for (a cat's name instead of a role) - with the roles it has;
- a murmur's `Who = S:<role>` with no cat in `[Cast]`;
- story days your pack writes while story days are off (a warning).

WaCa Cutscenes checks your cutscenes the same way (section 6).

Read it after every change; "No problems found." means the files read cleanly.

**Writing without restarting:** set `Watch = 1` under `[StoryCheck]` in Clan Life's `config/clanlife.ini`. Then every
time you save a story file, the mod that reads it reloads within a few seconds - Clan Life for its own files, WaCa
Cutscenes for `cutscenes.ini` / `shapes.ini` / `places.ini`, WaCa Looks for `roster.ini`, WaCa Hunting for `roles.ini` -
the story check runs again, and the change plays at its next moment. Cats a reload catches mid-scene go back where
they were. Switch it off again for normal play.

Watch needs UE4SS's own auto-reload: `EnableAutoReloadingLuaMods = 1` under `[General]` in `UE4SS-settings.ini` (next
to the game's `ue4ss` folder; UE4SS ships it at 0). Without it nothing reloads - the story check says so when the game
starts. **Save your game before a writing session:** UE4SS's auto-reload very rarely freezes the game partway through
a reload (about once in 35 reloads on the test machine - the game stops responding and has to be ended). Set it back
to 0 for normal play.

## 11. A worked example: a loner visits

The example pack's loner takes four small pieces:

1. `events.ini`: `[Cast] S:loner = Rogue:Quill` - a role played by a cat brought in for its scenes.
2. `cutscenes.ini`: `[Cutscene.LonerVisit]` - Quill asks your leader for shelter (section 6).
3. `clanevents.ini`: `[Event.LonerVisit]` - some evening, once: `Cutscene: LonerVisit`, then `Set: SawLoner = 1`.
4. `lines.ini`: `[Murmur.LonerTalk] Require = SawLoner >= 1` - the clan talks about it for days.

The scene plays, the story remembers it, and the camp gossips. No code is needed for any of it.
