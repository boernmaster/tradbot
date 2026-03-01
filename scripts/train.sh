#!/bin/bash
# train.sh — unified training entry point
# Reads TRAINING_BACKEND from .environment to select local or Vast.ai training.
#
# Usage:
#   ./scripts/train.sh [args...]        # uses TRAINING_BACKEND from .environment
#
# All args are forwarded to the selected backend script:
#   local  → scripts/local_train.sh  [--no-download] [--deploy] [--days N] ...
#   vastai → scripts/vastai_train.sh  [--dry-run] [--model lstm] ...
#
# Override backend for one run:
#   TRAINING_BACKEND=vastai ./scripts/train.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.environment"

[ -f "$ENV_FILE" ] && source "$ENV_FILE" 2>/dev/null || true

BACKEND="${TRAINING_BACKEND:-local}"

case "$BACKEND" in
  local)
    echo "[train.sh] Backend: local  (change TRAINING_BACKEND=vastai to switch)"
    exec "$SCRIPT_DIR/local_train.sh" "$@"
    ;;
  vastai)
    echo "[train.sh] Backend: vastai (change TRAINING_BACKEND=local to switch)"
    exec "$SCRIPT_DIR/vastai_train.sh" "$@"
    ;;
  *)
    echo "❌ Unknown TRAINING_BACKEND: '$BACKEND' — must be 'local' or 'vastai'"
    exit 1
    ;;
esac
