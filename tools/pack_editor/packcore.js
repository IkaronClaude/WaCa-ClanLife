// THE STORY-PACK EDITOR'S CORE (no browser needed - node tests it): read a pack's ini files keeping every comment,
// blank line and key order, change keys, write them back byte for byte where nothing changed; and check a pack the way
// tools/check_pack.py does. pack_editor.html wraps it (build_pack_editor.py bakes in the mods' known names).
"use strict";

// --- ini, round-trip safe ---

// text -> { eol, sections: [{ name, lines: [{ kind: "kv" | "other", key, value, raw }] }] } - the lines before the first
// [section] live in a section named "" (comments at the top of a file)
function parseIni(text) {
    const eol = text.includes("\r\n") ? "\r\n" : "\n";
    const raw = text.split(/\r?\n/);
    if (raw.length && raw[raw.length - 1] === "") raw.pop();       // (the file's last line end)
    const sections = [{ name: "", lines: [] }];
    for (const line of raw) {
        const t = line.trim();
        const h = /^\[(.+)\]$/.exec(t);
        if (h) { sections.push({ name: h[1].trim(), header: line, lines: [] }); continue; }
        const cur = sections[sections.length - 1];
        if (t && !/^[;#]/.test(t) && t.includes("=")) {
            const i = line.indexOf("=");
            const key = line.slice(0, i).trim();
            let value = line.slice(i + 1);
            const m = /\s;.*$/.exec(value);                           // (a trailing ; comment stays with the line)
            cur.lines.push({ kind: "kv", key, value: (m ? value.slice(0, m.index) : value).trim(), raw: line });
        } else {
            cur.lines.push({ kind: "other", raw: line });
        }
    }
    return { eol, sections };
}

function serializeIni(model) {
    const out = [];
    for (const s of model.sections) {
        if (s.name !== "" || s.header !== undefined) out.push(s.header !== undefined ? s.header : "[" + s.name + "]");
        for (const l of s.lines) out.push(l.raw);
    }
    return out.join(model.eol) + model.eol;
}

function section(model, name) { return model.sections.find(s => s.name === name) || null; }

function get(model, sec, key) {
    const s = section(model, sec);
    const l = s && s.lines.find(x => x.kind === "kv" && x.key === key);
    return l ? l.value : undefined;
}

// set a key (a changed line keeps its trailing comment); value null removes it; a new key goes after the section's
// last key (before its trailing blank / comment lines)
function set(model, sec, key, value) {
    let s = section(model, sec);
    if (!s) {
        if (value === null) return;
        const last = model.sections[model.sections.length - 1];
        if (last.lines.length && last.lines[last.lines.length - 1].raw.trim() !== "") last.lines.push({ kind: "other", raw: "" });
        s = { name: sec, header: "[" + sec + "]", lines: [] };
        model.sections.push(s);
    }
    const i = s.lines.findIndex(x => x.kind === "kv" && x.key === key);
    if (value === null) { if (i >= 0) s.lines.splice(i, 1); return; }
    if (i >= 0) {
        const l = s.lines[i];
        const m = /\s;.*$/.exec(l.raw.slice(l.raw.indexOf("=") + 1));
        l.value = String(value);
        l.raw = key + " = " + l.value + (m ? " " + m[0].trim() : "");
        return;
    }
    let at = s.lines.length;
    while (at > 0 && s.lines[at - 1].kind !== "kv") at--;
    if (at === 0) at = s.lines.length;
    s.lines.splice(at, 0, { kind: "kv", key, value: String(value), raw: key + " = " + value });
}

// --- the check (tools/check_pack.py's rules; known = { kinds, actions, shots } from the mods' Lua) ---

const NEED = { Portrait: 1, Behind: 1, Over: 2, Two: 2 };
const rolesIn = text => (String(text || "").match(/S:[A-Za-z0-9_]+/g) || []);

// files: { "clanevents.ini": model, ... } (the pack's content folder); others: extra [Cast] models (other packs)
function check(files, known, others) {
    const problems = [], warnings = [];
    const kv = model => model ? model.sections.flatMap(s => s.lines.filter(l => l.kind === "kv").map(l => ({ sec: s.name, ...l }))) : [];
    // (the roles Clan Life casts itself in play - events.lua Events.BUILTIN_ROLES)
    const cast = { "S:mentor": "your mentor (from the game's own text)" };
    for (const m of [files["events.ini"], ...(others || [])]) {
        const s = m && section(m, "Cast");
        if (s) for (const l of s.lines) if (l.kind === "kv") cast[l.key] = l.value;
    }
    for (const f of ["clanevents.ini", "days.ini", "gatherings.ini"]) {
        for (const l of kv(files[f])) {
            const m = /^\s*Newcomer\s*:.*\bas\s+(S:[A-Za-z0-9_]+)/.exec(l.value);
            if (m && !cast[m[1]]) cast[m[1]] = "a newcomer";
        }
    }
    const P = (f, l, text) => problems.push({ file: f, section: l.sec, key: l.key, text });
    const W = (f, l, text) => warnings.push({ file: f, section: l.sec, key: l.key, text });
    const uncast = (f, l, v) => { for (const r of rolesIn(v)) if (!(r in cast)) P(f, l, `the role ${r} has no cat - give it one in [Cast]`); };

    for (const f of ["clanevents.ini", "days.ini", "gatherings.ini", "duties.ini"]) {
        for (const l of kv(files[f])) {
            if (/^Step\d*$/.test(l.key)) {
                const m = /^\s*(\w+)\s*(?::|$)/.exec(l.value);
                if (!m) P(f, l, `can't read the step '${l.value}' (Kind: what)`);
                else if (known.kinds && !known.kinds.includes(m[1])) P(f, l, `unknown step kind '${m[1]}'`);
            }
            uncast(f, l, l.value);
            if (l.key === "When" && f === "clanevents.ini") {
                const r = /^Reach:\s*(.+)$/.exec(l.value);
                const spec = r && r[1].trim();
                if (spec && /^S:/.test(spec) && /^(Rogue|Clan:)/.test(cast[spec] || "")) W(f, l, `${spec} is played by ${cast[spec]}, brought in only for scenes - it can't be met`);
                else if (spec && /^-?[\d.]+[\s,]/.test(spec) && !/^-?[\d.]+[\s,]+-?[\d.]+[\s,]+-?[\d.]+$/.test(spec)) W(f, l, `'${spec}' looks like a place but isn't x y z`);
            }
        }
    }
    for (const l of kv(files["lines.ini"])) if (l.key === "Who" || /^Line\d+$/.test(l.key)) uncast("lines.ini", l, l.value);
    for (const l of kv(files["cutscenes.ini"])) {
        if (!l.sec.startsWith("Cutscene.")) continue;
        if (/^[A-Z]$/.test(l.key)) uncast("cutscenes.ini", l, l.value);
        if (!/^Beat\d+[a-z]?$/.test(l.key)) continue;
        const m = /^\s*[\d.]+\s*(\[[^\]]*\]\s*)?(\w+)\s*(?::\s*(.*))?$/.exec(l.value);
        if (!m) { P("cutscenes.ini", l, `can't read the beat '${l.value}' (<seconds> Action: who = what)`); continue; }
        const action = m[2], rest = m[3] || "";
        if (known.actions && !known.actions.includes(action)) { P("cutscenes.ini", l, `no action '${action}'`); continue; }
        if (action === "Camera") {
            const [who, what = ""] = rest.split(/=(.*)/s);
            const shot = (/^\s*(\w+)/.exec(who) || [])[1];
            if (known.shots && shot && !known.shots.includes(shot)) P("cutscenes.ini", l, `no camera shot '${shot}'`);
            else if (NEED[shot]) {
                const named = what.replace(/~[\d.]+/g, "").split(/[,&>]/).filter(x => x.trim()).length;
                if (named < NEED[shot]) P("cutscenes.ini", l, `Camera: ${shot} frames ${NEED[shot]} cat(s), ${named} named`);
            }
        }
        uncast("cutscenes.ini", l, rest);
    }
    return { problems, warnings };
}

// the pack's sections an editor lists: events, cutscenes, the cast, murmurs
function outline(files) {
    const names = (f, prefix) => (files[f] ? files[f].sections.filter(s => s.name.startsWith(prefix)).map(s => s.name) : []);
    return {
        events: names("clanevents.ini", "Event."),
        cutscenes: names("cutscenes.ini", "Cutscene."),
        murmurs: names("lines.ini", "Murmur."),
        cast: files["events.ini"] && section(files["events.ini"], "Cast") ? section(files["events.ini"], "Cast").lines.filter(l => l.kind === "kv").map(l => l.key) : [],
    };
}

const PackCore = { parseIni, serializeIni, section, get, set, check, outline };
if (typeof module !== "undefined") module.exports = PackCore;
if (typeof window !== "undefined") window.PackCore = PackCore;
