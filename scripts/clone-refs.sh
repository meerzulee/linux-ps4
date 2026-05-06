#!/bin/bash
#
# Clone reference repositories for patch extraction
# These repos contain PS4-specific patches we can learn from
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="${SCRIPT_DIR}/../tmp"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

echo ""
echo "=============================================="
echo "  Clone Reference Repositories"
echo "=============================================="
echo ""

mkdir -p "$TMP_DIR"

# Define repos to clone (Baikal-only — user hardware is Baikal southbridge)
# Depth chosen to comfortably cover the PS4-specific patch stack on top of vanilla.
declare -A REPOS=(
    ["crashniels-6.15"]="https://github.com/crashniels/linux.git|ps4-linux-6.15.y-baikal|300"
    ["feeRnt-5.4.247-baikal"]="https://github.com/feeRnt/ps4-linux-12xx.git|5.4.247-baikal-dfaus|800"
    # feeRnt experimental 6.x Baikal branches — useful for forward-porting reference
    ["feeRnt-6.15.4-baikal-crashniels"]="https://github.com/feeRnt/ps4-linux-12xx.git|x_exp__6.15.4-baikal-crashniels|400"
    ["feeRnt-6.15.4-BaikalLove"]="https://github.com/feeRnt/ps4-linux-12xx.git|x_exp__6.15.4-BaikalLove|400"
    ["whitehax0r-5.4-baikal"]="https://github.com/whitehax0r/ps4-linux-baikal.git|main|300"
    ["ps4boot-5.3-baikal"]="https://github.com/ps4boot/ps4-linux.git|baikal|150"
)

clone_repo() {
    local name=$1
    local url=$2
    local branch=$3
    local depth=$4
    local dest="${TMP_DIR}/${name}"
    
    if [ -d "$dest" ]; then
        log_warn "${name} already exists, updating..."
        cd "$dest"
        git fetch origin "$branch" --depth="$depth"
        git reset --hard "origin/${branch}" 2>/dev/null || git checkout "$branch"
        cd "$SCRIPT_DIR"
    else
        log_info "Cloning ${name}..."
        git clone "$url" --branch "$branch" --depth="$depth" "$dest"
    fi
}

for name in "${!REPOS[@]}"; do
    IFS='|' read -r url branch depth <<< "${REPOS[$name]}"
    log_step "Processing: ${name}"
    clone_repo "$name" "$url" "$branch" "$depth"
    echo ""
done

echo "=============================================="
log_info "Reference repos ready in: ${TMP_DIR}"
echo "=============================================="
echo ""
echo "Available repos:"
for dir in "${TMP_DIR}"/*; do
    if [ -d "$dir" ]; then
        echo "  - $(basename $dir)"
    fi
done
echo ""
echo "Useful commands:"
echo ""
echo "  # View commit history"
echo "  cd tmp/feeRnt-5.4.247-baikal && git log --oneline | head -30"
echo ""
echo "  # Show specific commit"
echo "  git show <commit-hash>"
echo ""
echo "  # Find PS4-related commits"
echo "  git log --oneline --all --grep='ps4\\|baikal\\|liverpool'"
echo ""
echo "  # Extract commit as patch"
echo "  git format-patch -1 <commit-hash> -o ../../patches/0100-southbridge/"
echo ""
echo "  # Compare files between repos"
echo "  diff -u tmp/repo1/path/file tmp/repo2/path/file"
echo ""
