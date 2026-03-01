#!/bin/bash
# vastai_train.sh
# Provisions a Vast.ai GPU instance (RTX 3090/4080/4090), runs the full training
# pipeline, deploys model to prod host if quality gate passes, then self-terminates.
#
# Usage:
#   ./scripts/vastai_train.sh
#   ./scripts/vastai_train.sh --model lstm   (default: lightgbm)
#   ./scripts/vastai_train.sh --dry-run      (search only, don't provision)

set -e

export PATH="$HOME/bin:$HOME/.local/bin:$PATH"

# ── Config ────────────────────────────────────────────────────────────────────
MODEL=${1:-lightgbm}
SEARCH_ONLY=false
[[ "$*" == *"--dry-run"* ]] && SEARCH_ONLY=true
[[ "$*" == *"--model"* ]] && MODEL=$(echo "$*" | grep -oP '(?<=--model )\S+')

DOCKER_IMAGE="ghcr.io/boernmaster/tradbot-training:latest"
DISK_GB=25
MIN_RAM_GB=16
MIN_DOWN_MBPS=200

source "$(dirname "$0")/../.environment" 2>/dev/null || { echo "❌ .environment file not found"; exit 1; }

if [ -z "$VASTAI_API_KEY" ]; then
  echo "❌ VASTAI_API_KEY not set. Add it to .env"
  exit 1
fi

vastai set api-key "$VASTAI_API_KEY" > /dev/null

# ── Search for instance ───────────────────────────────────────────────────────
# gpu_ram>=16 + total_flops>=12 excludes P100 (~10 TFLOPS) and below.
# Targets V100 (12.5), A100 (15.6), RTX 3090 (35), RTX 4090 (82) etc.
echo "🔍 Searching for cheapest GPU (≥16GB VRAM, ≥12 TFLOPS, CUDA 12+)..."

OFFER=$(vastai search offers \
  "rentable=true \
   num_gpus=1 \
   gpu_ram>=16 \
   total_flops>=12 \
   inet_down>$MIN_DOWN_MBPS \
   cpu_ram>$MIN_RAM_GB \
   disk_space>$DISK_GB \
   reliability>0.95 \
   cuda_vers>=12.0" \
  -o dph_total \
  --limit 5 \
  --raw 2>/dev/null)

if [ -z "$OFFER" ] || [ "$OFFER" = "[]" ]; then
  echo "❌ No suitable instances found. Try relaxing filters."
  exit 1
fi

BEST=$(echo "$OFFER" | jq '.[0]')
INSTANCE_ID=$(echo "$BEST" | jq -r '.id')
PRICE=$(echo "$BEST" | jq -r '.dph_total')
LOCATION=$(echo "$BEST" | jq -r '.geolocation')
VRAM=$(echo "$BEST" | jq -r '(.gpu_ram / 1024 | floor)')  # gpu_ram is in MB
GPU_NAME=$(echo "$BEST" | jq -r '.gpu_name')

echo "✅ Found: Instance $INSTANCE_ID | ${GPU_NAME} | €${PRICE}/hr | ${LOCATION} | ${VRAM}GB VRAM"

if [ "$SEARCH_ONLY" = "true" ]; then
  echo "🔎 Dry-run mode — not provisioning. Exiting."
  exit 0
fi

# ── Encode prod host SSH key ──────────────────────────────────────────────────
if [ -z "$RASPI_SSH_KEY_B64" ] && [ -f ~/.ssh/vastai_raspi_key ]; then
  RASPI_SSH_KEY_B64=$(base64 -w0 ~/.ssh/vastai_raspi_key)
fi

if [ -z "$RASPI_SSH_KEY_B64" ]; then
  echo "❌ RASPI_SSH_KEY_B64 not set and ~/.ssh/vastai_raspi_key not found."
  echo "   Generate a deploy key: ssh-keygen -t ed25519 -f ~/.ssh/vastai_raspi_key -N ''"
  echo "   Add public key to prod host: ~/.ssh/authorized_keys"
  exit 1
fi

