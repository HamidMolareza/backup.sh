#!/usr/bin/env bash
# Backup current user's crontab.

set -uo pipefail

out_dir="$TMP_BACKUP_DIR/crontab"
mkdir -p "$out_dir" || true

if command -v crontab >/dev/null 2>&1; then
  ts="$(date +%Y%m%d-%H%M%S)"
  if crontab -l >/dev/null 2>&1; then
    crontab -l >"$out_dir/crontab_${ts}.txt" 2>/dev/null || true
    echo "Saved crontab to $out_dir/crontab_${ts}.txt"
  else
    echo "No user crontab found (crontab -l returned non-zero)." >&2
  fi
else
  echo "crontab command not available." >&2
fi

# Lightweight restore helper
cat <<'EOF' >"$out_dir/restore.sh"
#!/usr/bin/env bash
set -euo pipefail
file="${1:-}"
if [ -z "$file" ]; then
  echo "Usage: $0 <crontab_file>" >&2
  exit 1
fi
crontab "$file"
echo "Crontab installed from $file"
EOF
chmod +x "$out_dir/restore.sh" || true

exit 0
