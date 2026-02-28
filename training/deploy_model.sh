#!/bin/bash
# deploy_model.sh
# Runs inside the Vast.ai container after quality gate passes.
# Rsyncs trained model files to the production host and restarts Freqtrade.
# Works with any Linux host: RPi, NAS, mini-PC, etc.
#
# Required env vars (injected by vastai_train.sh):
#   RASPI_HOST           Production host IP or hostname
#   RASPI_USER           SSH user on host
#   RASPI_SSH_KEY_B64    base64-encoded private SSH key
#   RASPI_MODEL_PATH     target path for models (default: /mnt/ssd/freqtrade/user_data/models/)
#   DATA_ROOT            persistent storage root on the host (default: /mnt/ssd)

set -e

DATA_ROOT="${DATA_ROOT:-/mnt/ssd}"
RASPI_MODEL_PATH="${RASPI_MODEL_PATH:-$DATA_ROOT/freqtrade/user_data/models/}"
RASPI_STACK_PATH="${RASPI_STACK_PATH:-$DATA_ROOT/tradbot/}"
KEY_FILE="/tmp/raspi_deploy_key"
WORK_DIR="/app/tradbot"

log() { echo "[deploy] $*"; }

# ── Validate required env ─────────────────────────────────────────────────────
for VAR in RASPI_HOST RASPI_USER RASPI_SSH_KEY_B64; do
  if [ -z "${!VAR}" ]; then
    echo "❌ Missing required env var: $VAR"
    exit 1
  fi
done

# ── Set up SSH key ────────────────────────────────────────────────────────────
log "Setting up SSH key..."
echo "$RASPI_SSH_KEY_B64" | base64 -d > "$KEY_FILE"
chmod 600 "$KEY_FILE"

SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=15"
SSH="ssh $SSH_OPTS $RASPI_USER@$RASPI_HOST"
RSYNC_SSH="rsync -avz --progress -e 'ssh $SSH_OPTS'"

# ── Test connectivity ─────────────────────────────────────────────────────────
log "Testing SSH connection to $RASPI_HOST..."
if ! $SSH "echo 'SSH OK'" 2>/dev/null; then
  echo "❌ Cannot reach host at $RASPI_HOST"
  echo "   Check: RASPI_HOST, SSH key in ~/.ssh/authorized_keys on host, network reachable from Vast.ai"
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
# DATA_ROOT here is the path on the REMOTE host, passed in by vastai_train.sh.
TIMESTAMP=$(date '+%Y-%m-%d %H:%M UTC')
MODEL_TYPE="${TRAINING_MODEL:-lightgbm}"

$SSH "cat > ${DATA_ROOT}/freqtrade/user_data/model_update.txt << 'EOF'
timestamp=${TIMESTAMP}
model=${MODEL_TYPE}
deployed=true
EOF"

log "✅ Model update notification written to ${DATA_ROOT}/freqtrade/user_data/model_update.txt"
log "Prod host will notify via Signal: 'Neues Modell deployed ($MODEL_TYPE)'"

# ── Cleanup ───────────────────────────────────────────────────────────────────
rm -f "$KEY_FILE"

log "=== Deploy complete ==="
