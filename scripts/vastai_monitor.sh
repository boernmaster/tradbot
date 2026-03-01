#!/bin/bash
# vastai_monitor.sh
# Monitor running Vast.ai training instances.
#
# Usage:
#   ./scripts/vastai_monitor.sh              # one-shot status
#   ./scripts/vastai_monitor.sh --watch      # refresh every 30s
#   ./scripts/vastai_monitor.sh --logs       # tail logs of first running instance
#   ./scripts/vastai_monitor.sh --logs 32185542  # tail logs of specific instance
#   ./scripts/vastai_monitor.sh --destroy    # destroy first running instance
#   ./scripts/vastai_monitor.sh --destroy 32185542  # destroy specific instance

set -e

export PATH="$HOME/bin:$HOME/.local/bin:$PATH"
VENV_VASTAI="/volume1/docker/tradbot/.venv/bin/vastai"
VASTAI="${VENV_VASTAI:-vastai}"

source "$(dirname "$0")/../.environment" 2>/dev/null || { echo "❌ .environment not found"; exit 1; }

if [ -z "$VASTAI_API_KEY" ]; then
  echo "❌ VASTAI_API_KEY not set in .environment"
  exit 1
fi

WATCH=false
LOGS=false
DESTROY=false
TARGET_INSTANCE=""

for arg in "$@"; do
  case "$arg" in
    --watch)   WATCH=true ;;
    --logs)    LOGS=true ;;
    --destroy) DESTROY=true ;;
    [0-9]*)    TARGET_INSTANCE="$arg" ;;
  esac
done

# ── Resolve first running instance if no ID given ────────────────────────────
get_first_instance() {
  curl -sf "https://console.vast.ai/api/v0/instances/?api_key=$VASTAI_API_KEY" \
    | python3 -c "
import json, sys
instances = json.load(sys.stdin).get('instances', [])
running = [i for i in instances if i.get('actual_status') == 'running']
print(running[0]['id'] if running else '')
" 2>/dev/null
}

# ── Destroy mode ──────────────────────────────────────────────────────────────
if [ "$DESTROY" = "true" ]; then
  if [ -z "$TARGET_INSTANCE" ]; then
    TARGET_INSTANCE=$(get_first_instance)
  fi
  if [ -z "$TARGET_INSTANCE" ]; then
    echo "❌ No running instance found"
    exit 1
  fi
  echo "⚠️  Destroying instance $TARGET_INSTANCE (irreversible)..."
  $VASTAI destroy instance "$TARGET_INSTANCE" --api-key "$VASTAI_API_KEY"
  echo "✅ Instance $TARGET_INSTANCE destroyed."
  exit 0
fi

# ── Log tail mode ─────────────────────────────────────────────────────────────
if [ "$LOGS" = "true" ]; then
  if [ -z "$TARGET_INSTANCE" ]; then
    TARGET_INSTANCE=$(get_first_instance)
  fi

  if [ -z "$TARGET_INSTANCE" ]; then
    echo "❌ No running instance found"
    exit 1
  fi

  echo "📋 Tailing logs for instance $TARGET_INSTANCE (Ctrl+C to stop)..."
  while true; do
    $VASTAI logs "$TARGET_INSTANCE" --tail 20 2>/dev/null || true
    sleep 15
    echo "── $(date '+%H:%M:%S') ──────────────────────────────────────────────"
  done
  exit 0
fi

# ── Status display ────────────────────────────────────────────────────────────
show_status() {
  local NOW
  NOW=$(date +%s)

  local RAW
  RAW=$(curl -sf "https://console.vast.ai/api/v0/instances/?api_key=$VASTAI_API_KEY")

  local COUNT
  COUNT=$(echo "$RAW" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('instances',[])))")

  echo "╔══════════════════════════════════════════════════════════════════════╗"
  printf "║  Vast.ai Monitor  %-20s  %27s  ║\n" "" "$(date '+%Y-%m-%d %H:%M:%S')"
  echo "╠══════════════════════════════════════════════════════════════════════╣"

  if [ "$COUNT" -eq 0 ]; then
    echo "║  No running instances.                                               ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    return
  fi

  echo "$RAW" | python3 -c "
import json, sys, time

data = json.load(sys.stdin)
instances = data.get('instances', [])
now = $NOW

for i in instances:
    iid        = i.get('id', '?')
    status     = i.get('actual_status', '?')
    gpu        = i.get('gpu_name', '?')
    location   = i.get('geolocation', '?')
    dph        = i.get('dph_total', 0) or 0
    start      = i.get('start_date') or now
    elapsed_s  = now - start
    elapsed_m  = int(elapsed_s / 60)
    elapsed_h  = elapsed_s / 3600
    cost       = dph * elapsed_h
    image      = (i.get('image_uuid') or '')[:40]

    status_icon = '🟢' if status == 'running' else '🔴'

    print(f'║  {status_icon} Instance {iid:<10} {status:<10}                                  ║')
    print(f'║     GPU:      {gpu:<55} ║')
    print(f'║     Location: {location:<55} ║')
    print(f'║     Image:    {image:<55} ║')
    print(f'║     Elapsed:  {elapsed_m} min                                               ║')
    print(f'║     Cost:     €{cost:.3f} (€{dph:.4f}/hr)                                  ║')
    print( '╠══════════════════════════════════════════════════════════════════════╣')
" 2>/dev/null

  echo "╚══════════════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Commands:"
  echo "    Logs:    ./scripts/vastai_monitor.sh --logs [instance_id]"
  echo "    Destroy: ./scripts/vastai_monitor.sh --destroy [instance_id]"
}

# ── Watch loop ────────────────────────────────────────────────────────────────
if [ "$WATCH" = "true" ]; then
  echo "👁  Watching Vast.ai instances (refresh every 30s, Ctrl+C to stop)..."
  while true; do
    clear
    show_status
    sleep 30
  done
else
  show_status
fi
