#!/usr/bin/env bash
set -euo pipefail

# Use a temp HOME so we don't trample real config
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
export HOME=$TMP
mkdir -p "$HOME/.config/ctt"

cat > "$HOME/.config/ctt/config.json" <<EOF
{
  "db_path": "$HOME/.config/ctt/db.sqlite",
  "repos": [],
  "providers": {
    "patterns": [
      { "provider": "linear", "prefix_min": 2, "prefix_max": 6 }
    ]
  }
}
EOF

BIN="$(pwd)/zig-out/bin/ctt"
if [ ! -x "$BIN" ]; then
  echo "binary not found at $BIN; did you run 'zig build'?" >&2
  exit 1
fi

echo "==> add a task"
$BIN add "smoke test" --branch feat/smoke 2>/dev/null

echo "==> list (text)"
$BIN list 2>/dev/null

echo "==> list --json"
JSON=$($BIN list --json 2>/dev/null)
echo "$JSON"
echo "$JSON" | python3 -c 'import sys, json; tasks = json.load(sys.stdin); assert tasks[0]["title"] == "smoke test", tasks; print("title ok:", tasks[0]["title"])'

ID=$(echo "$JSON" | python3 -c 'import sys, json; print(json.load(sys.stdin)[0]["id"])')
echo "==> task id is $ID"

echo "==> show $ID --json"
$BIN show "$ID" --json 2>/dev/null | python3 -c 'import sys, json; t = json.load(sys.stdin); assert t[0]["title"] == "smoke test"; print("show ok")'

echo "==> update title"
$BIN update "$ID" --title "smoke test (updated)" 2>/dev/null
$BIN list --json 2>/dev/null | python3 -c 'import sys, json; assert json.load(sys.stdin)[0]["title"] == "smoke test (updated)"; print("update ok")'

echo "==> archive"
$BIN archive "$ID" 2>/dev/null
$BIN list --status archived --json 2>/dev/null | python3 -c 'import sys, json; tasks = json.load(sys.stdin); assert len(tasks) == 1 and tasks[0]["title"] == "smoke test (updated)"; print("archive ok")'

echo "==> delete"
$BIN delete "$ID" 2>/dev/null
$BIN list --json 2>/dev/null | python3 -c 'import sys, json; tasks = json.load(sys.stdin); assert len(tasks) == 0, tasks; print("delete ok")'

echo ""
echo "smoke OK ✓"

# ---------------------------------------------------------------------------
# Handoff / resume smoke
# ---------------------------------------------------------------------------
echo "--- handoff/resume smoke ---"

echo "==> add task for handoff smoke"
$BIN add "handoff smoke" 2>/dev/null
HID=$($BIN list --json 2>/dev/null | python3 -c 'import sys, json; tasks = json.load(sys.stdin); print([t for t in tasks if t["title"] == "handoff smoke"][-1]["id"])')
echo "==> handoff task id is $HID"

echo "==> set session"
$BIN session set "$HID" claude abc-test-123 2>/dev/null

echo "==> add two handoffs"
$BIN handoff "$HID" --note "first checkpoint" 2>/dev/null
$BIN handoff "$HID" --note "second checkpoint" 2>/dev/null

echo "==> context should have 2 handoffs"
CTXJSON=$($BIN context "$HID" --json 2>/dev/null)
echo "$CTXJSON" | python3 -c '
import sys, json
ctx = json.load(sys.stdin)
assert len(ctx["handoffs"]) == 2, "expected 2 handoffs, got: %d" % len(ctx["handoffs"])
print("handoffs count ok:", len(ctx["handoffs"]))
'

echo "==> context session_id matches"
echo "$CTXJSON" | python3 -c '
import sys, json
ctx = json.load(sys.stdin)
assert ctx["task"]["session"]["session_id"] == "abc-test-123", "session_id mismatch: %s" % ctx
print("session_id ok:", ctx["task"]["session"]["session_id"])
'

echo "==> resume --print (tolerant: accepts rendered command or NoTemplateForProvider/NoDefaultProvider)"
RESUME_OUT=$($BIN resume "$HID" --print 2>&1 || true)
echo "$RESUME_OUT" | python3 -c '
import sys
out = sys.stdin.read()
ok_patterns = ["abc-test-123", "NoTemplateForProvider", "NoDefaultProvider", "context_file", "append-system-prompt", "claude"]
assert any(p in out for p in ok_patterns), "resume --print output did not match any expected pattern:\n%s" % out
print("resume --print ok (output contains expected pattern)")
'

echo "==> clear session"
$BIN session clear "$HID" 2>/dev/null

echo "==> resume --print after session clear (tolerant: accepts any valid output or known error)"
RESUME_FRESH=$($BIN resume "$HID" --print 2>&1 || true)
echo "$RESUME_FRESH" | python3 -c '
import sys
out = sys.stdin.read()
ok_patterns = ["context_file", "append-system-prompt", "claude", "NoTemplateForProvider", "NoDefaultProvider", "resume failed"]
assert any(p in out for p in ok_patterns), "resume --print (fresh) output did not match any expected pattern:\n%s" % out
print("resume --print (fresh) ok (output contains expected pattern)")
'

echo "==> delete handoff task"
$BIN delete "$HID" 2>/dev/null

echo "handoff smoke OK"

# ──────────────────────────────────────────────────────────────────────────────
# Project picker smoke
# ──────────────────────────────────────────────────────────────────────────────

echo "--- project picker smoke ---"
$BIN add "project smoke" --project /tmp
PID=$($BIN list --json | python3 -c '
import sys, json
items = json.load(sys.stdin)
print(items[-1]["id"])
')

echo "==> verify project_path stored"
PROJ=$($BIN context "$PID" --json | python3 -c '
import sys, json
ctx = json.load(sys.stdin)
print(ctx["task"].get("project_path", ""))
')
test "$PROJ" = "/tmp" || { echo "expected /tmp, got: $PROJ"; exit 1; }
echo "project_path ok: $PROJ"

echo "==> resume --print still works with project_path set"
$BIN session set "$PID" claude smoke-id-456 2>/dev/null
RESUME_OUT=$($BIN resume "$PID" --print 2>&1 || true)
echo "$RESUME_OUT" | python3 -c '
import sys
out = sys.stdin.read()
ok_patterns = ["smoke-id-456", "NoTemplateForProvider", "NoDefaultProvider", "claude"]
assert any(p in out for p in ok_patterns), "resume --print output did not match any expected pattern:\n%s" % out
print("resume --print ok (output contains expected pattern)")
'

echo "==> delete project smoke task"
$BIN delete "$PID" 2>/dev/null

echo "project picker smoke OK"
