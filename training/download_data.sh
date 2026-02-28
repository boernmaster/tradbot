#!/bin/bash
# download_data.sh
# Downloads Kraken OHLCV data for training and backtesting.
# Runs inside the Vast.ai training container (called by entrypoint.sh).
#
# Required env vars:
#   KRAKEN_PAIRS    Comma-separated pairs, e.g. BTC/USDT,ETH/USDT
#   TRAIN_DAYS      Training window in days (default: 90)
#   BACKTEST_DAYS   Backtest window in days (default: 30)
#   TIMEFRAME       Candle size (default: 1h)
#
# TODO (Phase 2): Implement full download logic.

set -e

PAIRS="${KRAKEN_PAIRS:-BTC/USDT,ETH/USDT}"
TOTAL_DAYS=$(( ${TRAIN_DAYS:-90} + ${BACKTEST_DAYS:-30} + 7 ))
TIMEFRAME="${TIMEFRAME:-1h}"
FREQTRADE_DIR="/app/tradbot/freqtrade"

echo "[download_data] Pairs: $PAIRS | Days: $TOTAL_DAYS | Timeframe: $TIMEFRAME"

IFS=',' read -ra PAIR_ARRAY <<< "$PAIRS"
for PAIR in "${PAIR_ARRAY[@]}"; do
    echo "[download_data] Downloading $PAIR..."
    freqtrade download-data \
        --exchange kraken \
        --pairs "$PAIR" \
        --timeframes "$TIMEFRAME" \
        --days "$TOTAL_DAYS" \
        --datadir "$FREQTRADE_DIR/user_data/data"
done

echo "[download_data] Done."
