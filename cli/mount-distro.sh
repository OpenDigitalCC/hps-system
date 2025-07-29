#!/bin/bash
set -euo pipefail

# Source the necessary configurations
source "$(dirname "${BASH_SOURCE[0]}")/../lib/functions.sh"

# --- Step 4: Main distro management logic ---
CPU="x86_64"
MFR="linux"
OSNAME="rockylinux"
OSVER="10.0"
OSVER_MAJ="10"


#echo "[*] Mounting distro"
mount_distro_iso "${CPU}-${MFR}-${OSNAME}-${OSVER}"

