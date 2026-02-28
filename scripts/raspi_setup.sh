#!/bin/bash
# raspi_setup.sh
# First-time setup for the Raspberry Pi 4 production machine.
# Run once directly on the RPi as the pi user.
#
# What it does:
#   1. Formats and mounts USB SSD at /mnt/ssd
#   2. Moves Docker data-root to SSD
#   3. Creates required directory structure on SSD
#   4. Enables SSH
#   5. Adds Vast.ai deploy key to authorized_keys
#
# Prerequisites on RPi:
#   - 64-bit Raspberry Pi OS
#   - USB SSD connected
#   - pi user exists (default)
#
# Usage (run on RPi):
#   bash scripts/raspi_setup.sh
#
# TODO (Phase 4): Implement full setup logic.

set -e

echo "=== Raspberry Pi 4 First-Time Setup ==="
echo "This script is a placeholder. Full implementation in Phase 4."
echo ""
echo "Manual steps until Phase 4:"
echo "  1. sudo mkfs.ext4 /dev/sda1"
echo "  2. sudo mkdir -p /mnt/ssd"
echo "  3. echo '/dev/sda1 /mnt/ssd ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab"
echo "  4. sudo mount -a"
echo "  5. sudo mkdir -p /mnt/ssd/{freqtrade/user_data/{models,data,backtest_results},signal-data,openclaw,.ssh}"
echo "  6. cat ~/.ssh/vastai_raspi_key.pub >> /mnt/ssd/.ssh/authorized_keys"
echo "  7. chmod 700 /mnt/ssd/.ssh && chmod 600 /mnt/ssd/.ssh/authorized_keys"
