#!/usr/bin/env bash

set -uo pipefail

SRC=""
DEST="$TMP_BACKUP_DIR"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { warn "Missing command: $1"; return 1; }
}

require_cmd select-copy

if [ -z "${SRC:-}" ]; then
    read -r -p "Enter knowledge directory path: " SRC
    while [ -z "${SRC}" ]; do
        echo "knowledge directory cannot be empty. Please enter a path." >&2
        read -r -p "Enter knowledge directory path: " SRC
    done
fi

select-copy -s "$SRC" -d "$DEST"