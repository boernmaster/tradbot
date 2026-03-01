#!/bin/bash
# deploy_model.sh
# Runs inside the Vast.ai container after quality gate passes.
# Connects to Tailscale (no open ports needed), rsyncs trained model files
# to the production host, restarts Freqtrade, then disconnects.
# Works with any Linux host: RPi, NAS, mini-PC, etc.
#
# Required env vars (injected by vastai_train.sh):
#   RASPI_HOST           Tailscale IP of prod host (tailscale ip -4 on prod host)
#   RASPI_USER           SSH user on prod host
#   RASPI_SSH_KEY_B64    base64-encoded private SSH key
#   TAILSCALE_AUTH_KEY   Ephemeral Tailscale auth key (tailscale.com/admin/settings/keys)
#   RASPI_MODEL_PATH     target path for models (default: /mnt/ssd/freqtrade/user_data/models/)
#   DATA_ROOT            persistent storage root on the host (default: /mnt/ssd)

set -e

DATA_ROOT="${DATA_ROOT:-/mnt/ssd}"
RASPI_MODEL_PATH="${RASPI_MODEL_PATH:-$DATA_ROOT/freqtrade/user_data/models/}"
RASPI_STACK_PATH="${RASPI_STACK_PATH:-$DATA_ROOT/tradbot/}"
KEY_FILE="/tmp/raspi_deploy_key"
WORK_DIR="/app/tradbot"
TAILSCALED_PID=""

log() { echo "[deploy] $*"; }

cleanup() {
  rm -f "$KEY_FILE"
  if [ -n "$TAILSCALED_PID" ]; then
    log "Disconnecting from Tailscale..."
    tailscale logout 2>/dev/null || true
    kill "$TAILSCALED_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Validate required env ─────────────────────────────────────────────────────
for VAR in RASPI_HOST RASPI_USER RASPI_SSH_KEY_B64 TAILSCALE_AUTH_KEY; do
  if [ -z "${!VAR}" ]; then
    echo "❌ Missing required env var: $VAR"
    exit 1
  fi
done

# ── Set up SSH key ────────────────────────────────────────────────────────────
log "Setting up SSH key..."
echo "$RASPI_SSH_KEY_B64" | base64 -d > "$KEY_FILE"
chmod 600 "$KEY_FILE"

SSH_PORT="${RASPI_SSH_PORT:-22}"
SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=15 -p $SSH_PORT"
SSH="ssh $SSH_OPTS $RASPI_USER@$RASPI_HOST"
RSYNC_SSH="rsync -avz --progress -e 'ssh $SSH_OPTS'"

# ── Connect to Tailscale ──────────────────────────────────────────────────────
# Uses userspace networking — works in Docker containers without /dev/net/tun.
# Joins as an ephemeral node: auto-removed from the admin console on disconnect.
log "Starting Tailscale (userspace mode)..."
tailscaled --tun=userspace-networking --state=mem: &
TAILSCALED_PID=$!
sleep 3

tailscale up \
  --authkey="$TAILSCALE_AUTH_KEY" \
  --ephemeral \
  --hostname="vastai-training-$(date +%m%d-%H%M)" \
  --accept-routes=false \
  --shields-up=false

log "✅ Tailscale connected — routing SSH via Tailscale to $RASPI_HOST"

# ── Test connectivity ─────────────────────────────────────────────────────────
log "Testing SSH connection to $RASPI_HOST..."
if ! $SSH "echo 'SSH OK'" 2>/dev/null; then
  echo "❌ Cannot reach prod host at $RASPI_HOST via Tailscale"
  echo "   Check: RASPI_HOST is the Tailscale IP (run 'tailscale ip -4' on prod host)"
  echo "   Check: prod host has Tailscale running ('tailscale status')"
  echo "   Check: SSH key is in ~/.ssh/authorized_keys on prod host"
  exit 1
fi
log "✅ SSH connection OK"

# ── Rsync models ──────────────────────────────────────────────────────────────
MODEL_SRC="$WORK_DIR/freqtrade/user_data/models/"

log "Rsyncing models to prod host..."
log "  From: $MODEL_SRC"
log "  To:   $RASPI_USER@$RASPI_HOST:$RASPI_MODEL_PATH"

eval $RSYNC_SSH \
  --delete \
  "$MODEL_SRC" \
  "$RASPI_USER@$RASPI_HOST:$RASPI_MODEL_PATH"

log "✅ Model files transferred"

# ── Also sync backtest results ────────────────────────────────────────────────
BACKTEST_SRC="$WORK_DIR/freqtrade/user_data/backtest_results/"
BACKTEST_DST="$RASPI_USER@$RASPI_HOST:$DATA_ROOT/freqtrade/user_data/backtest_results/"

eval $RSYNC_SSH "$BACKTEST_SRC" "$BACKTEST_DST" 2>/dev/null || log "⚠️  Backtest results rsync failed (non-fatal)"

# ── Restart Freqtrade on prod host ───────────────────────────────────────────
log "Restarting Freqtrade on prod host..."
$SSH "cd $RASPI_STACK_PATH && docker compose -f docker-compose.raspi.yml --env-file .environment restart freqtrade" 2>&1

log "✅ Freqtrade restarted with new model"

# ── Write update notification file ───────────────────────────────────────────
# OpenClaw skill polls this file and sends Signal notification.
TIMESTAMP=$(date '+%Y-%m-%d %H:%M UTC')
MODEL_TYPE="${TRAINING_MODEL:-lightgbm}"

$SSH "cat > ${DATA_ROOT}/freqtrade/user_data/model_update.txt << 'EOF'
timestamp=${TIMESTAMP}
model=${MODEL_TYPE}
deployed=true
EOF"

log "✅ Model update notification written to ${DATA_ROOT}/freqtrade/user_data/model_update.txt"

log "=== Deploy complete ==="
# cleanup() runs via trap on EXIT
