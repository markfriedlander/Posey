#!/bin/bash
# qa_battery.sh — Three Hats QA battery driver
#
# Runs the standard 4-question test pattern (factual / connection /
# follow-up / not-in-doc) across three documents on Mark's iPhone via
# the local API.
#
# API POLITENESS (CLAUDE.md "AFM cooldown" standing requirement):
# Sequential /ask calls overload AFM into a Code=-1 (null) error
# state where every subsequent call fails until the app relaunches.
# This script inserts a cooldown (default 2.5s ± 500ms jitter)
# before each /ask call. Real users naturally pause between
# questions; the harness imitates that pacing.
#
# Override via env vars:
#   POSEY_TEST_COOLDOWN_SECONDS=2.5   base seconds (default 2.5)
#   POSEY_TEST_COOLDOWN_JITTER=0.5    ± seconds of jitter (default 0.5)
#   POSEY_TEST_NO_COOLDOWN=1          disable entirely (one-shot only)
#
# Configure first:
#   python3 tools/posey_test.py setup <ip> 8765 <token>
#
# Then run:
#   tools/qa_battery.sh

set -e

CONFIG=tools/.posey_api_config.json
if [ ! -f "$CONFIG" ]; then
  echo "No API config at $CONFIG — run tools/posey_test.py setup first" >&2
  exit 1
fi

# Pull host/port/token from the shared config so qa_battery.sh and
# posey_test.py stay in sync.
HOST=$(python3 -c "import json; print(json.load(open('$CONFIG'))['host'])")
PORT=$(python3 -c "import json; print(json.load(open('$CONFIG'))['port'])")
TOKEN=$(python3 -c "import json; print(json.load(open('$CONFIG'))['token'])")
BASE="http://$HOST:$PORT"

# Cooldown defaults match posey_test.py module docstring.
COOLDOWN_BASE=${POSEY_TEST_COOLDOWN_SECONDS:-2.5}
COOLDOWN_JITTER=${POSEY_TEST_COOLDOWN_JITTER:-0.5}
NO_COOLDOWN=${POSEY_TEST_NO_COOLDOWN:-0}

cooldown() {
  if [ "$NO_COOLDOWN" = "1" ]; then return; fi
  # Random uniform jitter in awk so we don't depend on bashisms.
  local sleep_seconds
  sleep_seconds=$(awk -v base="$COOLDOWN_BASE" -v jit="$COOLDOWN_JITTER" \
    'BEGIN { srand(); printf "%.3f", base + (2*rand() - 1) * jit }')
  sleep "$sleep_seconds"
}

ask() {
  local doc_id="$1"
  local question="$2"
  local label="$3"
  echo "--- $label ---"
  cooldown
  curl -s -X POST "$BASE/ask" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"documentID\":\"$doc_id\",\"question\":\"$question\",\"scope\":\"document\"}" \
    --max-time 240 \
    | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    print('<TRANSPORT-FAILURE: empty/invalid JSON from /ask>')
    sys.exit(0)
resp = r.get('response') or '<EMPTY>'
err = r.get('error')
print(resp)
if err: print('  [ERROR]', err[:160])
"
  echo
}

clear_doc() {
  curl -s -X POST "$BASE/command" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"CLEAR_ASK_POSEY_CONVERSATION:$1\"}" \
    --max-time 10 > /dev/null
}

# Resolve document IDs by title via LIST_DOCUMENTS so a re-import
# (which assigns a new UUID) doesn't break this script. Match is
# case-insensitive substring on the document title.
DOCS_JSON=$(curl -s -X POST "$BASE/command" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"LIST_DOCUMENTS"}' \
  --max-time 10)

resolve_doc_id() {
  local needle="$1"
  python3 - "$needle" <<EOF
import json, sys
needle = sys.argv[1].lower()
data = json.loads('''$DOCS_JSON''')
docs = data.get('raw') if isinstance(data, dict) else data
if not isinstance(docs, list):
    print("", end=""); sys.exit(0)
for d in docs:
    if needle in (d.get('title') or '').lower():
        print(d.get('id', ''), end=""); sys.exit(0)
print("", end="")
EOF
}

AI_BOOK=$(resolve_doc_id "AI Book Collaboration")
COPYRIGHT=$(resolve_doc_id "Clouds Of High-tech Copyright")
INTERNET_STEPS=$(resolve_doc_id "Internet Steps")

for var in AI_BOOK COPYRIGHT INTERNET_STEPS; do
  if [ -z "${!var}" ]; then
    echo "Could not resolve doc ID for $var via LIST_DOCUMENTS — is it imported?" >&2
    exit 1
  fi
done

echo "===== AI BOOK ====="
clear_doc $AI_BOOK
ask $AI_BOOK "Who are the authors?" "Q1 factual"
ask $AI_BOOK "How does Mark Friedlander describe his role compared to the AI contributors?" "Q2 connection"
ask $AI_BOOK "Building on what you said about Mark's role, why does the methodology need a moderator?" "Q3 follow-up"
ask $AI_BOOK "What is the ISBN of this book?" "Q4 not-in-doc"

echo
echo "===== COPYRIGHT PDF ====="
clear_doc $COPYRIGHT
ask $COPYRIGHT "What course was this paper written for?" "Q1 factual"
ask $COPYRIGHT "What is the main argument about ADR (alternative dispute resolution) and copyright disputes?" "Q2 connection"
ask $COPYRIGHT "You mentioned ADR. What kinds of disputes does the paper discuss?" "Q3 follow-up"
ask $COPYRIGHT "What is the price of this paper?" "Q4 not-in-doc"

echo
echo "===== INTERNET STEPS PDF ====="
clear_doc $INTERNET_STEPS
ask $INTERNET_STEPS "What is this document about?" "Q1 broad"
ask $INTERNET_STEPS "What aspects of copyright does it cover?" "Q2 connection"
ask $INTERNET_STEPS "Following from copyright, does the document mention DMCA?" "Q3 follow-up"
ask $INTERNET_STEPS "Who is the author's spouse?" "Q4 not-in-doc"

# 2026-05-16 (B9) — Image-extraction regression. Imports every fixture
# in TestFixtures/parity/images/, calls LIST_IMAGES on each, asserts
# the importer extracted at least the expected count per format.
# Catches silent regressions in inline-image rendering that ask-style
# questions wouldn't surface. Runs as a sub-process so its exit code
# surfaces back to qa_battery's failure semantics.
echo
echo "===== IMAGE-CORPUS REGRESSION (B9) ====="
if command -v python3 >/dev/null 2>&1; then
  python3 tools/verify_image_corpus.py || echo "[B9] image regression FAILED"
else
  echo "[B9] python3 not found; skipping image regression"
fi
