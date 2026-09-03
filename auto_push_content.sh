#!/bin/bash
# PACE BD Weekly Batch (Content dashboard) — auto-push script
# Picks up the finished index.html that Cowork saves locally and pushes it to
# GitHub if it contains a batch number newer than what's already live.
# Runs via launchd (see ~/Library/LaunchAgents/com.pace.bd-content-autopush.plist).
#
# This is the Content-dashboard sibling of the sports dashboard's
# auto_push.sh (~/pace-bd/Business-Development/auto_push.sh), adapted to
# this dashboard's simpler structure (no Swiss Events view to preserve).
# Same design principle: never trust Cowork's saved file as a whole. It is
# used ONLY as a source to extract three well-defined, always-present
# pieces:
#   1. the new batchN array(s)
#   2. the batchScanCounts + seedBatches lines
#   3. the Executive Summary paragraph
# Those three pieces are spliced into a fresh copy of the CURRENT LIVE file.
# Everything else on the page (favicon, CSS, branding, the Methodology
# section, anything else added to the dashboard over time) is taken ONLY
# from the live file and can never be touched by a batch push, no matter
# what template Cowork used to generate its file. If extraction of any
# piece fails, or the merged result is missing a protected feature, the run
# is refused and flagged for review rather than silently degrading the live
# site.

set -u

SOURCE="$HOME/pace-bd/inbox-content/index.html"
REPO="$HOME/pace-bd/Business-Development-Content"
LOG="$REPO/autopush.log"
MANUAL_FILE="$HOME/pace-bd/inbox-content/NEEDS_MANUAL_UPLOAD.html"
MANUAL_INSTR="$HOME/pace-bd/inbox-content/NEEDS_MANUAL_UPLOAD_INSTRUCTIONS.txt"
REVIEW_FILE="$HOME/pace-bd/inbox-content/REVIEW_NEEDED_invalid.html"
MERGED_FILE="/tmp/pace_content_autopush_merged.html"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

notify() {
  osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1
}

log "=== run start ==="

if [ ! -f "$SOURCE" ]; then
  log "No source file found at '$SOURCE' — nothing to do."
  exit 0
fi

cd "$REPO" || { log "ERROR: repo dir '$REPO' not found."; exit 1; }

if ! git diff --quiet || ! git diff --cached --quiet; then
  log "SKIPPED: uncommitted local changes present in '$REPO' — not touching them. Commit or stash before the next 15-min poll, or this run is simply skipped harmlessly."
  exit 0
fi

fetch_ok=true
if ! git fetch origin main -q; then
  fetch_ok=false
  log "WARNING: git fetch failed — will use last known local state to compare batch numbers."
else
  git checkout main -q
  git reset --hard origin/main -q
fi

repo_batch=$(grep -oE 'const batch[0-9]+ = \[' index.html | grep -oE '[0-9]+' | sort -n | tail -1)
src_batch=$(grep -oE 'const batch[0-9]+ = \[' "$SOURCE" | grep -oE '[0-9]+' | sort -n | tail -1)

if [ -z "$src_batch" ]; then
  log "Source file has no recognizable batchN array — skipping, not touching live."
  exit 0
fi

if [ -n "$repo_batch" ] && [ "$src_batch" -le "$repo_batch" ]; then
  log "No new batch (source=batch${src_batch:-none}, live=batch${repo_batch:-none}). Nothing to push."
  rm -f "$MANUAL_FILE" "$MANUAL_INSTR" "$REVIEW_FILE" "$MERGED_FILE" 2>/dev/null
  exit 0
fi

check=$(python3 - "$SOURCE" <<'PY'
import re, sys
content = open(sys.argv[1], encoding='utf-8').read()
blocks = re.findall(r'<script>(.*?)</script>', content, re.S)
js = "".join(blocks)
if not js.strip():
    print("NO_SCRIPT")
elif js.count('{') != js.count('}') or js.count('[') != js.count(']'):
    print("UNBALANCED")
else:
    print("OK")
PY
)

if [ "$check" != "OK" ]; then
  cp "$SOURCE" "$REVIEW_FILE"
  log "Source validation failed ($check) on batch ${src_batch} — NOT pushed. Copy saved for review at '$REVIEW_FILE'."
  notify "PACE BD Content batch ${src_batch}: content problem" "Source validation failed ($check) — not pushed. See REVIEW_NEEDED_invalid.html."
  exit 1
fi

