#!/bin/bash
# deploy_stack.sh
# Pushes configs, strategies, and OpenClaw skills from PC to the production host.
# Run from the project root after updating strategy, configs, or skills.
#
# What gets synced:
#   - freqtrade/config.json, config.freqai.json (NOT data or models)
#   - freqtrade/user_data/strategies/
#   - openclaw/openclaw.json, openclaw/skills/
#   - docker-compose.raspi.yml
#
# What does NOT get synced (excluded):
#   - freqtrade/user_data/data/     (downloaded fresh on Vast.ai)
#   - freqtrade/user_data/models/   (rsynced by deploy_model.sh from Vast.ai)
#   - .environment                   (never synced — set manually on prod host)
#   - .git/
#
# Usage:
#   ./scripts/deploy_stack.sh
#   ./scripts/deploy_stack.sh --dry-run   (preview changes, no transfer)

set -e

DRY_RUN=false
[[ "$*" == *"--dry-run"* ]] && DRY_RUN=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_ROOT/.environment" 2>/dev/null || {
    echo "❌ .environment file not found at $PROJECT_ROOT/.environment"
    exit 1
}

: "${RASPI_HOST:?RASPI_HOST not set in .environment}"
: "${RASPI_USER:?RASPI_USER not set in .environment}"

DATA_ROOT="${DATA_ROOT:-/mnt/ssd}"
RASPI_STACK_PATH="${RASPI_STACK_PATH:-${DATA_ROOT}/tradbot}"
SSH_KEY="${RASPI_SSH_KEY_FILE:-$HOME/.ssh/vastai_raspi_key}"

SSH_OPTS="-o StrictHostKeyChecking=no"
[[ -f "$SSH_KEY" ]] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

RSYNC_OPTS="-avz --delete"
[[ "$DRY_RUN" = "true" ]] && RSYNC_OPTS="$RSYNC_OPTS --dry-run" && echo "🔎 DRY-RUN mode — no files will be transferred"

echo "▶ Deploying stack to $RASPI_USER@$RASPI_HOST:$RASPI_STACK_PATH"

rsync $RSYNC_OPTS \
    -e "ssh $SSH_OPTS" \
    --exclude '.git/' \
    --exclude '.environment' \
    --exclude 'freqtrade/user_data/data/' \
    --exclude 'freqtrade/user_data/models/' \
    --exclude 'freqtrade/user_data/backtest_results/' \
    --exclude 'freqtrade/logs/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude '.mypy_cache/' \
    --exclude 'node_modules/' \
    "$PROJECT_ROOT/" \
    "$RASPI_USER@$RASPI_HOST:$RASPI_STACK_PATH/"

if [[ "$DRY_RUN" = "true" ]]; then
    echo ""
    echo "✅ Dry-run complete. Run without --dry-run to apply."
    exit 0
fi

echo ""
echo "▶ Reloading Freqtrade config on prod host..."
ssh $SSH_OPTS "$RASPI_USER@$RASPI_HOST" \
    "cd $RASPI_STACK_PATH && docker compose -f docker-compose.raspi.yml --env-file .environment exec freqtrade freqtrade reload-config 2>/dev/null || true"

echo ""
echo "✅ Stack deployed."
echo "   If you updated docker-compose.raspi.yml, restart manually:"
echo "   ssh $RASPI_USER@$RASPI_HOST 'cd $RASPI_STACK_PATH && docker compose -f docker-compose.raspi.yml --env-file .environment up -d'"
