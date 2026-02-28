#!/bin/bash
# deploy_stack.sh
# Pushes configs and Compose files from PC to the Raspberry Pi.
# Run from PC after updating strategy or configs.
#
# Usage:
#   ./scripts/deploy_stack.sh
#
# Required env vars (from .environment):
#   RASPI_HOST, RASPI_USER, RASPI_STACK_PATH
#
# TODO (Phase 4): Implement full deploy logic.

set -e

source "$(dirname "$0")/../.environment" 2>/dev/null || { echo "❌ .environment not found"; exit 1; }

RASPI_STACK_PATH="${RASPI_STACK_PATH:-/mnt/ssd/signal-trader/}"

echo "Deploying stack to $RASPI_USER@$RASPI_HOST:$RASPI_STACK_PATH"
echo "TODO: implement in Phase 4"
echo ""
echo "Manual steps until Phase 4:"
echo "  rsync -avz --exclude '.git' --exclude 'freqtrade/user_data/data' \\"
echo "    --exclude 'freqtrade/user_data/models' \\"
echo "    ./ $RASPI_USER@$RASPI_HOST:$RASPI_STACK_PATH"
