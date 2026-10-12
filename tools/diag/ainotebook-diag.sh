#!/bin/bash
# Read-only diagnostics for a stuck folder indexing run (macOS).
# Writes ~/Desktop/ainotebook-diag.txt. No document text, chats or API keys are read.
DB="$HOME/Library/Application Support/AINotebook/db.sqlite"
OUT="$HOME/Desktop/ainotebook-diag.txt"
q() { sqlite3 -readonly -header -column "$DB" "$1" 2>&1; echo; }
{
echo "== app"
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "/Applications/AI Notebook.app/Contents/Info.plist" 2>&1
date; echo "now_s=$(date +%s)"
ps -axo pid,etime,%cpu,%mem,rss,command | grep -i "[A]INotebookApp"
echo
echo "== ollama"
curl -s -m 3 http://127.0.0.1:11434/api/version; echo
curl -s -m 3 http://127.0.0.1:11434/api/ps | head -c 600; echo; echo
echo "== jobs by kind/state"
q "SELECT kind, state, count(*) n, max(attempts) max_att, min(next_retry_at) min_retry, max(lease_until) max_lease FROM ingest_jobs GROUP BY kind, state ORDER BY kind, state;"
echo "== unfinished jobs (oldest 40)"
q "SELECT id, kind, target, state, attempts, next_retry_at, lease_until, error, substr(options_json,1,80) opts FROM ingest_jobs WHERE state IN ('queued','running','paused') ORDER BY id LIMIT 40;"
echo "== last 30 failed/cancelled jobs"
q "SELECT id, kind, target, state, attempts, error FROM ingest_jobs WHERE state IN ('failed','cancelled') ORDER BY id DESC LIMIT 30;"
echo "== error codes"
q "SELECT kind, state, error, count(*) n FROM ingest_jobs WHERE error IS NOT NULL GROUP BY kind, state, error ORDER BY n DESC LIMIT 30;"
echo "== folders"
q "SELECT id, notebook_id, display_name, watch_enabled, scan_state, scan_generation, last_full_scan_at, last_scan_error FROM folder_sources;"
echo "== sources by notebook/status"
q "SELECT notebook_id, status, count(*) n FROM sources GROUP BY notebook_id, status ORDER BY notebook_id, status;"
q "SELECT error, count(*) n FROM sources WHERE status='error' GROUP BY error ORDER BY n DESC;"
echo "== index generations"
q "SELECT id, notebook_id, provider_id, model, dims, state, created_at, activated_at FROM index_generations ORDER BY id DESC LIMIT 15;"
q "SELECT generation_id, state, count(*) n FROM index_generation_manifest GROUP BY generation_id, state ORDER BY generation_id DESC LIMIT 30;"
q "SELECT generation_id, count(*) embedded_chunks FROM chunk_embeddings GROUP BY generation_id ORDER BY generation_id DESC LIMIT 10;"
echo "== providers (no keys)"
q "SELECT id, type, name, base_url, enabled, privacy_acknowledged FROM providers;"
echo "== chunk totals"
q "SELECT count(*) chunks FROM source_chunks;"
echo "== process sample (top of stack)"
PID=$(pgrep -x AINotebookApp | head -1)
if [ -n "$PID" ]; then
  sample "$PID" 5 -file /tmp/ainotebook-sample.txt >/dev/null 2>&1
  sed -n '/Sort by top of stack/,$p' /tmp/ainotebook-sample.txt | head -60
  echo "-- main thread"
  grep -m1 -A40 "Thread_.*DispatchQueue_1: com.apple.main-thread" /tmp/ainotebook-sample.txt | cut -c1-160
else
  echo "app not running"
fi
} > "$OUT" 2>&1
echo "Hotovo: $OUT ($(wc -l < "$OUT") řádků)"
