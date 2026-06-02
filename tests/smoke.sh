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
