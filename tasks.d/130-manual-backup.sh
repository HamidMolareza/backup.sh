#!/usr/bin/env bash
# Interactive manual checklist (no-op in NON_INTERACTIVE mode except writing TODO file)

set -uo pipefail

checklist_dir="$tmp_backup_dir/manual-checklist"
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
printf '%s\n' "Destination base: $tmp_backup_dir" >> "$todo"
printf '%s\n\n' "Mark these off after completing:" >> "$todo"

if [ "${NON_INTERACTIVE:-0}" = "1" ]; then
  for t in "${tasks[@]}"; do
    printf '[ ] %s -> %s/\n' "$t" "$tmp_backup_dir" >> "$todo"
  done
  echo "NON_INTERACTIVE=1: wrote checklist to $todo"
  exit 0
fi

for t in "${tasks[@]}"; do
  echo "$t -> $tmp_backup_dir/"
  printf '[ ] %s -> %s/\n' "$t" "$tmp_backup_dir" >> "$todo"
  wait_to_press_enter
done

echo "Checklist saved to $todo"
exit 0
