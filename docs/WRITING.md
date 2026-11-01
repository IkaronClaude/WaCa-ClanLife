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
| `If: <conditions>` | the rest of the scene only if they hold |
| `Wait: <s>`, `Fade: <s>`, `FadeIn: <s>` | a pause; the screen fading out / in |
| `Pose: <pose> @ <who>` | a cat plays a pose (Sit, Growl, Hiss, Sniff ...) |
| `Emit: <event>` | sends an event other mods (or your own `When = Event:`) hear |
| `Hook: <name>` | a mod's own Lua code runs here |

## 4. Who - naming cats

- **Parts of your clan:** `Leader`, `Deputy`, `MedicineCat`, `Nearest` (the nearest clanmate), `Player`.
- **A cat by its name:** `Lionstar`.
- **A story role:** `E:RiverClanDeputy`.
- **Your own role:** `S:<role>`, given a cat in `events.ini`:

```ini
[Cast]
S:herbalist = Mossfeather      ; a cat of the clan, by name
S:loner = Rogue:Quill          ; a cat who isn't in the world - brought in for each scene that asks for it
S:envoy = Clan:ShadowClan      ; another Clan's cat (Clan:<Clan>.<Part> for its leader / deputy ...)
```

Your scenes then say `@ S:herbalist`, and your cutscenes say `B = S:loner`.

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
Place = Here                ; Here (in front of your cat), Pile, Zone:<code> ...
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
README.

Cast slots take the same names as section 4. They also take `Rogue`, `Rogue:<Name>` and `Clan:<Clan>`: cats brought in
for the scene and gone after it.

## 7. Story days (`days.ini`)

The story as days. Each `[Day.N]` sets that story day's beats per third (`Morning`, `Noon`, `Evening`, `Night`, as many
numbered as you need: `Morning2`, `Morning3` ...). It can also set the day's duties, season and weather.

`Advance` says when the story moves on. Until it holds, the story day repeats. `Like = M` copies a day you already
wrote. The full key list is at the top of Clan Life's `config/days.ini`.

## 8. Dialogue (`lines.ini`)

- **Murmurs**: what the clan says as your cat walks past. A set of lines, said when its conditions hold:

```ini
[Murmur.LonerTalk]
Require = SawLoner >= 1
Who = All                   ; or Elder, Warrior, Apprentice, Queen ... (the cat's role)
Line1 = That loner smelled of the Thunderpath.
Line2 = {LEADER} was kind to let him rest - kinder than I'd have been.
```

  `{PLAYER}`, `{LEADER}`, `{DEPUTY}` and `{NAME}` are filled in. Each cat says a different line every day, and
  nothing repeats until all of them have been said.
- **Dialogue by days**: `[Dialogue.<Name>] Who / Days / Require / Line1..` gives the game's filler lines for given cats
  on given days.

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
- a variable nothing ever sets, which is usually a typo (`SawLonr`).

Read it after every change; "No problems found." means the files read cleanly.

**Writing without restarting:** set `Watch = 1` under `[StoryCheck]` in Clan Life's `config/clanlife.ini`. Then every
time you save a story file, Clan Life (and WaCa Cutscenes, for your scenes) reloads within a few seconds, the story
check runs again, and the change plays at its next moment. Switch it off again for normal play.

## 11. A worked example: a loner visits

The example pack's loner takes four small pieces:

1. `events.ini`: `[Cast] S:loner = Rogue:Quill` - a role played by a cat brought in for its scenes.
2. `cutscenes.ini`: `[Cutscene.LonerVisit]` - Quill asks your leader for shelter (section 6).
3. `clanevents.ini`: `[Event.LonerVisit]` - some evening, once: `Cutscene: LonerVisit`, then `Set: SawLoner = 1`.
4. `lines.ini`: `[Murmur.LonerTalk] Require = SawLoner >= 1` - the clan talks about it for days.

The scene plays, the story remembers it, and the camp gossips. No code is needed for any of it.
