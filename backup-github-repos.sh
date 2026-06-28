#!/usr/bin/env bash
#
# Mirror-backup ALL your GitHub repos (public + private) to a local folder / external HDD.
#
# - Lists every repo your token can access via the GitHub REST API (handles pagination).
# - First run: bare "mirror" clone (full history, all branches, tags, notes).
#   Later runs: fast "remote update --prune" (only new commits).
# - Token is passed per-git-command via an auth header -> NEVER written into repo
#   configs on disk, so your backup drive carries no secret.
# - Per-repo error isolation: one bad repo never stops the rest.
# - Timestamped log file + pass/fail summary.
#
# PREREQUISITES:
#   git, curl, and jq installed.
#     - Debian/Ubuntu:  sudo apt install git curl jq
#     - macOS (brew):   brew install git curl jq
#     - Git-Bash/Win:   git+curl ship with Git for Windows; install jq from https://jqlang.github.io/jq/
#   A GitHub Personal Access Token (classic) with scope "repo" (+ "read:org" for org repos):
#     https://github.com/settings/tokens
#
# TOKEN: export it, or the script prompts securely.
#     export GITHUB_BACKUP_TOKEN="ghp_xxxxYOURTOKENxxxx"
#
# USAGE:
#     ./backup-github-repos.sh -d /mnt/usb/GitHubBackup
#     ./backup-github-repos.sh -d /mnt/usb/GitHubBackup --bundle
#     ./backup-github-repos.sh -d /mnt/usb/GitHubBackup -a "owner,collaborator,organization_member"
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
DEST=""
AFFILIATION="owner,collaborator,organization_member"
MAKE_BUNDLE=0
MAKE_LFS=0

usage() {
    grep '^#' "$0" | sed 's/^#//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--destination) DEST="$2"; shift 2 ;;
        -a|--affiliation) AFFILIATION="$2"; shift 2 ;;
        --bundle)         MAKE_BUNDLE=1; shift ;;
        --lfs)            MAKE_LFS=1; shift ;;
        -h|--help)        usage ;;
        *) echo "Unknown arg: $1" >&2; usage ;;
    esac
done

# If no destination passed, list mounted volumes and ask (auto-detect external drives).
if [[ -z "$DEST" ]]; then
    echo ""
    echo "Mounted volumes (external drives usually under /media, /mnt, or /Volumes):"
    # Show real filesystems with mountpoint + free space; skip pseudo/system mounts.
    df -h -x tmpfs -x devtmpfs 2>/dev/null | awk 'NR==1 || $6 ~ /^\/(media|mnt|run\/media|Volumes)/ || NR<=8'
    echo ""
    read -rp "Enter full destination path (e.g. /mnt/usb/GitHubBackup): " DEST
    [[ -z "$DEST" ]] && { echo "ERROR: no destination given." >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Deps
# ---------------------------------------------------------------------------
for bin in git curl jq; do
    command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found in PATH." >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Token (priority: env var > secure prompt)
# ---------------------------------------------------------------------------
TOKEN="${GITHUB_BACKUP_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
    read -rsp "Enter GitHub Personal Access Token (input hidden): " TOKEN
    echo
fi
[[ -z "$TOKEN" ]] && { echo "ERROR: no token provided." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prep destination + logging
# ---------------------------------------------------------------------------
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"          # absolute path
STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
LOG_DIR="$DEST/_logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup_$STAMP.log"

log() {
    local level="${2:-INFO}"
    printf '%s [%s] %s\n' "$(date +%H:%M:%S)" "$level" "$1" | tee -a "$LOG_FILE"
}

log "GitHub backup started. Destination: $DEST"
log "Affiliation filter: $AFFILIATION"

AUTH_HEADER="AUTHORIZATION: bearer $TOKEN"
API="https://api.github.com"

api_get() {
    # $1 = full url
    curl -fsSL \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "User-Agent: bash-github-backup" \
        "$1"
}

# ---------------------------------------------------------------------------
# Verify token + identify user
# ---------------------------------------------------------------------------
if ! ME="$(api_get "$API/user" | jq -r '.login')" || [[ -z "$ME" || "$ME" == "null" ]]; then
    log "Token check FAILED. Check the token + its scopes." "ERROR"
    exit 1
fi
log "Authenticated as: $ME"

# If --lfs requested, confirm git-lfs installed; warn + disable if missing.
if [[ "$MAKE_LFS" -eq 1 ]]; then
    if git lfs version >/dev/null 2>&1; then
        log "git-lfs detected. Will fetch all LFS objects per repo."
    else
        log "git-lfs not found. Install from https://git-lfs.com then re-run. Skipping LFS." "WARN"
        MAKE_LFS=0
    fi
fi

# ---------------------------------------------------------------------------
# List ALL repos (paginated, 100/page until empty)
# Collect "owner<TAB>name<TAB>clone_url" lines.
# ---------------------------------------------------------------------------
log "Listing repositories..."
REPO_LIST="$(mktemp)"
trap 'rm -f "$REPO_LIST"' EXIT

page=1
while :; do
    batch="$(api_get "$API/user/repos?per_page=100&page=$page&affiliation=$AFFILIATION")"
    count="$(echo "$batch" | jq 'length')"
    [[ "$count" -eq 0 ]] && break
    echo "$batch" | jq -r '.[] | [.owner.login, .name, .clone_url] | @tsv' >> "$REPO_LIST"
    log "  page $page: $count repos"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
done

TOTAL="$(wc -l < "$REPO_LIST" | tr -d ' ')"
[[ "$TOTAL" -eq 0 ]] && { log "No repos returned. Check token scopes (needs 'repo')." "WARN"; exit 0; }
log "Total repos to back up: $TOTAL"

# ---------------------------------------------------------------------------
# Mirror each repo. Clone first run, update later runs.
# Layout:  <DEST>/<owner>/<repo>.git   (bare mirror)
# ---------------------------------------------------------------------------
ok=0; fail=0; failed=""

while IFS=$'\t' read -r owner name url; do
    owner_dir="$DEST/$owner"
    repo_dir="$owner_dir/$name.git"
    mkdir -p "$owner_dir"

    if (
        set -e
        if [[ -d "$repo_dir" ]]; then
            log "Updating $owner/$name ..."
            git -c "http.extraHeader=$AUTH_HEADER" -C "$repo_dir" remote update --prune >>"$LOG_FILE" 2>&1
        else
            log "Cloning  $owner/$name ..."
            git -c "http.extraHeader=$AUTH_HEADER" clone --mirror "$url" "$repo_dir" >>"$LOG_FILE" 2>&1
        fi

        if [[ "$MAKE_LFS" -eq 1 ]]; then
            git -c "http.extraHeader=$AUTH_HEADER" -C "$repo_dir" lfs fetch --all >>"$LOG_FILE" 2>&1
        fi

        if [[ "$MAKE_BUNDLE" -eq 1 ]]; then
            git -C "$repo_dir" bundle create "$owner_dir/$name.bundle" --all >>"$LOG_FILE" 2>&1
            log "  bundle -> $owner_dir/$name.bundle"
        fi
    ); then
        ok=$((ok + 1))
    else
        fail=$((fail + 1))
        failed="$failed $owner/$name"
        log "FAILED $owner/$name" "ERROR"
    fi
done < "$REPO_LIST"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "-----------------------------------------------"
log "DONE. Success: $ok  Failed: $fail  Total: $TOTAL"
if [[ "$fail" -gt 0 ]]; then
    log "Failed repos:$failed" "WARN"
    log "Re-run the script to retry failed repos." "WARN"
fi
log "Log saved to: $LOG_FILE"
