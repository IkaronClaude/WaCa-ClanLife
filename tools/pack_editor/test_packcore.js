// node test_packcore.js <pack folder> [<broken pack folder>] - the editor core's round trip and check, against real packs
"use strict";
const fs = require("fs"), path = require("path"), C = require("./packcore.js");
let failed = 0;
const ok = (cond, what) => { console.log((cond ? "  ok   " : "  FAIL ") + what); if (!cond) failed++; };

const known = JSON.parse(fs.readFileSync(path.join(__dirname, "known.json"), "utf8"));
function load(pack) {
    const dir = path.join(pack, "content"), files = {};
    for (const f of fs.readdirSync(dir)) if (f.endsWith(".ini")) files[f] = C.parseIni(fs.readFileSync(path.join(dir, f), "utf8"));
    return { dir, files };
}

const [packDir, brokenDir] = process.argv.slice(2);
const { dir, files } = load(packDir);
console.log("round trip (every file byte for byte):");
for (const f of Object.keys(files)) ok(C.serializeIni(files[f]) === fs.readFileSync(path.join(dir, f), "utf8"), f);

console.log("edits:");
const m = C.parseIni(fs.readFileSync(path.join(dir, "clanevents.ini"), "utf8"));
const before = C.serializeIni(m);
C.set(m, "Event.HerbLesson", "Chance", "50");
ok(C.get(m, "Event.HerbLesson", "Chance") === "50", "set a key -> get it back");
C.set(m, "Event.NewOne", "When", "Morning");
C.set(m, "Event.NewOne", "Step1", "Card: Hello {PLAYER}.");
const again = C.parseIni(C.serializeIni(m));
ok(C.get(again, "Event.NewOne", "Step1") === "Card: Hello {PLAYER}.", "a new section + keys survive a write and a read");
C.set(again, "Event.NewOne", "Step1", null);
ok(C.get(again, "Event.NewOne", "Step1") === undefined, "a key removed");
const diff = C.serializeIni(m).split(/\r\n/).filter((l, i) => l !== before.split(/\r\n/)[i]).length;
ok(diff <= 6, `an edit touches only its lines (${diff} line(s) differ)`);

console.log("check:");
const r = C.check(files, known, []);
ok(r.problems.length === 0, `the pack: ${r.problems.length} problem(s), ${r.warnings.length} warning(s)`);
for (const p of r.problems) console.log("       " + JSON.stringify(p));
const o = C.outline(files);
ok(o.events.length > 0 && o.cutscenes.length > 0, `outline: ${o.events.length} events, ${o.cutscenes.length} cutscenes, ${o.cast.length} roles, ${o.murmurs.length} murmurs`);
if (brokenDir) {
    const b = load(brokenDir);
    const rb = C.check(b.files, known, []);
    ok(rb.problems.length === 7, `the broken pack: ${rb.problems.length} problem(s) (check_pack.py found 7)`);
    for (const p of rb.problems) console.log("       " + p.file + " [" + p.section + "] " + p.key + ": " + p.text);
}
console.log(failed ? `${failed} FAILED` : "all passed");
process.exit(failed ? 1 : 0);
