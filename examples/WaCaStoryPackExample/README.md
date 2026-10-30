# WaCa story pack example

A story pack with no code: a folder in `ue4ss\Mods` with `enabled.txt` and a `content` folder. It shows the three
things a writer adds most:

| File | What it adds | Read by |
| --- | --- | --- |
| `content\roster.ini` | a **custom cat**: Troutwing, a RiverClan warrior, becomes *Mossfeather* (name and coat) | WaCa Looks |
| `content\events.ini` | a **custom role**: `S:herbalist`, played by Mossfeather | WaCa Clan Life (`[Cast]`) |
| `content\cutscenes.ini` | a **custom cutscene**: `HerbLesson`, the herbalist and your cat | WaCa Cutscenes |
| `content\clanevents.ini` | a **clan event** that plays it some mornings and adds bond | WaCa Clan Life |

Install: copy `WaCaStoryPackExample` into `...\Wrc\Binaries\Win64\ue4ss\Mods\` and add `WaCaStoryPackExample : 1` to
`mods.txt` (or keep the `enabled.txt`). Needs WaCa Core, WaCa Looks, WaCa Clan Life and WaCa Cutscenes, playing
RiverClan.

Try the cutscene at once: set `Preview = HerbLesson` in `WaCaCutscenes\config\cutscenes.ini` and press its PreviewKey.
