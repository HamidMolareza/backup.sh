#!/usr/bin/env bash
# Interactive manual checklist (no-op in NON_INTERACTIVE mode except writing TODO file)

set -uo pipefail

checklist_dir="$TMP_BACKUP_DIR/manual-checklist"
mkdir -p "$checklist_dir" || true
todo="$checklist_dir/TODO.txt"

tasks=(
  "Export browser bookmarks and extension configs"
  "Export OneTab"
  "Copy Joplin files"
  "Copy IDE settings"
  "Copy Proton password"
  "Copy phone numbers"
  "Copy FreeOTP"
  "Copy Mobile Screen Shots"
  "Mobile: Copy Poolaki data"
  "Mobile: Make backup from phone"
  "Copy Download Manager links"
  "Copy phone files"
)

printf '%s\n' "Manual backup checklist ($(date))" > "$todo"
printf '%s\n' "Destination base: $TMP_BACKUP_DIR" >> "$todo"
printf '%s\n\n' "Mark these off after completing:" >> "$todo"

if [ "${NON_INTERACTIVE:-0}" = "1" ]; then
  for t in "${tasks[@]}"; do
    printf '[ ] %s -> %s/\n' "$t" "$TMP_BACKUP_DIR" >> "$todo"
  done
  echo "NON_INTERACTIVE=1: wrote checklist to $todo"
  exit 0
fi

for t in "${tasks[@]}"; do
  echo "$t -> $TMP_BACKUP_DIR/"
  printf '[ ] %s -> %s/\n' "$t" "$TMP_BACKUP_DIR" >> "$todo"
  WAIT_TO_PRESS_ENTER
done

echo "Checklist saved to $todo"
exit 0
