"""Proofread a story pack WITHOUT starting the game: its steps, cutscene beats, camera shots, roles and Reach: lines.
usage: python check_pack.py <pack folder> [--mods <the game's ue4ss\\Mods folder>]
The names it knows (step kinds, cutscene actions, camera shots) are read from the installed mods' own Lua, next to the
pack (or --mods), so it stays in step with them. The in-game story check (Saved\\WaCaStoryCheck.txt) checks more - the
cats and places of a real save; this is the quick pass while writing. Exit code 1 when there are problems."""
import os, re, sys

def read_ini(path):
    """{section: [(key, value, line number)]} - keys in order (a pack may repeat a key)"""
    out, sec = {}, ""
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8-sig", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            line = raw.strip()
            if not line or line[0] in ";#":
                continue
            m = re.match(r"^\[(.+)\]$", line)
            if m:
                sec = m.group(1).strip()
                out.setdefault(sec, [])
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                v = re.sub(r"\s;.*$", "", v)          # (a trailing ; comment)
                out.setdefault(sec, []).append((k.strip(), v.strip(), n))
    return out

def lua_names(path, pattern):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return set(re.findall(pattern, f.read()))

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    pack = os.path.abspath(args[0])
    mods = os.path.abspath(args[args.index("--mods") + 1]) if "--mods" in args else os.path.dirname(pack)
    content = os.path.join(pack, "content")
    if not os.path.isdir(content):
        print(f"no content folder in {pack}")
        return 2

    sc = os.path.join(mods, "WaCaClanLife", "Scripts", "storycheck.lua")
    cs = os.path.join(mods, "WaCaCutscenes", "Scripts", "cutscenes.lua")
    kinds = None
    if os.path.exists(sc):
        with open(sc, encoding="utf-8", errors="replace") as f:
            m = re.search(r"local KINDS = \{(.*?)\}", f.read(), re.S)
        kinds = set(re.findall(r"(\w+) = true", m.group(1))) if m else None
    actions = lua_names(cs, r"function ACTIONS\.(\w+)")
    shots = None
    if os.path.exists(cs):
        with open(cs, encoding="utf-8", errors="replace") as f:
            m = re.search(r"local SHOTS = \{(.*?)\}", f.read(), re.S)
        shots = set(re.findall(r"(\w+) = true", m.group(1))) if m else None
    missing = [n for n, v in (("WaCa Clan Life (step kinds)", kinds), ("WaCa Cutscenes (actions, shots)", actions)) if not v]

    problems, warnings = [], []
    def problem(f, sec, k, n, text): problems.append(f"{f}:{n} [{sec}] {k}: {text}")
    def warning(f, sec, k, n, text): warnings.append(f"{f}:{n} [{sec}] {k}: {text}")

    # the roles cast: this pack, every other pack beside it, Clan Life's own config
    cast = {}
    sources = [os.path.join(content, "events.ini"), os.path.join(mods, "WaCaClanLife", "config", "events.ini")]
    if os.path.isdir(mods):
        for d in os.listdir(mods):
            p = os.path.join(mods, d, "content", "events.ini")
            if os.path.isfile(p) and p not in sources:
                sources.append(p)
    for p in sources:
        for k, v, _ in read_ini(p).get("Cast", []):
            cast[k] = v

    # (a role a Newcomer step gives its cat in play - "Newcomer: <clanmate> as S:apprentice" - counts as cast)
    for d in ([pack] + [os.path.join(mods, x) for x in os.listdir(mods)] if os.path.isdir(mods) else [pack]):
        for fname in ("clanevents.ini", "days.ini", "gatherings.ini"):
            for items in read_ini(os.path.join(d, "content", fname)).values():
                for k, v, _ in items:
                    for role in re.findall(r"^\s*Newcomer\s*:.*\bas\s+(S:[A-Za-z0-9_]+)", v):
                        cast.setdefault(role, "a newcomer")

    def roles_in(text):
        return re.findall(r"S:[A-Za-z0-9_]+", text or "")

    # STEPS - clan events, story days, Gathering scenes, a pack's duties' events
    for fname in ("clanevents.ini", "days.ini", "gatherings.ini", "duties.ini"):
        ini = read_ini(os.path.join(content, fname))
        for sec, items in ini.items():
            for k, v, n in items:
                if re.match(r"^Step\d*$", k):
                    m = re.match(r"^\s*(\w+)\s*(?::|$)", v)     # (Else, EndIf, Release: no value)
                    if not m:
                        problem(fname, sec, k, n, f"can't read the step '{v}' (Kind: what)")
                        continue
                    if kinds and m.group(1) not in kinds:
                        problem(fname, sec, k, n, f"unknown step kind '{m.group(1)}' (known: {', '.join(sorted(kinds))})")
                for role in roles_in(v):
                    if role not in cast:
                        problem(fname, sec, k, n, f"the role {role} has no cat - give it one in [Cast] (content\\events.ini)")
                if k == "When" and fname == "clanevents.ini":
                    r = re.match(r"^Reach:\s*(.+)$", v)
                    spec = r and r.group(1).strip()
                    if spec and re.match(r"^S:", spec) and cast.get(spec, "").startswith(("Rogue", "Clan:")):
                        warning(fname, sec, k, n, f"{spec} is played by {cast[spec]}, brought in only for scenes - it can't be met")
                    elif spec and re.match(r"^-?[\d.]+[\s,]", spec) and not re.match(r"^-?[\d.]+[\s,]+-?[\d.]+[\s,]+-?[\d.]+$", spec):
                        warning(fname, sec, k, n, f"'{spec}' looks like a place but isn't x y z")

    # CUTSCENES - beats, actions, camera shots and the cats they frame, cast specs
    ini = read_ini(os.path.join(content, "cutscenes.ini"))
    need = {"Portrait": 1, "Behind": 1, "Over": 2, "Two": 2}
    for sec, items in ini.items():
        if not sec.startswith("Cutscene."):
            continue
        for k, v, n in items:
            if re.match(r"^[A-Z]$", k) or k in ("Leader", "Deputy", "MedicineCat") or k.startswith("Role"):
                for role in roles_in(v):
                    if role not in cast:
                        problem("cutscenes.ini", sec, k, n, f"the role {role} has no cat - give it one in [Cast]")
            if not re.match(r"^Beat\d+[a-z]?$", k):
                continue
            m = re.match(r"^\s*[\d.]+\s*(\[[^\]]*\]\s*)?(\w+)\s*(?::\s*(.*))?$", v)
            if not m:
                problem("cutscenes.ini", sec, k, n, f"can't read the beat '{v}' (<seconds> Action: who = what)")
                continue
            action, rest = m.group(2), (m.group(3) or "")
            if actions and action not in actions:
                problem("cutscenes.ini", sec, k, n, f"no action '{action}' (known: {', '.join(sorted(actions))})")
                continue
            if action == "Camera":
                who, _, what = rest.partition("=")
                shot = (re.match(r"^\s*(\w+)", who) or [None, None])[1]
                if shots and shot and shot not in shots:
                    problem("cutscenes.ini", sec, k, n, f"no camera shot '{shot}' (known: {', '.join(sorted(shots))})")
                elif shot in need:
                    named = len([x for x in re.split(r"[,&>]", re.sub(r"~[\d.]+", "", what)) if x.strip()])
                    if named < need[shot]:
                        problem("cutscenes.ini", sec, k, n, f"Camera: {shot} frames {need[shot]} cat(s), {named} named")
            for role in roles_in(rest):
                if role not in cast:
                    problem("cutscenes.ini", sec, k, n, f"the role {role} has no cat - give it one in [Cast]")

    print(f"pack check: {os.path.basename(pack)} - {len(problems)} problem(s), {len(warnings)} warning(s)")
    for m in missing:
        print(f"  (not found next to the pack: {m} - those names weren't checked; use --mods <the game's ue4ss\\Mods>)")
    for p in problems:
        print("  PROBLEM  " + p)
    for w in warnings:
        print("  warning  " + w)
    return 1 if problems else 0

if __name__ == "__main__":
    sys.exit(main())
