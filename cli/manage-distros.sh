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

OSNAME_VARIANTS=("rockylinux" "almalinux" "debian")

echo "Available OS variants: ${OSNAME_VARIANTS[*]}"
read -rp "Enter OS variant to manage [default: $OSNAME]: " selected
OSNAME="${selected:-$OSNAME}"

echo "[*] Listing local ISOs for ${CPU}-${MFR}-${OSNAME}-${OSVER}"
list_local_iso "${CPU}" "${MFR}" "${OSNAME}" "${OSVER}"

ISO_PATH="$(get_iso_path)"
echo "[*] Using ISO path: $ISO_PATH"

#TODO: if we don't have an extracted version, check if we have an ISO
#if no ISO, get one or if we can't, explin where to put it and what to call it

#echo "[*] Checking for latest ${OSNAME} version..."
#check_latest_version "${CPU}" "${MFR}" "${OSNAME}"

echo "[*] Ensuring ISO for ${CPU}-${MFR}-${OSNAME}-${OSVER} is present..."
download_iso "${CPU}" "${MFR}" "${OSNAME}" "${OSVER}"

echo "[*] Extracting ISO for PXE..."
extract_iso_for_pxe "${CPU}" "${MFR}" "${OSNAME}" "${OSVER}"

#echo "[*] Verifying ISO signature..."
#verify_checksum_signature "${CPU}" "${MFR}" "${OSNAME}" "${OSVER}"

