#!/usr/bin/env bash
# Backup current user's crontab (task script)

set -uo pipefail
umask 077

# ----- basics -----
task_name="$(basename "${BASH_SOURCE[0]}" .sh)"
dest_base="${TMP_BACKUP_DIR:-${tmp_backup_dir:-./output/.tasks}}"
out_dir="${dest_base}/${task_name}"
mkdir -p "$out_dir"

log()  { printf "[TASK %s] %s\n" "$task_name" "$*" >&2; }
warn() { log "WARN: $*"; }

# ----- checks -----
if ! command -v crontab >/dev/null 2>&1; then
  warn "crontab command not available; skipping."
  exit 0
fi

if ! crontab -l >/dev/null 2>&1; then
  warn "No user crontab found (crontab -l non-zero); nothing to back up."
  exit 0
fi

# ----- dump crontab -----
ts="$(date +%Y%m%d-%H%M%S)"
user="${USER:-unknown}"
dest="${out_dir}/crontab_${user}_${ts}.txt"

if crontab -l >"$dest" 2>/dev/null; then
  log "Saved crontab to: $dest"
else
  warn "Failed to read crontab; skipping."
  exit 0
fi

# ----- restore helper -----
cat > "${out_dir}/restore.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
file="${1:-}"
if [ -z "${file}" ]; then
  echo "Usage: $0 </path/to/crontab.txt>" >&2
  exit 1
fi
if [ ! -f "$file" ]; then
  echo "File not found: $file" >&2
  exit 1
fi
crontab "$file"
echo "Crontab installed from $file"
EOF
chmod +x "${out_dir}/restore.sh" || true

log "Done."
exit 0
