#!/bin/bash
# server_setup.sh
# First-time setup for the production server (RPi 4, x86_64 NAS, mini-PC, etc.).
# Run ONCE on the server as root or a sudo user.
#
# Behaviour adapts to the environment:
#   - If DATA_ROOT is already mounted/accessible → skips disk setup entirely
#   - If --format-disk is passed → formats DISK_DEV and mounts at DATA_ROOT
#   - If --move-docker is passed → relocates Docker data-root to DATA_ROOT
#
# What it always does:
#   1. Creates required directory structure under DATA_ROOT
#   2. Adds Vast.ai deploy key to ~/.ssh/authorized_keys
#   3. Clones/updates the repo to DATA_ROOT/tradbot/
#
# Usage:
#   # NAS or machine with storage already mounted:
#   DATA_ROOT=/volume1/docker/tradbot-data bash scripts/server_setup.sh
#
#   # RPi with fresh USB SSD (formats /dev/sda, mounts at /mnt/ssd):
#   DISK_DEV=/dev/sda bash scripts/server_setup.sh --format-disk
#
#   # Also relocate Docker data-root (useful on RPi to avoid SD card wear):
#   DISK_DEV=/dev/sda bash scripts/server_setup.sh --format-disk --move-docker
#
# Environment variables (all optional — defaults shown):
#   DATA_ROOT        /mnt/ssd           Persistent storage root
#   DISK_DEV         /dev/sda           Device to format (only with --format-disk)
#   REPO_URL         https://github.com/boernmaster/tradbot.git
#   VASTAI_PUBKEY    (empty)            Public key content to add to authorized_keys

set -e

# ── Config ────────────────────────────────────────────────────────────────────

DATA_ROOT="${DATA_ROOT:-/mnt/ssd}"
DISK_DEV="${DISK_DEV:-/dev/sda}"
REPO_URL="${REPO_URL:-https://github.com/boernmaster/tradbot.git}"
REPO_DIR="$DATA_ROOT/tradbot"

FORMAT_DISK=false
MOVE_DOCKER=false
for arg in "$@"; do
    [[ "$arg" == "--format-disk" ]] && FORMAT_DISK=true
    [[ "$arg" == "--move-docker" ]] && MOVE_DOCKER=true
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $(id -u) -ne 0 ]] && error "Run as root or with sudo"

ARCH=$(uname -m)
info "=== Production Server Setup (arch: $ARCH) ==="
echo ""

# ── Step 1: Storage ───────────────────────────────────────────────────────────

if mountpoint -q "$DATA_ROOT" 2>/dev/null || [[ -d "$DATA_ROOT" ]]; then
    info "[1/4] DATA_ROOT already accessible at $DATA_ROOT — skipping disk setup."
elif [[ "$FORMAT_DISK" = "true" ]]; then
    warn "About to FORMAT $DISK_DEV and mount at $DATA_ROOT. ALL DATA WILL BE LOST."
    read -r -p "Continue? (type 'yes' to confirm): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && { info "Aborted."; exit 0; }

    info "[1/4] Partitioning $DISK_DEV..."
    parted -s "$DISK_DEV" mklabel gpt
    parted -s "$DISK_DEV" mkpart primary ext4 0% 100%
    sleep 2

    DISK_PART="${DISK_DEV}1"
    info "Formatting ${DISK_PART} as ext4..."
    mkfs.ext4 -F -L tradbot-data "$DISK_PART"

    mkdir -p "$DATA_ROOT"
    mount "$DISK_PART" "$DATA_ROOT"

    UUID=$(blkid -s UUID -o value "$DISK_PART")
    if ! grep -q "$UUID" /etc/fstab 2>/dev/null; then
        echo "UUID=$UUID $DATA_ROOT ext4 defaults,noatime 0 2" >> /etc/fstab
        info "Added to /etc/fstab (UUID=$UUID)"
    fi
else
    warn "DATA_ROOT ($DATA_ROOT) does not exist and --format-disk was not passed."
    warn "Options:"
    warn "  a) Create and mount it manually, then re-run this script."
    warn "  b) Pass --format-disk to format DISK_DEV=$DISK_DEV automatically."
    warn "  c) Set DATA_ROOT to an existing path (e.g. DATA_ROOT=/volume1/mydata)."
    exit 1
