"""The editor PAGE end to end in headless Edge: its own Open / edit / Save code on a pack, with an in-memory folder in place
of the folder picker (the only part a click is needed for). usage: python test_page.py <pack folder>
Checks: the pack opens, an edit through the form enables Save, Save writes only the changed file, the written file is
the original with that one line changed (line endings kept), Save is off again after."""
import json, os, re, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
pack = os.path.join(os.path.abspath(sys.argv[1]), "content")
texts = {}
for f in os.listdir(pack):
    if f.endswith(".ini"):
        with open(os.path.join(pack, f), encoding="utf-8", newline="") as h:
            texts[f] = h.read()
with open(os.path.join(here, "pack_editor.html"), encoding="utf-8") as h:
    page = h.read()

# the edit: the first numeric value of the first [Event.*] in clanevents.ini, + 7
ev = re.search(r"^\[(Event\.[^\]]+)\]\s*$", texts["clanevents.ini"], re.M).group(1)
body = texts["clanevents.ini"].split("[" + ev + "]", 1)[1].split("\n[", 1)[0]
key, val = re.search(r"^(\w+)\s*=\s*(\d+)\s*$", body, re.M).groups()
new = str(int(val) + 7)

harness = """<script>
const DISK = Object.assign({}, %(disk)s), WRITES = {};
const fh = n => ({ kind: "file", name: n, getFile: async () => ({ text: async () => DISK[n] }),
  createWritable: async () => { let b = ""; return { write: async t => { b += t; }, close: async () => { DISK[n] = b; WRITES[n] = b; } }; } });
const content = { kind: "directory", name: "content", entries: async function* () { for (const n of Object.keys(DISK)) yield [n, fh(n)]; },
  getFileHandle: async n => fh(n) };
window.showDirectoryPicker = async () => ({ kind: "directory", name: "pack", getDirectoryHandle: async n => { if (n !== "content") throw 0; return content; } });
(async () => {
  const r = {};
  await document.getElementById("open").onclick();
  r.opened = document.getElementById("status").textContent;
  r.saveOffAfterOpen = document.getElementById("save").disabled;
  current = { file: "clanevents.ini", section: %(ev)s }; render();
  const k = [...document.querySelectorAll('#editor input[data-f="k"]')].find(i => i.value === %(key)s);
  const v = k && k.closest("tr").querySelector('input[data-f="v"]');
  if (v) { v.value = %(new)s; v.onchange(); }
  r.saveOnAfterEdit = !document.getElementById("save").disabled;
  await document.getElementById("save").onclick();
  r.written = Object.keys(WRITES);
  r.after = WRITES["clanevents.ini"] || "";
  r.saveOffAfterSave = document.getElementById("save").disabled;
  const pre = document.createElement("pre"); pre.id = "RESULT"; pre.textContent = JSON.stringify(r); document.body.appendChild(pre);
})();
</script>
</body>""" % {"disk": json.dumps(texts), "ev": json.dumps(ev), "key": json.dumps(key), "new": json.dumps(new)}

tmp = os.path.join(tempfile.mkdtemp(), "editor_page_test.html")
with open(tmp, "w", encoding="utf-8") as h:
    h.write(page.replace("</body>", harness))
edge = next(p for p in (os.path.expandvars(r"%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"),
                        os.path.expandvars(r"%ProgramFiles%\Microsoft\Edge\Application\msedge.exe")) if os.path.exists(p))
dom = subprocess.run([edge, "--headless=new", "--disable-gpu", "--virtual-time-budget=5000", "--dump-dom", "file:///" + tmp.replace(os.sep, "/")],
                     capture_output=True, text=True, encoding="utf-8").stdout
m = re.search(r'<pre id="RESULT">(.*?)</pre>', dom, re.S)
if not m:
    print("FAIL - the page test didn't finish"); sys.exit(1)
import html
r = json.loads(html.unescape(m.group(1)))
before, after = texts["clanevents.ini"], r["after"]
a, b = before.split("\n"), after.split("\n")
changed = [(x, y) for x, y in zip(a, b) if x != y]
checks = [
    ("the pack opens (" + r["opened"] + ")", "13 file" in r["opened"] or "file(s)" in r["opened"]),
    ("Save is off after opening", r["saveOffAfterOpen"]),
    (f"an edit in the form ([{ev}] {key} {val} -> {new}) turns Save on", r["saveOnAfterEdit"]),
    ("Save writes only the changed file " + str(r["written"]), r["written"] == ["clanevents.ini"]),
    (f"the written file = the original with one line changed {changed}", len(a) == len(b) and len(changed) == 1 and changed[0][1].strip().endswith(new)),
    ("line endings kept", ("\r\n" in before) == ("\r\n" in after)),
    ("Save is off again after saving", r["saveOffAfterSave"]),
]
for what, ok in checks:
    print(("  ok   " if ok else "  FAIL ") + what)
sys.exit(0 if all(ok for _, ok in checks) else 1)
