#!/bin/bash
# vastai_search.sh
# Finds the cheapest available RTX 3090 instances on Vast.ai matching our filters.
# Use this to preview options before running vastai_train.sh.
#
# Usage:
#   ./scripts/vastai_search.sh
#   ./scripts/vastai_search.sh --limit 10
#
# TODO (Phase 2): Implement full search logic.

set -e

LIMIT="${2:-5}"
MIN_RAM_GB=16
MIN_DOWN_MBPS=200
MIN_DISK_GB=25

source "$(dirname "$0")/../.environment" 2>/dev/null || { echo "❌ .environment not found"; exit 1; }

vastai set api-key "$VASTAI_API_KEY" > /dev/null

echo "🔍 Searching for RTX 3090 instances (cheapest first)..."

vastai search offers \
    "gpu_name=RTX_3090 \
     rentable=true \
     num_gpus=1 \
     inet_down>$MIN_DOWN_MBPS \
     cpu_ram>$MIN_RAM_GB \
     disk_space>$MIN_DISK_GB \
     reliability>0.95 \
     cuda_vers>=12.0" \
    -o dph_total \
    --limit "$LIMIT" \
    | head -20

echo ""
echo "Run ./scripts/vastai_train.sh to provision the cheapest option."
