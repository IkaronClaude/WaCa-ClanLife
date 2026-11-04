"""Bake the story-pack editor: pack_editor/pack_editor.html (+ known.json for the tests) with the names the installed
mods know - step kinds (WaCa Clan Life's storycheck.lua), cutscene actions and camera shots (WaCa Cutscenes' cutscenes.lua)
- and packcore.js inlined, so the page is one file a writer opens in Chrome / Edge.
usage: python build_pack_editor.py [--mods <the game's ue4ss\\Mods>]   (default: this repo + its WaCa-Cutscenes sibling)"""
import json, os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
args = sys.argv[1:]
if "--mods" in args:
    mods = args[args.index("--mods") + 1]
    sc = os.path.join(mods, "WaCaClanLife", "Scripts", "storycheck.lua")
    cs = os.path.join(mods, "WaCaCutscenes", "Scripts", "cutscenes.lua")
else:
    sc = os.path.join(here, "..", "Mods", "WaCaClanLife", "Scripts", "storycheck.lua")
    cs = os.path.join(here, "..", "..", "WaCa-Cutscenes", "Mods", "WaCaCutscenes", "Scripts", "cutscenes.lua")

def table(path, name):
    with open(path, encoding="utf-8") as f:
        m = re.search(r"local " + name + r" = \{(.*?)\}", f.read(), re.S)
    return sorted(set(re.findall(r"(\w+) = true", m.group(1))))

with open(cs, encoding="utf-8") as f:
    actions = sorted(set(re.findall(r"function ACTIONS\.(\w+)", f.read())))
known = {"kinds": table(sc, "KINDS"), "actions": actions, "shots": table(cs, "SHOTS")}
ed = os.path.join(here, "pack_editor")
with open(os.path.join(ed, "known.json"), "w", encoding="utf-8") as f:
    json.dump(known, f, indent=1)
with open(os.path.join(ed, "packcore.js"), encoding="utf-8") as f:
    core = f.read()
with open(os.path.join(ed, "page.html"), encoding="utf-8") as f:
    page = f.read()
page = page.replace("/*PACKCORE*/", core).replace("/*KNOWN*/null", json.dumps(known))
with open(os.path.join(ed, "pack_editor.html"), "w", encoding="utf-8", newline="\n") as f:
    f.write(page)
print(f"pack_editor.html: {len(known['kinds'])} step kinds, {len(actions)} actions, {len(known['shots'])} shots")
