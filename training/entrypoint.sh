#!/bin/bash
# entrypoint.sh
# Runs INSIDE the Vast.ai Docker container.
# Full pipeline: clone → download → train+backtest (walk-forward) → gate → deploy → done
# The Vast.ai instance terminates when this script exits.

set -e

REPO_URL="https://github.com/boernmaster/tradbot.git"
WORK_DIR="/app/tradbot"
FREQTRADE_DIR="$WORK_DIR/freqtrade"
MODEL=${TRAINING_MODEL:-lightgbm}
TRAIN_DAYS=${TRAIN_DAYS:-90}
BACKTEST_DAYS=${BACKTEST_DAYS:-30}
PAIRS=${KRAKEN_PAIRS:-BTC/USDT,ETH/USDT}
TIMEFRAME="1h"
TRAINING_EXCHANGE=${TRAINING_EXCHANGE:-binance}  # binance=fast (no --dl-trades); kraken=slow but production-accurate

log() { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { log "❌ FAILED: $*"; self_terminate; exit 1; }

self_terminate() {
  # Destroy this Vast.ai instance via the API so billing stops immediately.
  # Finds our own instance by querying all running instances for this API key.
  if [ -z "$VASTAI_API_KEY" ]; then return; fi
  log "Destroying Vast.ai instance via API..."
  INSTANCE_ID=$(curl -sf "https://console.vast.ai/api/v0/instances/?api_key=$VASTAI_API_KEY" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
instances = data.get('instances', [])
running = [i for i in instances if i.get('actual_status') == 'running']
print(running[0]['id'] if running else '')
" 2>/dev/null || true)
  if [ -n "$INSTANCE_ID" ]; then
    curl -sf -X DELETE "https://console.vast.ai/api/v0/instances/$INSTANCE_ID/?api_key=$VASTAI_API_KEY" > /dev/null && \
      log "✅ Instance $INSTANCE_ID destroyed." || \
      log "⚠ Could not destroy instance (will expire on its own)."
  fi
}

# ── Step 1: Clone repo ────────────────────────────────────────────────────────
log "=== [1/4] Cloning repository ==="
git clone --depth 1 "$REPO_URL" "$WORK_DIR" || fail "git clone failed"
cd "$WORK_DIR"

# ── Step 2: Download data ─────────────────────────────────────────────────────
TOTAL_DAYS=$(( TRAIN_DAYS + BACKTEST_DAYS + 7 ))  # +7 buffer for FreqAI warmup

IFS=',' read -ra PAIR_ARRAY <<< "$PAIRS"
PAIR_COUNT=${#PAIR_ARRAY[@]}

log "=== [2/4] Downloading $TRAINING_EXCHANGE data ==="
log "Exchange: $TRAINING_EXCHANGE | Timeframe: $TIMEFRAME | Days: $TOTAL_DAYS | Pairs: $PAIR_COUNT"

PAIR_IDX=0
for PAIR in "${PAIR_ARRAY[@]}"; do
  PAIR_IDX=$(( PAIR_IDX + 1 ))
  log "  [$PAIR_IDX/$PAIR_COUNT] $PAIR — fetching ${TOTAL_DAYS}d of ${TIMEFRAME} candles..."
  EXTRA_OPTS=""
  [[ "$TRAINING_EXCHANGE" = "kraken" ]] && EXTRA_OPTS="--dl-trades"

  # shellcheck disable=SC2086
  freqtrade download-data \
    --exchange "$TRAINING_EXCHANGE" \
    --pairs "$PAIR" \
    --timeframes "$TIMEFRAME" \
    --days "$TOTAL_DAYS" \
    --userdir "$FREQTRADE_DIR/user_data" \
    $EXTRA_OPTS \
    2>&1 | grep -E "(Download|Downloading|rows|candles|Skipping|up to date|Done|ERROR)" \
         | sed "s/^/    /" \
    || true
done
log "  ✅ Data download complete ($PAIR_COUNT pairs)"

# ── Step 3: Select model class ────────────────────────────────────────────────
if [ "$MODEL" = "lstm" ]; then
  MODEL_CLASS="PyTorchLSTMRegressor"
elif [ "$MODEL" = "cnn_transformer" ]; then
  MODEL_CLASS="PyTorchTransformerModel"
else
  MODEL_CLASS="LightGBMRegressor"
fi

log "Model class: $MODEL_CLASS"

# ── Step 4: FreqAI walk-forward train + backtest ──────────────────────────────
# FreqAI trains a new model for each backtest_period_days window over the full
# timerange. Training happens implicitly inside freqtrade backtesting.
# No separate train-freqai step needed.
log "=== [3/4] FreqAI walk-forward train + backtest ($MODEL_CLASS) ==="
log "Training window: ${TRAIN_DAYS}d | Backtest validation: ${BACKTEST_DAYS}d"

RANGE_END=$(date '+%Y%m%d')
RANGE_START=$(date -d "-$(( TRAIN_DAYS + BACKTEST_DAYS )) days" '+%Y%m%d')

# Build config list — add exchange override when not using Kraken
CONFIG_ARGS=(
  --config "$FREQTRADE_DIR/config.json"
  --config "$FREQTRADE_DIR/config.freqai.json"
)

if [[ "$TRAINING_EXCHANGE" != "kraken" ]]; then
  OVERRIDE_CFG="/tmp/exchange_override.json"
  echo "{\"exchange\": {\"name\": \"$TRAINING_EXCHANGE\", \"key\": \"\", \"secret\": \"\"}}" > "$OVERRIDE_CFG"
  CONFIG_ARGS+=(--config "$OVERRIDE_CFG")
  log "Exchange override: using $TRAINING_EXCHANGE data"
fi

log "Timerange: ${RANGE_START} → ${RANGE_END} | Pairs: $PAIR_COUNT | Model: $MODEL_CLASS"

freqtrade backtesting \
  "${CONFIG_ARGS[@]}" \
  --strategy LightGBMStrategy \
  --freqaimodel "$MODEL_CLASS" \
  --timerange "${RANGE_START}-${RANGE_END}" \
  --userdir "$FREQTRADE_DIR/user_data" \
  --export trades \
  2>&1 | grep -E "(Training new model|Training model|training for pair|Populating indicators|Loading data for|Backtesting|walk.forward|Starting training|Wins|Losses|Sortino|Drawdown|Total profit|RMSE|Finished|ERROR)" \
  | grep -v "^$" \
  | sed 's/^[0-9-]* [0-9:]* - freqai[^ ]* - [A-Z]* - /  [freqai] /' \
  | sed 's/^[0-9-]* [0-9:]* - [^ ]* - INFO - /  /' \
  | sed 's/^[0-9-]* [0-9:]* - [^ ]* - WARNING - /  ⚠ /' \
  || true

# Discover the result file via Freqtrade's pointer file
LAST_RESULT_PTR="$FREQTRADE_DIR/user_data/backtest_results/.last_result.json"
if [ ! -f "$LAST_RESULT_PTR" ]; then
  fail "No backtest result pointer found: $LAST_RESULT_PTR (backtesting may have failed)"
fi

RESULT_FILENAME=$(python3 -c "import json; d=json.load(open('$LAST_RESULT_PTR')); print(d.get('latest_backtest',''))")
if [ -z "$RESULT_FILENAME" ]; then
  fail "Could not parse latest_backtest from $LAST_RESULT_PTR"
fi

# Resolve to absolute path (Freqtrade stores relative filename)
if [[ "$RESULT_FILENAME" = /* ]]; then
  RESULT_FILE="$RESULT_FILENAME"
else
  RESULT_FILE="$FREQTRADE_DIR/user_data/backtest_results/$RESULT_FILENAME"
fi

if [ ! -f "$RESULT_FILE" ]; then
  fail "Backtest result file not found: $RESULT_FILE"
fi

log "Backtest result: $RESULT_FILE"

# ── Step 4: Quality gate + deploy ─────────────────────────────────────────────
log "=== [4/4] Quality gate ==="

set +e
python3 "$WORK_DIR/training/quality_gate.py" "$RESULT_FILE"
GATE_RESULT=$?
set -e

if [ $GATE_RESULT -eq 0 ]; then
  log "✅ Quality gate PASSED. Deploying to prod host ($RASPI_HOST)..."
  bash "$WORK_DIR/training/deploy_model.sh"
  log "✅ Deployment complete."
else
  log "❌ Quality gate FAILED. Model not deployed."
  log "Review backtest results before deploying manually."
fi

log "=== Pipeline complete. ==="
self_terminate
