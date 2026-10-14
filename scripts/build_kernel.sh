#!/usr/bin/env bash
#
# Build an Intel LTS kernel with i915 or Xe debug options enabled,
# following /home/user/dev_task/kernel-setup-guide.txt.
#
# Usage:
#   ./build_kernel.sh <i915|xe> [options]
#
# Options:
#   -d DIR      Build directory (default: ADL_MR4_RC02)
#   -t TAG      Git tag/branch to check out (default: lts-v6.18.23-linux-260427T075939Z)
#   -c URL      URL of the .config to download (default: matches the guide's BSP config)
#   -v VERSION  CONFIG_LOCALVERSION value (default: -<variant>-debug)
#   -j JOBS     Parallel make jobs (default: nproc)
#   -h          Show this help

set -euo pipefail

REPO_URL="https://github.com/intel/linux-intel-lts.git"
TAG="lts-v6.18.23-linux-260427T075939Z"
CONFIG_URL="https://ikt.bj.intel.com/ikt_kernel_deb_repo/pool/main/l/lts-v6.18.23-linux-260427T075939Z/kernel.config"
BUILD_DIR="ADL_MR4_RC02"
JOBS="$(nproc)"
LOCALVERSION=""

usage() {
    grep '^#' "$0" | sed -n '2,/^$/p' | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

VARIANT=""
if [[ $# -ge 1 && "$1" != -* ]]; then
    VARIANT="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    shift
fi

while getopts ":d:t:c:v:j:h" opt; do
    case "$opt" in
        d) BUILD_DIR="$OPTARG" ;;
        t) TAG="$OPTARG" ;;
        c) CONFIG_URL="$OPTARG" ;;
        v) LOCALVERSION="$OPTARG" ;;
        j) JOBS="$OPTARG" ;;
        h) usage 0 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
        :) echo "Option -$OPTARG requires an argument" >&2; usage 1 ;;
    esac
done

if [[ "$VARIANT" != "i915" && "$VARIANT" != "xe" ]]; then
    echo "Error: first argument must be 'i915' or 'xe' (got: '${VARIANT}')" >&2
    usage 1
fi

[[ -z "$LOCALVERSION" ]] && LOCALVERSION="-${VARIANT}-debug"

log() { echo -e "\n==> $*"; }

for cmd in git make sudo; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Error: required tool '$cmd' not found." >&2; exit 1; }
done

PREREQ_PKGS=(
    build-essential
    bc
    bison
    flex
    libssl-dev
    libelf-dev
    dwarves
    libncurses-dev
    rsync
    cpio
    kmod
    fakeroot
    debhelper
    libdw-dev
)

log "Installing build prerequisites: ${PREREQ_PKGS[*]}"
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y "${PREREQ_PKGS[@]}"
else
    echo "Error: apt-get not found; install these packages manually: ${PREREQ_PKGS[*]}" >&2
    exit 1
fi

log "Setting up build directory: $BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

REPO_DIR="$(basename "$REPO_URL" .git)"
if [[ -d "$REPO_DIR/.git" ]]; then
    log "Repo already present, fetching updates"
    git -C "$REPO_DIR" fetch --all --tags
else
    log "Cloning $REPO_URL"
    git clone "$REPO_URL"
fi

cd "$REPO_DIR"

log "Checking out $TAG"
git checkout "$TAG"

log "Manual step required: download the kernel .config"
CONFIG_DEST="$(pwd)/.config"
cat <<EOF

The kernel config must be downloaded manually:

  1. Download this URL in your browser (or any authenticated session):
       $CONFIG_URL
  2. Save/copy it to:
       $CONFIG_DEST

EOF
while true; do
    read -r -p "Press Enter once the .config file is in place (or type 'skip' to abort): " REPLY
    if [[ "$REPLY" == "skip" ]]; then
        echo "Aborted: kernel .config was not provided." >&2
        exit 1
    fi
    if [[ -s "$CONFIG_DEST" ]]; then
        break
    fi
    echo "No (or empty) .config found at $CONFIG_DEST yet. Please copy it there first."
done

if [[ ! -x scripts/config ]]; then
    echo "Error: scripts/config not found in kernel source; cannot edit .config safely." >&2
    exit 1
fi

log "Setting CONFIG_LOCALVERSION=\"$LOCALVERSION\""
scripts/config --set-str LOCALVERSION "$LOCALVERSION"

if [[ "$VARIANT" == "i915" ]]; then
    log "Enabling i915 debug options"
    scripts/config \
        --enable CONFIG_DRM_I915_DEBUG_GUC \
        --enable CONFIG_DRM_I915_DEBUG_IOV \
        --enable CONFIG_DRM_I915_SELFTEST
else
    log "Enabling Xe debug options"
    scripts/config \
        --enable CONFIG_DRM_XE_DEBUG \
        --enable CONFIG_DRM_XE_WERROR \
        --enable CONFIG_DRM_XE_DEBUG_VM \
        --enable CONFIG_DRM_XE_DEBUG_SRIOV \
        --enable CONFIG_DRM_XE_DEBUG_MEM \
        --enable CONFIG_DRM_XE_LARGE_GUC_BUFFER \
        --module CONFIG_DRM_XE_KUNIT_TEST
fi

log "Resolving any newly-introduced config dependencies (olddefconfig)"
make olddefconfig

log "Building kernel packages (make -j$JOBS deb-pkg)"
sudo make -j"$JOBS" deb-pkg

log "Build complete. Generated packages:"
find .. -maxdepth 1 -name '*.deb' -print
