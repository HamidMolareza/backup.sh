#!/usr/bin/env bash
# Backup Deja Dup (GNOME) settings and provide a restore helper.

set -uo pipefail

task_dir="$TMP_BACKUP_DIR/deja-dup-settings"
mkdir -p "$task_dir" || true

if command -v dconf >/dev/null 2>&1; then
  echo "Dumping Deja Dup settings…"
  dconf dump /org/gnome/deja-dup/ >"$task_dir/deja-dup-settings.txt" 2>/dev/null || true
else
  echo "dconf not found; skipping Deja Dup settings." >&2
fi

cat <<'EOF' >"$task_dir/restore.sh"
#!/usr/bin/env bash
set -euo pipefail
file_path="${1:-}"
default_value="deja-dup-settings.txt"
if [ -z "${file_path}" ]; then
  read -r -p "Enter the backup file path [deja-dup-settings.txt]: " file_path
fi
: "${file_path:=$default_value}"
if [ ! -f "$file_path" ]; then
  echo "Input is not valid." >&2
  exit 1
fi
if ! command -v dconf >/dev/null 2>&1; then
  echo "dconf not available on this system." >&2
  exit 1
fi
dconf load /org/gnome/deja-dup/ < "$file_path"
echo "Deja Dup settings restored."
EOF
chmod +x "$task_dir/restore.sh" || true

exit 0
