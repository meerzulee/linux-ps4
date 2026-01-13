#!/bin/bash
#
# Helper script to extract patches from reference repos
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="${SCRIPT_DIR}/../tmp"
PATCHES_DIR="${SCRIPT_DIR}/../patches"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Extract patches from reference repositories

Usage: $0 <command> [options]

Commands:
    list <repo>                 List commits in a repo
    show <repo> <commit>        Show a specific commit
    extract <repo> <commit> <dest>  Extract commit as patch
    search <repo> <pattern>     Search commits by message
    diff <repo> <path>          Show changes in a file vs mainline
    files <repo>                Find PS4-specific files

Arguments:
    repo    - Repository name (e.g., feeRnt-5.4.247-baikal)
    commit  - Commit hash or range (e.g., abc123, HEAD~5..HEAD)
    dest    - Destination category (e.g., 0400-wifi-bt)
    pattern - Search pattern (grep regex)
    path    - File path within repo

Examples:
    $0 list feeRnt-5.4.247-baikal
    $0 search feeRnt-5.4.247-baikal "mt7668\\|mediatek"
    $0 show feeRnt-5.4.247-baikal abc123
    $0 extract feeRnt-5.4.247-baikal abc123 0400-wifi-bt
    $0 files whitehax0r-5.4-baikal
    $0 diff crashniels-6.15 drivers/ata/ahci.c

EOF
    exit 1
}

check_repo() {
    local repo=$1
    if [ ! -d "${TMP_DIR}/${repo}" ]; then
        log_error "Repository not found: ${repo}"
        log_info "Run './scripts/clone-refs.sh' first to clone reference repos"
        exit 1
    fi
}

cmd_list() {
    local repo=$1
    local count=${2:-50}
    check_repo "$repo"
    
    echo ""
    log_info "Recent commits in ${repo}:"
    echo ""
    cd "${TMP_DIR}/${repo}"
    git log --oneline -n "$count" --decorate
}

cmd_show() {
    local repo=$1
    local commit=$2
    check_repo "$repo"
    
    cd "${TMP_DIR}/${repo}"
    git show "$commit"
}

cmd_extract() {
    local repo=$1
    local commit=$2
    local dest=$3
    
    check_repo "$repo"
    
    if [ -z "$dest" ]; then
        log_error "Destination category required"
        echo "Available categories:"
        ls -1 "${PATCHES_DIR}" | grep "^0" | sed 's/^/  /'
        exit 1
    fi
    
    local dest_dir="${PATCHES_DIR}/${dest}"
    if [ ! -d "$dest_dir" ]; then
        log_warn "Creating category: ${dest}"
        mkdir -p "$dest_dir"
    fi
    
    cd "${TMP_DIR}/${repo}"
    
    log_info "Extracting ${commit} to ${dest}/"
    git format-patch -1 "$commit" -o "$dest_dir"
    
    log_info "Patch extracted:"
    ls -la "$dest_dir"/*.patch | tail -1
    
    echo ""
    log_warn "Don't forget to add the patch to patches/series!"
}

cmd_search() {
    local repo=$1
    local pattern=$2
    check_repo "$repo"
    
    echo ""
    log_info "Searching for '${pattern}' in ${repo}:"
    echo ""
    cd "${TMP_DIR}/${repo}"
    git log --oneline --all --grep="$pattern" -i | head -50
}

cmd_diff() {
    local repo=$1
    local filepath=$2
    check_repo "$repo"
    
    cd "${TMP_DIR}/${repo}"
    
    # Try to find the base tag
    local base_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
    
    if [ -n "$base_tag" ]; then
        log_info "Diff since ${base_tag} for ${filepath}:"
        git diff "${base_tag}" -- "$filepath"
    else
        log_info "Changes to ${filepath}:"
        git log --oneline -p -- "$filepath" | head -200
    fi
}

cmd_files() {
    local repo=$1
    check_repo "$repo"
    
    echo ""
    log_info "PS4-specific files in ${repo}:"
    echo ""
    cd "${TMP_DIR}/${repo}"
    
    echo "=== Files with 'ps4' in name ==="
    find . -type f -name "*ps4*" 2>/dev/null | grep -v ".git" | head -30
    
    echo ""
    echo "=== Files with 'baikal' in name ==="
    find . -type f -name "*baikal*" 2>/dev/null | grep -v ".git" | head -30
    
    echo ""
    echo "=== Files with 'liverpool' in name ==="
    find . -type f -name "*liverpool*" 2>/dev/null | grep -v ".git" | head -30
    
    echo ""
    echo "=== Custom directories ==="
    find . -type d \( -name "*ps4*" -o -name "*playstation*" \) 2>/dev/null | grep -v ".git"
}

# Main
case "${1:-}" in
    list)    cmd_list "$2" "$3" ;;
    show)    cmd_show "$2" "$3" ;;
    extract) cmd_extract "$2" "$3" "$4" ;;
    search)  cmd_search "$2" "$3" ;;
    diff)    cmd_diff "$2" "$3" ;;
    files)   cmd_files "$2" ;;
    *)       usage ;;
esac
