#!/bin/bash
# local_train.sh
# Run the full FreqAI training pipeline locally using the same Docker image
# as Vast.ai (ghcr.io/boernmaster/tradbot-training:latest).
# LightGBM trains on CPU — no GPU needed, ~5-15 min.
#
# Usage:
#   ./scripts/local_train.sh                       # download + train + quality gate
#   ./scripts/local_train.sh --no-download         # skip download, use existing data
#   ./scripts/local_train.sh --days 60             # training window (default: 90)
#   ./scripts/local_train.sh --backtest-days 30    # backtest window (default: 30)
#   ./scripts/local_train.sh --timerange 20260101-20260301
#   ./scripts/local_train.sh --pairs "BTC/USDT ETH/USDT"
#   ./scripts/local_train.sh --deploy              # rsync model to prod host if gate passes

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FT_DIR="$PROJECT_ROOT/freqtrade"
USERDIR="$FT_DIR/user_data"
ENV_FILE="$PROJECT_ROOT/.environment"

# Defaults
DOWNLOAD=true
DEPLOY=false
TRAIN_DAYS=90
BACKTEST_DAYS=30
TIMERANGE=""
PAIRS_OVERRIDE=""

# Load .environment
[ -f "$ENV_FILE" ] && source "$ENV_FILE" 2>/dev/null || true

IMAGE="${TRAINING_IMAGE:-ghcr.io/boernmaster/tradbot-training:latest}"
PAIRS="${KRAKEN_PAIRS:-BTC/USDT,ETH/USDT}"

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-download)   DOWNLOAD=false ;;
    --deploy)        DEPLOY=true ;;
    --days)          TRAIN_DAYS="$2"; shift ;;
    --backtest-days) BACKTEST_DAYS="$2"; shift ;;
    --timerange)     TIMERANGE="$2"; shift ;;
    --pairs)         PAIRS_OVERRIDE="$2"; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

[ -n "$PAIRS_OVERRIDE" ] && PAIRS="$PAIRS_OVERRIDE"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

PAIRS_SPACE=$(echo "$PAIRS" | tr ',' ' ')
PAIR_COUNT=$(echo "$PAIRS_SPACE" | wc -w | tr -d ' ')
TOTAL_DAYS=$(( TRAIN_DAYS + BACKTEST_DAYS + 7 ))

log "=== local_train.sh ==="
log "Image:    $IMAGE"
log "Pairs:    $PAIRS ($PAIR_COUNT)"
log "Training: ${TRAIN_DAYS}d  |  Backtest: ${BACKTEST_DAYS}d  |  Download: ${TOTAL_DAYS}d"
log "Download: $DOWNLOAD  |  Deploy: $DEPLOY"
echo ""

# Base docker run — mounts local configs and user_data into the container
DOCKER_RUN=(
  docker run --rm
  -v "$USERDIR:/freqtrade/user_data"
  -v "$FT_DIR/config.json:/freqtrade/config.json:ro"
  -v "$FT_DIR/config.freqai.json:/freqtrade/config.freqai.json:ro"
  -v "$FT_DIR/config.dev.json:/freqtrade/config.dev.json:ro"
  --workdir /freqtrade
  "$IMAGE"
)

# ── Step 1: Download data ─────────────────────────────────────────────────────
if [ "$DOWNLOAD" = "true" ]; then
  log "=== [1/3] Downloading Binance data ($TOTAL_DAYS days, $PAIR_COUNT pairs) ==="
  # shellcheck disable=SC2086
  "${DOCKER_RUN[@]}" freqtrade download-data \
    --config /freqtrade/config.json \
    --config /freqtrade/config.dev.json \
    --exchange binance \
    --pairs $PAIRS_SPACE \
    --timeframes 1h \
    --days "$TOTAL_DAYS" \
    --userdir /freqtrade/user_data
  log "✅ Data download complete"
else
  log "=== [1/3] Skipping data download (--no-download) ==="
fi

