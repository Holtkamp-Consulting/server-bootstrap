#!/bin/bash
set -euo pipefail

STAMP_FILE="/var/lib/server-bootstrap/maintenance-reboot-pending"

echo "[maintenance-update] apt update"
apt update

echo "[maintenance-update] apt full-upgrade -y"
apt full-upgrade -y

echo "[maintenance-update] apt autoremove --purge -y"
apt autoremove --purge -y

echo "[maintenance-update] apt clean"
apt clean

mkdir -p "$(dirname "$STAMP_FILE")"
touch "$STAMP_FILE"

echo "[maintenance-update] rebooting"
systemctl reboot
