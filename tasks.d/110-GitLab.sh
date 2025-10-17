#!/usr/bin/env bash
# Backup GitLab projects (mirror clones).
# Prefers: glab (GitLab CLI). Fallback: curl + jq.
# Optional env:
#   GITLAB_HOST        -> default: gitlab.com
#   GITLAB_TOKEN       -> personal access token (needed for private & membership)
#   GITLAB_USERNAME    -> required if no token and no glab auth
#   GITLAB_REPO_LIMIT  -> per-page limit (default 100)
#   GITLAB_RETRIES     -> retry count (default 3)
#   GITLAB_PROTOCOL    -> ssh|https (default ssh)

set -uo pipefail

retry() {
  local max="${1:-3}"; shift
  local attempt=1
  local delay=2
  while true; do
    if "$@"; then return 0; fi
    if [ "$attempt" -ge "$max" ]; then
      echo "Retry failed after ${attempt} attempts: $*" >&2
      return 1
    fi
    echo "Retry: ${attempt} -> sleeping ${delay}s…" >&2
    sleep "$delay"
    attempt=$((attempt+1))
    delay=$((delay*2))
  done
}

need() {
  command -v "$1" >/dev/null 2>&1
}

host="${GITLAB_HOST:-gitlab.com}"
api_base="https://${host}/api/v4"
limit="${GITLAB_REPO_LIMIT:-100}"
retries="${GITLAB_RETRIES:-3}"
proto="${GITLAB_PROTOCOL:-ssh}"

base="$tmp_backup_dir/gitlab"
repos_dir="$base/repos"
meta_dir="$base/meta"
mkdir -p "$repos_dir" "$meta_dir" || true

glab_ok=0
if need glab && glab --version >/dev/null 2>&1; then
  if glab auth status -h "$host" >/dev/null 2>&1; then
    glab_ok=1
  fi
fi

if [ "$glab_ok" -eq 1 ]; then
  echo "Using glab to enumerate GitLab projects…"
  glab --version >"$meta_dir/glab-version.txt" 2>&1 || true
  glab auth status -h "$host" >"$meta_dir/auth-status.txt" 2>&1 || true

  page=1
  >"$meta_dir/projects.json"
  while :; do
    out="$(glab api "projects?membership=true&simple=true&per_page=${limit}&page=${page}" 2>/dev/null || true)"
    [ -z "$out" ] && break
    echo "$out" >> "$meta_dir/projects.json"
    count="$(printf '%s' "$out" | grep -o '"path_with_namespace"' | wc -l | tr -d ' ')"
    [ "$count" -eq 0 ] && break

    # Loop projects in this page
    while IFS=$'\t' read -r path ssh http; do
      [ -z "$path" ] && continue
      url=""
      case "$proto" in
        ssh)   url="${ssh:-}";;
        https) url="${http:-}";;
        *)     url="${ssh:-}";;
      esac
      [ -z "$url" ] && url="${http:-}"

      dest="$repos_dir/${path}.git"
      mkdir -p "$(dirname "$dest")" || true
      if [ -d "$dest" ]; then
        echo "Updating GitLab repo: $path"
        retry "$retries" git -C "$dest" remote update --prune || true
      else
        echo "Cloning GitLab repo: $path -> $dest"
        retry "$retries" git clone --mirror "$url" "$dest" || true
      fi
    done < <( printf '%s' "$out" \
              | jq -r '.[] | [.path_with_namespace, .ssh_url_to_repo, .http_url_to_repo] | @tsv' 2>/dev/null )

    [ "$count" -lt "$limit" ] && break
    page=$((page+1))
  done

  exit 0
fi

# Fallback: curl + jq
if ! need curl || ! need jq; then
  echo "Neither glab nor (curl+jq) available; skipping GitLab backup." >&2
  exit 0
fi

token_hdr=()
[ -n "${GITLAB_TOKEN:-}" ] && token_hdr=(-H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")

# Determine username if needed
username="${GITLAB_USERNAME:-}"
if [ -z "$username" ] && [ -n "${GITLAB_TOKEN:-}" ]; then
  username="$(curl -fsSL "${token_hdr[@]}" "$api_base/user" | jq -r .username 2>/dev/null || echo "")"
fi

>"$meta_dir/projects.json"
page=1

if [ -n "${GITLAB_TOKEN:-}" ]; then
  # Membership projects (private+public)
  while :; do
    url="$api_base/projects?membership=true&simple=true&per_page=${limit}&page=${page}"
    out="$(curl -fsSL "${token_hdr[@]}" "$url" || true)"
    [ -z "$out" ] && break
    echo "$out" >> "$meta_dir/projects.json"
    count="$(printf '%s' "$out" | jq 'length' 2>/dev/null || echo 0)"
    [ "$count" -eq 0 ] && break

    while IFS=$'\t' read -r path ssh http; do
      [ -z "$path" ] && continue
      url=""
      case "$proto" in
        ssh)   url="${ssh:-}";;
        https) url="${http:-}";;
        *)     url="${ssh:-}";;
      esac
      [ -z "$url" ] && url="${http:-}"
      dest="$repos_dir/${path}.git"
      mkdir -p "$(dirname "$dest")" || true
      if [ -d "$dest" ]; then
        echo "Updating GitLab repo: $path"
        retry "$retries" git -C "$dest" remote update --prune || true
      else
        echo "Cloning GitLab repo: $path -> $dest"
        retry "$retries" git clone --mirror "$url" "$dest" || true
      fi
    done < <( printf '%s' "$out" \
              | jq -r '.[] | [.path_with_namespace, .ssh_url_to_repo, .http_url_to_repo] | @tsv' )
    [ "$count" -lt "$limit" ] && break
    page=$((page+1))
  done
else
  # Public projects for a username
  if [ -z "$username" ]; then
    echo "Set GITLAB_USERNAME or provide GITLAB_TOKEN to enumerate projects." >&2
    exit 0
  fi
  while :; do
    url="$api_base/users/${username}/projects?simple=true&per_page=${limit}&page=${page}"
    out="$(curl -fsSL "$url" || true)"
    [ -z "$out" ] && break
    echo "$out" >> "$meta_dir/projects.json"
    count="$(printf '%s' "$out" | jq 'length' 2>/dev/null || echo 0)"
    [ "$count" -eq 0 ] && break

    while IFS=$'\t' read -r path ssh http; do
      [ -z "$path" ] && continue
      url=""
      case "$proto" in
        ssh)   url="${ssh:-}";;
        https) url="${http:-}";;
        *)     url="${ssh:-}";;
      esac
      [ -z "$url" ] && url="${http:-}"
      dest="$repos_dir/${path}.git"
      mkdir -p "$(dirname "$dest")" || true
      if [ -d "$dest" ]; then
        echo "Updating GitLab repo: $path"
        retry "$retries" git -C "$dest" remote update --prune || true
      else
        echo "Cloning GitLab repo: $path -> $dest"
        retry "$retries" git clone --mirror "$url" "$dest" || true
      fi
    done < <( printf '%s' "$out" \
              | jq -r '.[] | [.path_with_namespace, .ssh_url_to_repo, .http_url_to_repo] | @tsv' )
    [ "$count" -lt "$limit" ] && break
    page=$((page+1))
  done
fi

exit 0
