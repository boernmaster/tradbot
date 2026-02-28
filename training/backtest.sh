#!/bin/bash
# backtest.sh
# Runs a Freqtrade backtest and saves results for quality_gate.py.
# Called by entrypoint.sh after training.
#
# Required env vars:
#   BACKTEST_DAYS   Validation window in days (default: 30)
#   FREQTRADE_DIR   Path to freqtrade/ directory inside cloned repo
#
# Output:
#   $FREQTRADE_DIR/user_data/backtest_results/last_backtest.json
#
# TODO (Phase 2): Implement full backtest logic.

set -e

BACKTEST_DAYS="${BACKTEST_DAYS:-30}"
FREQTRADE_DIR="/app/tradbot/freqtrade"
RESULT_FILE="$FREQTRADE_DIR/user_data/backtest_results/last_backtest.json"

BACKTEST_END=$(date '+%Y%m%d')
BACKTEST_START=$(date -d "-${BACKTEST_DAYS} days" '+%Y%m%d')

echo "[backtest] Timerange: $BACKTEST_START-$BACKTEST_END"

freqtrade backtesting \
    --config "$FREQTRADE_DIR/config.json" \
    --config "$FREQTRADE_DIR/config.freqai.json" \
    --strategy LightGBMStrategy \
    --timerange "${BACKTEST_START}-${BACKTEST_END}" \
    --datadir "$FREQTRADE_DIR/user_data/data" \
    --userdir "$FREQTRADE_DIR/user_data" \
    --export trades \
    --export-filename "$RESULT_FILE" \
    2>&1 | grep -E "(Backtesting|Wins|Losses|Sortino|Drawdown|Total)" || true

if [ ! -f "$RESULT_FILE" ]; then
    echo "[backtest] ERROR: Result file not found: $RESULT_FILE"
    exit 1
fi

echo "[backtest] Results saved to: $RESULT_FILE"
