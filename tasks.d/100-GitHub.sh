#!/usr/bin/env bash
# Backup all GitHub repositories (and gists) for the authenticated user or GH_OWNER.
# Requires: gh (GitHub CLI), git
# Optional env:
#   GH_OWNER                -> GitHub username/org to back up (default: current authed user)
#   GH_REPO_LIMIT           -> Max repos to fetch (default: 1000)
#   GH_CLONE_PROTOCOL       -> ssh|https (default: ssh; falls back to https if ssh URL is empty)
#   GH_RETRIES              -> Retry count for network ops (default: 3)

set -uo pipefail

retry() {
  # retry <max> <cmd...>
  local max="${1:-3}"; shift
  local attempt=1
  local delay=2
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      echo "Retry: command failed after ${attempt} attempts: $*" >&2
      return 1
    fi
    echo "Retry: attempt ${attempt} failed; sleeping ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt+1))
    delay=$((delay*2))
  done
}

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1; skipping GitHub backup."; exit 0; }
}

need gh
need git

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated; skipping GitHub backup." >&2
  exit 0
fi

owner="${GH_OWNER:-$(gh api user -q .login 2>/dev/null || echo '')}"
if [ -z "$owner" ]; then
  echo "Could not determine GitHub owner; set GH_OWNER." >&2
  exit 0
fi

limit="${GH_REPO_LIMIT:-1000}"
proto="${GH_CLONE_PROTOCOL:-ssh}"
retries="${GH_RETRIES:-3}"

base="$tmp_backup_dir/github"
repos_dir="$base/repos"
gists_dir="$base/gists"
meta_dir="$base/meta"
mkdir -p "$repos_dir" "$gists_dir" "$meta_dir" || true

# Save metadata
gh --version >"$meta_dir/gh-version.txt" 2>&1 || true
gh auth status >"$meta_dir/auth-status.txt" 2>&1 || true

# List repositories (JSON + TSV for looping)
gh repo list "$owner" --limit "$limit" \
  --json nameWithOwner,sshUrl,httpUrl,updatedAt,visibility,isPrivate,isFork,archived,defaultBranchRef \
  >"$meta_dir/repos.json" 2>/dev/null || true

# Loop over repos
while IFS=$'\t' read -r nwo sshurl httpurl; do
  [ -z "$nwo" ] && continue
  url=""
  case "$proto" in
    ssh)  url="${sshurl:-}";;
    https) url="${httpurl:-}";;
    *) url="${sshurl:-}";;
  esac
  [ -z "$url" ] && url="${httpurl:-https://github.com/${nwo}.git}"

  dest="$repos_dir/${nwo}.git"
  mkdir -p "$(dirname "$dest")" || true

  if [ -d "$dest" ]; then
    echo "Updating GitHub repo: $nwo"
    retry "$retries" git -C "$dest" remote update --prune || true
  else
    echo "Cloning GitHub repo: $nwo -> $dest"
    retry "$retries" git clone --mirror "$url" "$dest" || true
  fi
done < <( gh repo list "$owner" --limit "$limit" \
            --json nameWithOwner,sshUrl,httpUrl \
            --jq '.[] | [.nameWithOwner, .sshUrl, .httpUrl] | @tsv' 2>/dev/null )

# Gists
if gh gist list --limit 1 >/dev/null 2>&1; then
  echo "Backing up GitHub gists…"
  gh gist list --limit "$limit" --json id,updatedAt,public,description \
    >"$meta_dir/gists.json" 2>/dev/null || true

  while IFS= read -r gist_id; do
    [ -z "$gist_id" ] && continue
    dest="$gists_dir/$gist_id"
    if [ -d "$dest/.git" ]; then
      echo "Updating gist: $gist_id"
      retry "$retries" git -C "$dest" pull --ff-only || true
    else
      echo "Cloning gist: $gist_id"
      retry "$retries" gh gist clone "$gist_id" "$dest" || true
    fi
  done < <( gh gist list --limit "$limit" --json id --jq '.[].id' 2>/dev/null )
else
  echo "Skipping gists (not permitted or gh too old)." >&2
fi

exit 0