fi

# ── Step 2: Docker data-root (optional) ───────────────────────────────────────

if [[ "$MOVE_DOCKER" = "true" ]]; then
    info "[2/4] Relocating Docker data-root to $DATA_ROOT/docker..."

    if ! command -v docker &>/dev/null; then
        warn "Docker not found. Install it first: curl -fsSL https://get.docker.com | sh"
    else
        systemctl stop docker 2>/dev/null || service docker stop 2>/dev/null || true

        DOCKER_CONFIG="/etc/docker/daemon.json"
        mkdir -p /etc/docker "$DATA_ROOT/docker"

        if [[ -f "$DOCKER_CONFIG" ]]; then
            python3 -c "
import json
cfg = json.load(open('$DOCKER_CONFIG'))
cfg['data-root'] = '$DATA_ROOT/docker'
json.dump(cfg, open('$DOCKER_CONFIG', 'w'), indent=2)
"
        else
            echo "{\"data-root\": \"$DATA_ROOT/docker\"}" > "$DOCKER_CONFIG"
        fi

        if [[ -d /var/lib/docker && "$(ls -A /var/lib/docker 2>/dev/null)" ]]; then
            info "Migrating existing Docker data (this may take a while)..."
            rsync -aH /var/lib/docker/ "$DATA_ROOT/docker/"
            mv /var/lib/docker /var/lib/docker.bak
        fi

        systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
        info "Docker data-root is now $DATA_ROOT/docker"
    fi
else
    info "[2/4] Skipping Docker relocation (pass --move-docker to enable)."
fi

# ── Step 3: Directory structure ───────────────────────────────────────────────

info "[3/4] Creating directory structure under $DATA_ROOT..."
mkdir -p "$DATA_ROOT/freqtrade/user_data/"{models,data,backtest_results,logs}
mkdir -p "$DATA_ROOT/signal-data"
mkdir -p "$DATA_ROOT/openclaw"

# SSH authorized_keys — standard location on the user running the services
SUDO_USER_HOME=$(eval echo ~"${SUDO_USER:-$(whoami)}")
AUTH_KEYS="$SUDO_USER_HOME/.ssh/authorized_keys"
mkdir -p "$SUDO_USER_HOME/.ssh"
chmod 700 "$SUDO_USER_HOME/.ssh"

if [[ -n "$VASTAI_PUBKEY" ]]; then
    if ! grep -qF "$VASTAI_PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
        echo "$VASTAI_PUBKEY" >> "$AUTH_KEYS"
        chmod 600 "$AUTH_KEYS"
        info "Added Vast.ai deploy key to $AUTH_KEYS"
    else
        info "Key already present in $AUTH_KEYS"
    fi
else
    warn "VASTAI_PUBKEY not set. Add the deploy public key manually:"
    warn "  echo 'ssh-ed25519 AAAA...' >> $AUTH_KEYS && chmod 600 $AUTH_KEYS"
fi

# ── Step 4: Clone / update repo ───────────────────────────────────────────────

info "[4/4] Cloning repository to $REPO_DIR..."
if [[ -d "$REPO_DIR/.git" ]]; then
    info "Repo already exists — pulling latest..."
    git -C "$REPO_DIR" pull --ff-only
else
    git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
info "=== Setup complete ==="
echo ""
echo "  Architecture:  $ARCH"
echo "  Data root:     $DATA_ROOT"
echo "  Repo:          $REPO_DIR"
echo "  Auth keys:     $AUTH_KEYS"
echo ""
echo "Next steps:"
echo "  1. Copy .env.example to $REPO_DIR/.environment and fill in secrets"
echo "  2. Start the stack:"
echo "       cd $REPO_DIR"
echo "       docker compose -f docker-compose.raspi.yml --env-file .environment \\"
echo "         -e DATA_ROOT=$DATA_ROOT up -d"
echo "  3. Register the signal-cli bot number:"
echo "       docker compose -f docker-compose.raspi.yml exec signal-cli \\"
echo "         signal-cli -u \$OPENCLAW_BOT_NUMBER register"
