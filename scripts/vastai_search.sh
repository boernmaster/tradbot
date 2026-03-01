#!/bin/bash
# vastai_search.sh
# Finds the cheapest available GPU instances (RTX 3090/4080/4090) on Vast.ai.
# Use this to preview options before running vastai_train.sh.
#
# Usage:
#   ./scripts/vastai_search.sh
#   ./scripts/vastai_search.sh --limit 10
#
# TODO (Phase 2): Implement full search logic.

set -e

export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

LIMIT="${2:-5}"
MIN_RAM_GB=16
MIN_DOWN_MBPS=200
MIN_DISK_GB=25

source "$(dirname "$0")/../.environment" 2>/dev/null || { echo "❌ .environment not found"; exit 1; }

vastai set api-key "$VASTAI_API_KEY" > /dev/null

# gpu_ram>=16 + total_flops>=12 excludes P100 (~10 TFLOPS) and below.
# Targets V100 (12.5), A100 (15.6), RTX 3090 (35), RTX 4090 (82) etc.
echo "🔍 Searching for GPU instances (≥16GB VRAM, ≥12 TFLOPS, CUDA 12+, cheapest first)..."

vastai search offers \
    "rentable=true \
     num_gpus=1 \
     gpu_ram>=16 \
     total_flops>=12 \
     inet_down>$MIN_DOWN_MBPS \
     cpu_ram>$MIN_RAM_GB \
     disk_space>$MIN_DISK_GB \
     reliability>0.95 \
     cuda_vers>=12.0" \
    -o dph_total \
    --limit "$LIMIT" \
    | head -30

echo ""
echo "Run ./scripts/vastai_train.sh to provision the cheapest option."