# ── Step 2: FreqAI walk-forward train + backtest ──────────────────────────────
if [ -z "$TIMERANGE" ]; then
  RANGE_END=$(date '+%Y%m%d')
  if date -d "-1 day" '+%Y%m%d' >/dev/null 2>&1; then
    RANGE_START=$(date -d "-$(( TRAIN_DAYS + BACKTEST_DAYS )) days" '+%Y%m%d')
  else
    RANGE_START=$(date -v-"$(( TRAIN_DAYS + BACKTEST_DAYS ))"d '+%Y%m%d')
  fi
  TIMERANGE="${RANGE_START}-${RANGE_END}"
fi

log "=== [2/3] FreqAI walk-forward train + backtest ==="
log "Timerange: $TIMERANGE  |  Model: LightGBMRegressor"
log "(Expect ~5-15 min on CPU)"
echo ""

"${DOCKER_RUN[@]}" freqtrade backtesting \
  --config /freqtrade/config.json \
  --config /freqtrade/config.freqai.json \
  --config /freqtrade/config.dev.json \
  --strategy LightGBMStrategy \
  --freqaimodel LightGBMRegressor \
  --timerange "$TIMERANGE" \
  --userdir /freqtrade/user_data \
  --export trades

echo ""
log "✅ Training + backtest complete"

# ── Step 3: Quality gate ──────────────────────────────────────────────────────
log "=== [3/3] Quality gate ==="

LAST_RESULT_PTR="$USERDIR/backtest_results/.last_result.json"
if [ ! -f "$LAST_RESULT_PTR" ]; then
  log "❌ No backtest result pointer: $LAST_RESULT_PTR"
  exit 1
fi

RESULT_FILENAME=$(python3 -c "import json; d=json.load(open('$LAST_RESULT_PTR')); print(d.get('latest_backtest',''))")
if [ -z "$RESULT_FILENAME" ]; then
  log "❌ Could not read latest_backtest from $LAST_RESULT_PTR"
  exit 1
fi

if [[ "$RESULT_FILENAME" = /* ]]; then
  RESULT_FILE="$RESULT_FILENAME"
else
  RESULT_FILE="$USERDIR/backtest_results/$RESULT_FILENAME"
fi

if [ ! -f "$RESULT_FILE" ]; then
  log "❌ Result file not found: $RESULT_FILE"
  exit 1
fi

log "Result: $RESULT_FILE"
echo ""

set +e
python3 "$PROJECT_ROOT/training/quality_gate.py" "$RESULT_FILE"
GATE_RESULT=$?
set -e

echo ""
if [ $GATE_RESULT -eq 0 ]; then
  log "✅ Quality gate PASSED"
  log "Model: $USERDIR/models"

  if [ "$DEPLOY" = "true" ]; then
    log "=== Deploying model to prod host ==="
    RASPI_HOST="${RASPI_HOST:-}"
    RASPI_USER="${RASPI_USER:-root}"
    RASPI_SSH_PORT="${RASPI_SSH_PORT:-22}"
    DATA_ROOT="${DATA_ROOT:-/mnt/ssd}"

    if [ -z "$RASPI_HOST" ]; then
      log "❌ RASPI_HOST not set in .environment"
      exit 1
    fi

    SSH_OPTS="-p $RASPI_SSH_PORT -o StrictHostKeyChecking=no -o ConnectTimeout=10"
    REMOTE="$RASPI_USER@$RASPI_HOST"
    REMOTE_MODEL_DIR="$DATA_ROOT/freqtrade/user_data/models/"

    log "Syncing models → $REMOTE:$REMOTE_MODEL_DIR"
    # shellcheck disable=SC2086
    rsync -az --delete -e "ssh $SSH_OPTS" "$USERDIR/models/" "$REMOTE:$REMOTE_MODEL_DIR"

    log "Restarting Freqtrade on prod host..."
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$REMOTE" \
      "docker compose -f /opt/tradbot/docker-compose.raspi.yml --env-file /opt/tradbot/.environment restart freqtrade 2>/dev/null || \
       docker compose -f ~/tradbot/docker-compose.raspi.yml --env-file ~/tradbot/.environment restart freqtrade"

    log "✅ Deployment complete"
  else
    log "Run with --deploy to push the model to the prod host."
  fi
else
  log "❌ Quality gate FAILED — model not deployed"
fi
