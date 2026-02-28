#!/bin/bash
# raspi_setup.sh — kept for backward compatibility.
# Use scripts/server_setup.sh instead (works on RPi, NAS, x86_64, etc.).
exec "$(dirname "$0")/server_setup.sh" "$@"