extract_status="SKIPPED_FETCH_FAILED"
if $fetch_ok; then
  extract_status=$(python3 - "$SOURCE" "$REPO/index.html" "$MERGED_FILE" <<'PY'
import re, sys

src_path, live_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(src_path, encoding='utf-8').read()
live = open(live_path, encoding='utf-8').read()

errors = []

live_batches = set(int(n) for n in re.findall(r'const batch(\d+) = \[', live))
src_batches = set(int(n) for n in re.findall(r'const batch(\d+) = \[', src))
new_batches = sorted(src_batches - live_batches)
new_batch_blocks = ''
if not new_batches:
    errors.append('NO_NEW_BATCH_ARRAY_IN_SOURCE')
else:
    for n in new_batches:
        m = re.search(r'const batch%d = \[.*?\n\];\n' % n, src, re.S)
        if not m:
            errors.append(f'COULD_NOT_EXTRACT_BATCH_{n}')
        else:
            new_batch_blocks += m.group(0)

m_counts = re.search(r'const batchScanCounts = \{.*?\};[^\n]*\nconst seedBatches = \[.*?\];', src, re.S)
if not m_counts:
    errors.append('COULD_NOT_EXTRACT_COUNTS_LINES')

m_exec = re.search(r'<h2>Executive Summary</h2>\s*<p[^>]*>.*?</p>', src, re.S)
if not m_exec:
    errors.append('COULD_NOT_EXTRACT_EXEC_SUMMARY')

if errors:
    print('EXTRACT_FAIL:' + ','.join(errors))
    sys.exit(0)

def fix_dashes(text):
    text = re.sub(r'(?<=\S)[—–](?=\S)', '-', text)
    def colon_fix(m):
        return m.group(0).replace('—', ':').replace('–', ':').replace(' :', ':')
    text = re.sub(r"industry:'[^']*[—–][^']*'", colon_fix, text)
    text = re.sub(r"source:'[^']*[—–][^']*'", colon_fix, text)
    text = re.sub(r'\s[—–]\s', ', ', text)
    text = text.replace('—', ',').replace('–', ',')
    return text

new_batch_blocks = fix_dashes(new_batch_blocks)
exec_block = fix_dashes(m_exec.group(0))

merged = live

old_counts = re.search(r'const batchScanCounts = \{.*?\};[^\n]*\nconst seedBatches = \[.*?\];', merged, re.S)
if not old_counts:
    print('EXTRACT_FAIL:LIVE_COUNTS_LINE_NOT_FOUND')
    sys.exit(0)
merged = merged[:old_counts.start()] + new_batch_blocks + m_counts.group(0) + merged[old_counts.end():]

old_exec = re.search(r'<h2>Executive Summary</h2>\s*<p[^>]*>.*?</p>', merged, re.S)
if not old_exec:
    print('EXTRACT_FAIL:LIVE_EXEC_SUMMARY_NOT_FOUND')
    sys.exit(0)
merged = merged[:old_exec.start()] + exec_block + merged[old_exec.end():]

blocks = re.findall(r'<script>(.*?)</script>', merged, re.S)
js = ''.join(blocks)
if js.count('{') != js.count('}') or js.count('[') != js.count(']'):
    print('EXTRACT_FAIL:UNBALANCED_AFTER_MERGE')
    sys.exit(0)

if '—' in merged or '–' in merged:
    print('EXTRACT_FAIL:DASHES_SURVIVED_AUTO_FIX')
    sys.exit(0)

protected = [('rel="icon"', 'FAVICON'), ('reach-tick', 'REACH_TICK'),
             ('reachedOutIds', 'REACHED_OUT_IDS'), ('pace-service', 'PACE_SERVICE_CSS'),
             ('PACE Commercial Fit', 'COMMERCIAL_FIT_SECTION'),
             ('Qualification criteria', 'QUALIFICATION_CRITERIA_SECTION')]
missing = [label for marker, label in protected if merged.count(marker) == 0]
if missing:
    print('EXTRACT_FAIL:MISSING_AFTER_MERGE:' + ','.join(missing))
    sys.exit(0)

with open(out_path, 'w', encoding='utf-8') as f:
    f.write(merged)
print('OK')
PY
)
fi

if [ "$extract_status" != "OK" ]; then
  cp "$SOURCE" "$REVIEW_FILE"
  log "Extraction/merge failed for batch ${src_batch}: $extract_status — NOT pushed. Live site untouched. Source copy saved for review at '$REVIEW_FILE'."
  notify "PACE BD Content batch ${src_batch}: could not safely merge" "$extract_status — nothing pushed, live site untouched. See REVIEW_NEEDED_invalid.html and autopush.log."
  exit 1
fi

cp "$MERGED_FILE" "$REPO/index.html"
git add index.html
if git diff --cached --quiet; then
  log "Merged file but git sees no changes — nothing to commit."
  rm -f "$MERGED_FILE" 2>/dev/null
  exit 0
fi

if git commit -m "Weekly BD Content scan, batch ${src_batch}" -q && git push -q; then
  sha=$(git rev-parse --short HEAD)
  log "Pushed batch ${src_batch} successfully (commit ${sha}), merged onto the current live file — all existing features preserved."
  rm -f "$MANUAL_FILE" "$MANUAL_INSTR" "$REVIEW_FILE" "$MERGED_FILE" 2>/dev/null
  log "=== run end ==="
  exit 0
fi

cp "$MERGED_FILE" "$MANUAL_FILE"
cat > "$MANUAL_INSTR" <<EOF
Automatic push FAILED for Content batch ${src_batch} — likely a git auth or network issue.
Check autopush.log for the exact error. Common fix: re-run in Terminal:
  gh auth login --hostname github.com --git-protocol https --web

The file at $MANUAL_FILE already has batch ${src_batch}'s new content merged
onto the current live site (all existing features preserved) and is ready to
upload manually:

1. Go to https://github.com/noemie-PACE/Business-Development-Content
2. Open index.html, click the pencil (edit) icon
3. Select all, delete, paste in the full contents of the file above
4. Commit directly to main with message: Weekly BD Content scan, batch ${src_batch}

Once git access is working again, this will resolve itself automatically on
the next 15-minute check — no need to do anything else after a manual upload.
EOF
log "git push failed for batch ${src_batch} — left ready-to-upload (already merged) copy at '$MANUAL_FILE' and instructions at '$MANUAL_INSTR'."
notify "PACE BD Content batch ${src_batch}: auto-push failed" "Manual upload needed — ready file is in the Business Development Content folder (NEEDS_MANUAL_UPLOAD.html)."
exit 1