if [ -z "$TAILSCALE_AUTH_KEY" ]; then
  echo "❌ TAILSCALE_AUTH_KEY not set."
  echo "   Generate at: https://login.tailscale.com/admin/settings/keys"
  echo "   Use type: Reusable, Ephemeral, no expiry (or short expiry)"
  exit 1
fi

# Derive paths from DATA_ROOT if not explicitly set in .environment
DATA_ROOT="${DATA_ROOT:-/mnt/ssd}"
RASPI_MODEL_PATH="${RASPI_MODEL_PATH:-${DATA_ROOT}/freqtrade/user_data/models/}"
RASPI_STACK_PATH="${RASPI_STACK_PATH:-${DATA_ROOT}/tradbot/}"

# ── Provision ─────────────────────────────────────────────────────────────────
echo "▶ Provisioning instance..."
echo "▶ Prod host: $RASPI_USER@$RASPI_HOST | DATA_ROOT: $DATA_ROOT"

# No --onstart needed: the Dockerfile CMD runs entrypoint.sh automatically.
# CONTRACT_ID is passed in so entrypoint.sh can self-destroy the instance on exit.
LAUNCHED=$(vastai create instance "$INSTANCE_ID" \
  --image "$DOCKER_IMAGE" \
  --env "RASPI_HOST=${RASPI_HOST}" \
  --env "RASPI_USER=${RASPI_USER}" \
  --env "RASPI_SSH_KEY_B64=${RASPI_SSH_KEY_B64}" \
  --env "RASPI_SSH_PORT=${RASPI_SSH_PORT:-22}" \
  --env "TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}" \
  --env "DATA_ROOT=${DATA_ROOT}" \
  --env "RASPI_MODEL_PATH=${RASPI_MODEL_PATH}" \
  --env "RASPI_STACK_PATH=${RASPI_STACK_PATH}" \
  --env "KRAKEN_PAIRS=${KRAKEN_PAIRS:-BTC/USDT,ETH/USDT}" \
  --env "TRAINING_MODEL=${MODEL}" \
  --env "TRAINING_EXCHANGE=${TRAINING_EXCHANGE:-binance}" \
  --env "TRAIN_DAYS=${TRAIN_DAYS:-90}" \
  --env "BACKTEST_DAYS=${BACKTEST_DAYS:-30}" \
  --env "VASTAI_API_KEY=${VASTAI_API_KEY}" \
  --disk "$DISK_GB" \
  --raw)

CONTRACT_ID=$(echo "$LAUNCHED" | jq -r '.new_contract')

if [ -z "$CONTRACT_ID" ] || [ "$CONTRACT_ID" = "null" ]; then
  echo "❌ Failed to provision instance. Response: $LAUNCHED"
  exit 1
fi

echo "▶ Instance $CONTRACT_ID started."
echo "▶ Model: $MODEL | Estimated duration: $([ "$MODEL" = "lightgbm" ] && echo "~20 min" || echo "~60 min")"
echo "▶ Streaming logs (Ctrl+C safe — instance continues)..."
echo ""

# ── Watch ─────────────────────────────────────────────────────────────────────
sleep 15  # wait for instance to start

START_TIME=$(date +%s)

while true; do
  STATUS=$(vastai show instance "$CONTRACT_ID" --raw 2>/dev/null | jq -r '.actual_status' 2>/dev/null || echo "unknown")

  if [ "$STATUS" = "exited" ] || [ "$STATUS" = "offline" ] || [ "$STATUS" = "unknown" ]; then
    ELAPSED=$(( ($(date +%s) - START_TIME) / 60 ))
    COST=$(echo "scale=3; $PRICE * $ELAPSED / 60" | bc)
    echo ""
    echo "✅ Training instance finished after ${ELAPSED} min (~€${COST})"
    break
  fi

  # Print last log line every 30s
  vastai logs "$CONTRACT_ID" --tail 3 2>/dev/null | tail -1
  sleep 30
done

echo ""
echo "Check prod host Freqtrade web UI to confirm new model loaded."
echo "Or ask the bot: 'Wurde ein neues Modell deployed?'"
