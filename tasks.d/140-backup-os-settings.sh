#!/usr/bin/env bash
# Backup OS settings: dconf, installed packages, snaps/flatpaks, Nautilus scripts
# Creates simple restore helpers.

set -uo pipefail

base="$tmp_backup_dir/os-configs"
mkdir -p "$base" || true

# 1) Desktop settings via dconf (fallback to gsettings)
if command -v dconf >/dev/null 2>&1; then
  echo "Dumping full dconf database…"
  dconf dump / >"$base/dconf-settings-backup.conf" 2>/dev/null || true
else
  echo "dconf not available; attempting gsettings dump…" >&2
  if command -v gsettings >/dev/null 2>&1; then
    gsettings list-recursively >"$base/gsettings-list.txt" 2>/dev/null || true
  fi
fi

cat <<'EOF' >"$base/restore.sh"
#!/usr/bin/env bash
set -euo pipefail
if command -v dconf >/dev/null 2>&1 && [ -f "dconf-settings-backup.conf" ]; then
  echo "Loading dconf settings…"
  dconf load / < dconf-settings-backup.conf
  echo "Done."
else
  echo "dconf not available or backup missing. Nothing restored." >&2
fi
EOF
chmod +x "$base/restore.sh" || true

# 2) Installed packages
pkg_dir="$base/installed-packages"
mkdir -p "$pkg_dir" || true

if command -v dpkg >/dev/null 2>&1; then
  dpkg --get-selections >"$pkg_dir/ubuntu-dpkg-selections.txt" 2>/dev/null || true
  command -v apt-mark >/dev/null 2>&1 && apt-mark showmanual >"$pkg_dir/apt-manual-packages.txt" 2>/dev/null || true
fi

if command -v snap >/dev/null 2>&1; then
  snap list >"$pkg_dir/snap.txt" 2>/dev/null || true
fi

if command -v flatpak >/dev/null 2>&1; then
  flatpak list --app --columns=application,arch,branch,origin >"$pkg_dir/flatpak.txt" 2>/dev/null || true
fi

cat <<'EOF' >"$pkg_dir/restore.sh"
#!/usr/bin/env bash
set -euo pipefail

if command -v apt >/dev/null 2>&1; then
  echo "Restoring APT packages…"
  sudo apt update
  if [ -f apt-manual-packages.txt ]; then
    # Reinstall manually installed packages (best-effort)
    xargs -a apt-manual-packages.txt -r sudo apt install -y || true
  fi
  if [ -f ubuntu-dpkg-selections.txt ]; then
    # Alternative: dpkg selections + dselect (older method)
    sudo apt install -y dselect || true
    sudo dpkg --set-selections < ubuntu-dpkg-selections.txt || true
    echo "Run: sudo dselect (optional interactive step)" || true
  fi
fi

if command -v snap >/dev/null 2>&1 && [ -f snap.txt ]; then
  echo "Reinstalling snaps…"
  # first column is name; skip header
  tail -n +2 snap.txt | awk '{print $1}' | xargs -r -n1 sudo snap install || true
fi

if command -v flatpak >/dev/null 2>&1 && [ -f flatpak.txt ]; then
  echo "Reinstalling flatpaks…"
  cut -d$'\t' -f1 flatpak.txt 2>/dev/null | xargs -r -n1 flatpak install -y --noninteractive || true
fi

echo "Package restore completed (best-effort)."
EOF
chmod +x "$pkg_dir/restore.sh" || true

# 3) Nautilus items (scripts/actions/etc.)
# Prefer rsync if available to preserve attributes.
nautilus_src="$HOME/.local/share/nautilus"
if [ -d "$nautilus_src" ]; then
  dst="$base/nautilus"
  mkdir -p "$dst" || true
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$nautilus_src"/ "$dst"/ 2>/dev/null || true
  else
    cp -a "$nautilus_src"/. "$dst"/ 2>/dev/null || true
  fi
fi

exit 0
