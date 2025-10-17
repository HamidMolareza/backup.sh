#!/usr/bin/env bash
# Backup GitHub repositories (and gists) for the authenticated user or GH_OWNER.
# Requires: gh (GitHub CLI), git
#
# Optional env:
#   GH_OWNER            -> GitHub username/org (default: current authed user)
#   GH_REPO_LIMIT       -> Max repos to fetch (default: 1000)
#   GH_CLONE_PROTOCOL   -> ssh|https (default: https)
#   GH_RETRIES          -> Retry count for network ops (default: 3)
#   GH_FETCH_LFS        -> 1 = also fetch Git LFS objects (default: 0)
#   GH_SKIP_GISTS       -> 1 = skip gists (default: 0)
#   TMP_BACKUP_DIR      -> base output dir (default: ./output/.tasks/github)

set -uo pipefail
umask 077
unset LD_PRELOAD 2>/dev/null || true

# ----- tiny logger -----
TASK_NAME="$(basename "${BASH_SOURCE[0]}" .sh)"
log()  { printf "[TASK %s] %s\n" "$TASK_NAME" "$*" >&2; }
warn() { log "WARN: $*"; }
die0() { warn "$*"; exit 0; }  # exit 0 to not fail the whole backup

# ----- deps -----
need() { command -v "$1" >/dev/null 2>&1 || die0 "Missing command: $1; skipping GitHub backup."; }
need gh
need git
if ! gh auth status >/dev/null 2>&1; then die0 "gh is not authenticated; skipping."; fi

# ----- config -----
owner="${GH_OWNER:-$(gh api user -q .login 2>/dev/null || echo '')}"
[ -z "$owner" ] && die0 "Could not determine GitHub owner; set GH_OWNER."
limit="${GH_REPO_LIMIT:-1000}"
proto="${GH_CLONE_PROTOCOL:-ssh}"
retries="${GH_RETRIES:-3}"
fetch_lfs="${GH_FETCH_LFS:-0}"
skip_gists="${GH_SKIP_GISTS:-0}"

# ----- dirs -----
BASE="${TMP_BACKUP_DIR:-${tmp_backup_dir:-./output/.tasks}}/github"
REPOS_DIR="$BASE/repos"
GISTS_DIR="$BASE/gists"
META_DIR="$BASE/meta"
mkdir -p "$REPOS_DIR" "$GISTS_DIR" "$META_DIR"

# ----- utilities -----
retry() {
  # retry <max> <cmd...>
  local max="${1:-3}"; shift
  local attempt=1 delay=2
  while true; do
    if "$@"; then return 0; fi
    if [ "$attempt" -ge "$max" ]; then
      warn "Retry: command failed after ${attempt} attempts: $*"
      return 1
    fi
    warn "Retry: attempt ${attempt} failed; sleeping ${delay}s..."
    sleep "$delay"
    attempt=$((attempt+1)); delay=$((delay*2))
  done
}

pick_url() {
  # pick_url <sshUrl> <webUrl>
  local sshurl="$1" weburl="$2"
  case "$proto" in
    ssh)   [ -n "$sshurl" ] && printf '%s\n' "$sshurl" || printf '%s\n' "$weburl" ;;
    https) [ -n "$weburl" ] && printf '%s\n' "$weburl" || printf '%s\n' "$sshurl" ;;
    *)     [ -n "$weburl" ] && printf '%s\n' "$weburl" || printf '%s\n' "$sshurl" ;;
  esac
}

update_repo() {
  # update_repo <dest> <url> (bare mirror)
  local dest="$1" url="$2"
  if [ -d "$dest" ]; then
    log "Updating repo: ${dest#"$REPOS_DIR/"}"
    # ensure URL is current (protocol switch etc.)
    git -C "$dest" remote set-url origin "$url" >/dev/null 2>&1 || true
    retry "$retries" git -C "$dest" remote update --prune --prune-tags || true
  else
    log "Cloning repo: ${dest#"$REPOS_DIR/"}"
    mkdir -p "$(dirname "$dest")"
    retry "$retries" git clone --mirror "$url" "$dest" || {
      warn "Clone failed: $url → $dest"
      return 0
    }
  fi
  if [ "$fetch_lfs" = "1" ] && command -v git >/dev/null 2>&1 && git lfs version >/dev/null 2>&1; then
    retry "$retries" git -C "$dest" lfs fetch --all || true
  fi
  git -C "$dest" gc --auto >/dev/null 2>&1 || true
}

# ----- metadata -----
gh --version >"$META_DIR/gh-version.txt" 2>&1 || true
gh auth status >"$META_DIR/auth-status.txt" 2>&1 || true
gh api rate_limit -q '.resources.core | "remaining=\(.remaining) reset=\(.reset)"' \
  > "$META_DIR/rate-limit.txt" 2>/dev/null || true

# ----- list repos once for metadata -----
log "Listing repositories for owner: $owner (limit=$limit)"
gh repo list "$owner" --limit "$limit" \
  --json nameWithOwner,sshUrl,url,updatedAt,visibility,isPrivate,isFork,archived,defaultBranchRef \
  >"$META_DIR/repos.json" 2>/dev/null || true

# ----- loop repos (using gh's built-in --jq to avoid jq dependency) -----
while IFS=$'\t' read -r nwo sshurl weburl; do
  [ -z "$nwo" ] && continue
  url="$(pick_url "$sshurl" "$weburl")"
  # If both are empty (shouldn't happen), synthesize an https URL:
  [ -z "$url" ] && url="https://github.com/${nwo}.git"
  dest="$REPOS_DIR/${nwo}.git"   # creates owner/repo.git tree
  update_repo "$dest" "$url"
done < <( gh repo list "$owner" --limit "$limit" \
          --json nameWithOwner,sshUrl,url \
          --jq '.[] | [.nameWithOwner, .sshUrl, .url] | @tsv' 2>/dev/null )

# ----- gists (optional) -----
if [ "$skip_gists" != "1" ]; then
  if gh gist list --limit 1 >/dev/null 2>&1; then
    log "Backing up gists (limit=$limit)"
    gh gist list --limit "$limit" --json id,updatedAt,public,description \
      >"$META_DIR/gists.json" 2>/dev/null || true

    while IFS= read -r gist_id; do
      [ -z "$gist_id" ] && continue
      dest="$GISTS_DIR/$gist_id"
      if [ -d "$dest/.git" ]; then
        log "Updating gist: $gist_id"
        retry "$retries" git -C "$dest" fetch --all --prune || true
        retry "$retries" git -C "$dest" pull --ff-only     || true
      else
        log "Cloning gist: $gist_id"
        mkdir -p "$GISTS_DIR"
        retry "$retries" gh gist clone "$gist_id" "$dest" || {
          warn "Gist clone failed: $gist_id → $dest"
          true
        }
      fi
      git -C "$dest" gc --auto >/dev/null 2>&1 || true
    done < <( gh gist list --limit "$limit" --json id --jq '.[].id' 2>/dev/null )
  else
    warn "Skipping gists (not permitted, missing scope, or gh too old)."
  fi
else
  log "Skipping gists (GH_SKIP_GISTS=1)."
fi

# ----- summary -----
{
  echo "owner=$owner"
  echo "protocol=$proto"
  echo "limit=$limit"
  echo "retries=$retries"
  echo "fetch_lfs=$fetch_lfs"
  echo "timestamp=$(date -Iseconds)"
} > "$META_DIR/summary.txt"

log "GitHub backup complete → $BASE"
exit 0
