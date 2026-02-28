#!/bin/bash
# entrypoint.sh
# Runs INSIDE the Vast.ai Docker container.
# Full pipeline: clone → download → train → backtest → gate → deploy → done
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

log() { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { log "❌ FAILED: $*"; exit 1; }

# ── Step 1: Clone repo ────────────────────────────────────────────────────────
log "=== [1/5] Cloning repository ==="
git clone --depth 1 "$REPO_URL" "$WORK_DIR" || fail "git clone failed"
cd "$WORK_DIR"

# ── Step 2: Download data ─────────────────────────────────────────────────────
log "=== [2/5] Downloading Kraken data ==="
log "Pairs: $PAIRS | Timeframe: $TIMEFRAME | Days: $TRAIN_DAYS"

IFS=',' read -ra PAIR_ARRAY <<< "$PAIRS"
for PAIR in "${PAIR_ARRAY[@]}"; do
  PAIR_CLEAN=$(echo "$PAIR" | tr '/' '_')
  log "Downloading $PAIR..."
  freqtrade download-data \
    --exchange kraken \
    --pairs "$PAIR" \
    --timeframes "$TIMEFRAME" \
    --days $(( TRAIN_DAYS + BACKTEST_DAYS + 7 )) \
    --datadir "$FREQTRADE_DIR/user_data/data" \
    2>&1 | tail -3
done

# ── Step 3: Train model ───────────────────────────────────────────────────────
log "=== [3/5] Training FreqAI $MODEL model ==="

# Select model type
if [ "$MODEL" = "lstm" ]; then
  MODEL_CLASS="PyTorchLSTMRegressor"
elif [ "$MODEL" = "cnn_transformer" ]; then
  MODEL_CLASS="PyTorchTransformerModel"
else
  MODEL_CLASS="LightGBMRegressor"
fi

log "Model class: $MODEL_CLASS"

freqtrade train-freqai \
  --config "$FREQTRADE_DIR/config.json" \
  --config "$FREQTRADE_DIR/config.freqai.json" \
  --strategy LightGBMStrategy \
  --freqai-model "$MODEL_CLASS" \
  --timerange "$(date -d "-${TRAIN_DAYS} days" '+%Y%m%d')-$(date '+%Y%m%d')" \
  --datadir "$FREQTRADE_DIR/user_data/data" \
  --userdir "$FREQTRADE_DIR/user_data" \
  2>&1 | grep -E "(Training|Epoch|Loss|RMSE|Finished|Error)" || true

log "Training complete."

# ── Step 4: Backtest ──────────────────────────────────────────────────────────
log "=== [4/5] Running backtest (last $BACKTEST_DAYS days) ==="

BACKTEST_END=$(date '+%Y%m%d')
BACKTEST_START=$(date -d "-${BACKTEST_DAYS} days" '+%Y%m%d')

freqtrade backtesting \
  --config "$FREQTRADE_DIR/config.json" \
  --config "$FREQTRADE_DIR/config.freqai.json" \
  --strategy LightGBMStrategy \
  --timerange "${BACKTEST_START}-${BACKTEST_END}" \
  --datadir "$FREQTRADE_DIR/user_data/data" \
  --userdir "$FREQTRADE_DIR/user_data" \
  --export trades \
  --export-filename "$FREQTRADE_DIR/user_data/backtest_results/last_backtest.json" \
  2>&1 | grep -E "(Backtesting|Wins|Losses|Sortino|Drawdown|Total)" || true

RESULT_FILE="$FREQTRADE_DIR/user_data/backtest_results/last_backtest.json"

if [ ! -f "$RESULT_FILE" ]; then
  fail "Backtest result file not found: $RESULT_FILE"
fi

# ── Step 5: Quality gate + deploy ─────────────────────────────────────────────
log "=== [5/5] Quality gate ==="

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
  exit 1
fi

log "=== Pipeline complete. Instance will terminate. ==="
