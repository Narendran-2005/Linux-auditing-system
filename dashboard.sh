#!/bin/bash
# dashboard.sh - builds a single-file HTML dashboard from a results file
# Usage: dashboard.sh RESULTS_FILE [OUTPUT_HTML]
unset AUDIT_RESULTS   # never record the dashboard's own messages
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -u -o pipefail
umask 077             # reports list weaknesses: owner-only permissions

if (( $# < 1 )) || [[ ! -r "$1" ]]; then
    fail "usage: dashboard.sh RESULTS_FILE [OUTPUT_HTML] (results file not readable)"
    exit 2
fi

results="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${REPORT_DIR:-$ROOT_DIR/reports}"
mkdir -p "$REPORT_DIR" || { fail "cannot create $REPORT_DIR"; exit 1; }
out="${2:-$REPORT_DIR/audit-$(uname -n)-$(date +%F_%H-%M-%S).html}"

have python3 || { fail "python3 is required to build the dashboard"; exit 1; }

python3 - "$results" "$out" "$REPORT_DIR" <<'PY'
import csv, datetime, html, os, platform, re, shutil, socket, sys

results_path, out_path, report_dir = sys.argv[1], sys.argv[2], sys.argv[3]
prev_path = os.path.join(report_dir, "previous.tsv")
hist_path = os.path.join(report_dir, "history.csv")
STATUSES = ("FAIL", "WARN", "PASS")
esc = html.escape

def read_records(path):
    recs = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t", 2)
                if len(parts) == 3 and parts[0] in STATUSES:
                    recs.append(tuple(parts))
    except FileNotFoundError:
        pass
    return recs

def os_name():
    try:
        with open("/etc/os-release", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.system()

def worst(items):
    sts = {st for st, _ in items}
    if "FAIL" in sts:
        return "FAIL"
    if "WARN" in sts:
        return "WARN"
    return "PASS"

def findings(recs):
    return {r for r in recs if r[0] != "PASS"}

def change_html(items):
    if not items:
        return "<p class='muted'>None</p>"
    lis = []
    for st, sec, msg in sorted(items):
        lis.append(f"<li><span class='tag {st.lower()}'>{st}</span>{esc(sec)}: {esc(msg)}</li>")
    return "<ul>" + "".join(lis) + "</ul>"

# ---- Load this run -------------------------------------------------------
records = read_records(results_path)
if not records:
    sys.exit("no audit results were recorded")

total = len(records)
counts = {s: sum(1 for r in records if r[0] == s) for s in STATUSES}
score = round(100 * (counts["PASS"] + 0.5 * counts["WARN"]) / total)
score_class = "good" if score >= 80 else "mid" if score >= 60 else "bad"

sections = {}
for st, sec, msg in records:
    sections.setdefault(sec, []).append((st, msg))

# ---- Compare with the previous run ---------------------------------------
prev = read_records(prev_path)
has_prev = bool(prev)
cur_f, prev_f = findings(records), findings(prev)
new_f = (cur_f - prev_f) if has_prev else set()
resolved_f = (prev_f - cur_f) if has_prev else set()

# ---- Score history (CSV, one row per run) --------------------------------
host = socket.gethostname()
now = datetime.datetime.now()
write_header = not os.path.exists(hist_path)
with open(hist_path, "a", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    if write_header:
        w.writerow(["timestamp", "host", "pass", "warn", "fail", "score"])
    w.writerow([now.isoformat(timespec="seconds"), host,
                counts["PASS"], counts["WARN"], counts["FAIL"], score])
with open(hist_path, encoding="utf-8") as fh:
    history = list(csv.DictReader(fh))[-10:]

shutil.copyfile(results_path, prev_path)

# ---- Build HTML fragments ------------------------------------------------
def section_html(name, items):
    rows = []
    for st, msg in items:
        badge = " <span class='new'>NEW</span>" if (st, name, msg) in new_f else ""
        text = esc((name + " " + msg).lower())
        rows.append(
            f"<li class='row' data-status='{st}' data-text='{text}'>"
            f"<span class='tag {st.lower()}'>{st}</span>{esc(msg)}{badge}</li>")
    w = worst(items)
    return (f"<section class='card' data-section>"
            f"<h3>{esc(name)} <span class='pill {w.lower()}'>{w}</span></h3>"
            f"<ul>{''.join(rows)}</ul></section>")

if not has_prev:
    changes = ("<p class='muted'>First run on this host. Run the audit again later "
               "and this panel will show what has changed.</p>")
else:
    changes = (f"<h4>New findings ({len(new_f)})</h4>{change_html(new_f)}"
               f"<h4>Resolved since last run ({len(resolved_f)})</h4>{change_html(resolved_f)}")

hist_rows = []
for r in history:
    hist_rows.append(
        f"<tr><td>{esc(r['timestamp'].replace('T', ' '))}</td>"
        f"<td>{esc(r['host'])}</td><td>{esc(r['score'])}</td>"
        f"<td>{esc(r['fail'])}</td><td>{esc(r['warn'])}</td>"
        f"<td><div class='bar'><span style='width:{esc(r['score'])}%'></span></div></td></tr>")

values = {
    "TITLE": esc(f"Audit: {host}"),
    "HOST": esc(host),
    "OS": esc(os_name()),
    "KERNEL": esc(os.uname().release),
    "GENERATED": esc(now.strftime("%Y-%m-%d %H:%M")),
    "PRIVS": "running as root" if os.geteuid() == 0 else "not root: some checks are limited",
    "SCORE": str(score),
    "SCORECLASS": score_class,
    "PASS": str(counts["PASS"]),
    "WARN": str(counts["WARN"]),
    "FAIL": str(counts["FAIL"]),
    "CHANGES": changes,
    "SECTIONS": "".join(section_html(n, items) for n, items in sections.items()),
    "HISTORY": "".join(hist_rows),
}

TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>@@TITLE@@</title>
<style>
:root { --pass:#16a34a; --warn:#d97706; --fail:#dc2626; --bg:#f3f4f6;
        --card:#ffffff; --ink:#1f2937; --muted:#6b7280; --line:#e5e7eb; }
* { box-sizing: border-box; }
body { margin:0; font:14px/1.5 system-ui, -apple-system, Segoe UI, sans-serif;
       background:var(--bg); color:var(--ink); }
header { background:#111827; color:#fff; padding:20px 28px; }
header h1 { margin:0; font-size:20px; }
header p { margin:4px 0 0; color:#9ca3af; }
main { max-width:1200px; margin:0 auto; padding:24px 28px; }
h2 { font-size:16px; margin:0 0 10px; }
h3 { font-size:15px; margin:0 0 8px; }
h4 { font-size:13px; margin:12px 0 4px; color:var(--muted); }
.card { background:var(--card); border-radius:10px; padding:16px 18px;
        box-shadow:0 1px 2px rgba(0,0,0,.06); }
.top { display:grid; grid-template-columns:220px 1fr; gap:16px; margin-bottom:16px; }
.center { text-align:center; }
.muted { color:var(--muted); }
.ring { width:140px; height:140px; border-radius:50%; margin:6px auto 4px;
        display:grid; place-items:center;
        background:conic-gradient(var(--c) calc(var(--p) * 1%), var(--line) 0); }
.ring span { background:#fff; width:106px; height:106px; border-radius:50%;
             display:grid; place-items:center; font-size:30px; font-weight:700; }
.ring.good { --c:var(--pass); } .ring.mid { --c:var(--warn); } .ring.bad { --c:var(--fail); }
.counts { display:grid; grid-template-columns:repeat(3,1fr); gap:16px; align-items:center; }
.count { text-align:center; font-weight:600; color:var(--muted); }
.count strong { display:block; font-size:34px; }
.count.pass strong { color:var(--pass); }
.count.warn strong { color:var(--warn); }
.count.fail strong { color:var(--fail); }
.changes-card { margin-bottom:16px; }
.changes-card ul { margin:0; padding-left:0; list-style:none; }
.changes-card li { padding:3px 0; }
.toolbar { display:flex; gap:8px; flex-wrap:wrap; margin:24px 0 12px; }
.toolbar button { border:1px solid #d1d5db; background:#fff; border-radius:6px;
                  padding:6px 12px; cursor:pointer; font:inherit; }
.toolbar button.active { background:#111827; color:#fff; border-color:#111827; }
.toolbar input { flex:1; min-width:200px; padding:6px 10px; border:1px solid #d1d5db;
                 border-radius:6px; font:inherit; }
.sections { display:grid; grid-template-columns:repeat(auto-fill,minmax(360px,1fr)); gap:16px; }
.sections ul { list-style:none; margin:0; padding:0; }
li.row { padding:6px 0; border-bottom:1px solid var(--line); word-break:break-word; }
.tag { display:inline-block; min-width:50px; text-align:center; border-radius:4px;
       color:#fff; font-size:11px; font-weight:700; padding:1px 6px; margin-right:8px; }
.tag.pass { background:var(--pass); } .tag.warn { background:var(--warn); }
.tag.fail { background:var(--fail); }
.pill { font-size:11px; padding:1px 8px; border-radius:999px; color:#fff; vertical-align:middle; }
.pill.pass { background:var(--pass); } .pill.warn { background:var(--warn); }
.pill.fail { background:var(--fail); }
.new { background:#2563eb; color:#fff; font-size:10px; padding:1px 5px; border-radius:4px; }
table { width:100%; border-collapse:collapse; }
th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); }
.bar { background:var(--line); border-radius:4px; height:8px; width:140px; }
.bar span { display:block; height:100%; background:var(--pass); border-radius:4px; }
.footnote { font-size:12px; margin-top:16px; }
.hidden { display:none !important; }
@media (max-width:700px) { .top { grid-template-columns:1fr; } main { padding:16px; } }
</style>
</head>
<body>
<header>
  <h1>Linux audit: @@HOST@@</h1>
  <p>@@OS@@ &middot; kernel @@KERNEL@@ &middot; generated @@GENERATED@@ &middot; @@PRIVS@@</p>
</header>
<main>
  <div class="top">
    <div class="card center">
      <div class="ring @@SCORECLASS@@" style="--p:@@SCORE@@"><span>@@SCORE@@</span></div>
      <p class="muted">Health score</p>
    </div>
    <div class="card counts">
      <div class="count pass"><strong>@@PASS@@</strong>PASS</div>
      <div class="count warn"><strong>@@WARN@@</strong>WARN</div>
      <div class="count fail"><strong>@@FAIL@@</strong>FAIL</div>
    </div>
  </div>

  <div class="card changes-card">
    <h2>Changes since last run</h2>
    @@CHANGES@@
  </div>

  <div class="toolbar">
    <button data-filter="all" class="active">All</button>
    <button data-filter="FAIL">Fail</button>
    <button data-filter="WARN">Warn</button>
    <button data-filter="PASS">Pass</button>
    <input id="search" type="search" placeholder="Search findings">
  </div>

  <div class="sections">@@SECTIONS@@</div>

  <div class="card" style="margin-top:16px">
    <h2>Score history</h2>
    <table>
      <tr><th>When</th><th>Host</th><th>Score</th><th>Fail</th><th>Warn</th><th>Trend</th></tr>
      @@HISTORY@@
    </table>
  </div>

  <p class="muted footnote">
    Score = (PASS + 0.5 &times; WARN) &divide; total checks in this run. It shows how many
    of this host's checks passed. It is not a benchmark or compliance score.
  </p>
</main>
<script>
const filterButtons = document.querySelectorAll('[data-filter]');
const search = document.getElementById('search');
let currentFilter = 'all';

function applyFilters() {
  const q = search.value.trim().toLowerCase();
  document.querySelectorAll('li.row').forEach(li => {
    const statusOk = currentFilter === 'all' || li.dataset.status === currentFilter;
    const textOk = !q || li.dataset.text.includes(q);
    li.classList.toggle('hidden', !(statusOk && textOk));
  });
  document.querySelectorAll('section[data-section]').forEach(sec => {
    const visible = sec.querySelectorAll('li.row:not(.hidden)').length;
    sec.classList.toggle('hidden', visible === 0);
  });
}

filterButtons.forEach(btn => btn.addEventListener('click', () => {
  currentFilter = btn.dataset.filter;
  filterButtons.forEach(b => b.classList.toggle('active', b === btn));
  applyFilters();
}));
search.addEventListener('input', applyFilters);
</script>
</body>
</html>
"""

# Single pass, so text from the results is never re-scanned for placeholders
page = re.sub(r"@@(\w+)@@", lambda m: values.get(m.group(1), ""), TEMPLATE)

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(page)
PY

rc=$?
if (( rc != 0 )); then
    fail "dashboard generation failed"
    exit 1
fi

echo -e "${GREEN}Dashboard written:${NORMAL} $out"
exit 0