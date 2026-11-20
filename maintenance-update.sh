#!/bin/bash
set -euo pipefail

STAMP_FILE="/var/lib/server-bootstrap/maintenance-reboot-pending"
# Unattended: never stop at a debconf or conffile prompt (that would hang until
# the unit's TimeoutStartSec= kills dpkg mid-upgrade); keep local conffiles.
export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[maintenance-update] apt update"
apt update

echo "[maintenance-update] apt full-upgrade -y"
apt "${APT_OPTS[@]}" full-upgrade -y

echo "[maintenance-update] apt autoremove --purge -y"
apt "${APT_OPTS[@]}" autoremove --purge -y

echo "[maintenance-update] apt clean"
apt clean

mkdir -p "$(dirname "$STAMP_FILE")"
touch "$STAMP_FILE"

echo "[maintenance-update] rebooting"
systemctl reboot
