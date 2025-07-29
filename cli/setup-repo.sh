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

prepare_custom_repo_for_distro "${CPU}-${MFR}-${OSNAME}-${OSVER}" "$@"

# fetch_and_register_source_file "https://github.com/openzfs/zfs/releases/download/zfs-2.2.4/zfs-2.2.4.tar.gz" build_zfs_source


