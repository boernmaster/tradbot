#!/bin/bash
# train.sh
# Runs FreqAI model training on the Vast.ai GPU instance.
# Called by entrypoint.sh after data download.
#
# Required env vars:
#   TRAINING_MODEL   lightgbm | lstm | cnn_transformer (default: lightgbm)
#   TRAIN_DAYS       Training window in days (default: 90)
#   FREQTRADE_DIR    Path to freqtrade/ directory inside cloned repo
#
# TODO (Phase 2): Implement full training logic.

set -e

MODEL="${TRAINING_MODEL:-lightgbm}"
TRAIN_DAYS="${TRAIN_DAYS:-90}"
FREQTRADE_DIR="/app/signal-trader/freqtrade"

case "$MODEL" in
    lstm)            MODEL_CLASS="PyTorchLSTMRegressor" ;;
    cnn_transformer) MODEL_CLASS="PyTorchTransformerModel" ;;
    *)               MODEL_CLASS="LightGBMRegressor" ;;
esac

TIMERANGE_START=$(date -d "-${TRAIN_DAYS} days" '+%Y%m%d')
TIMERANGE_END=$(date '+%Y%m%d')

echo "[train] Model class: $MODEL_CLASS"
echo "[train] Timerange: $TIMERANGE_START-$TIMERANGE_END"

freqtrade train-freqai \
    --config "$FREQTRADE_DIR/config.json" \
    --config "$FREQTRADE_DIR/config.freqai.json" \
    --strategy LightGBMStrategy \
    --freqai-model "$MODEL_CLASS" \
    --timerange "${TIMERANGE_START}-${TIMERANGE_END}" \
    --datadir "$FREQTRADE_DIR/user_data/data" \
    --userdir "$FREQTRADE_DIR/user_data" \
    2>&1 | grep -E "(Training|Epoch|Loss|RMSE|Finished|Error)" || true

echo "[train] Training complete."
