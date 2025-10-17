#!/usr/bin/env bash
# Backup OS settings: dconf/gsettings, installed packages, snaps/flatpaks, Nautilus items.
# Creates simple restore helpers for dconf and packages.

set -uo pipefail
umask 077

# ---------- basics ----------
task_name="$(basename "${BASH_SOURCE[0]}" .sh)"
dest_base="${TMP_BACKUP_DIR:-${tmp_backup_dir:-./output/.tasks}}"
base="${dest_base}/os-configs"
mkdir -p "$base"

log()  { printf "[TASK %s] %s\n" "$task_name" "$*" >&2; }
warn() { log "WARN: $*"; }

# ---------- 1) Desktop settings via dconf (fallback to gsettings) ----------
dconf_dir="${base}/dconf"
mkdir -p "$dconf_dir"

if command -v dconf >/dev/null 2>&1; then
  # Allow narrowing dump via config: DCONF_PATHS="/org/gnome/ /com/deja-dup/"
  IFS=' ' read -r -a _paths <<< "${DCONF_PATHS:-/}"
  for p in "${_paths[@]}"; do
    safe="$(printf '%s' "$p" | sed 's#^/##; s#[/[:space:]]#_#g')"
    out="${dconf_dir}/${safe}.conf"
    log "Dumping dconf: ${p} -> ${out}"
    dconf dump "$p" >"$out" 2>/dev/null || true
  done
else
  if command -v gsettings >/dev/null 2>&1; then
    log "dconf not available; dumping gsettings (informational)."
    gsettings list-recursively > "${dconf_dir}/gsettings-list.txt" 2>/dev/null || true
  else
    warn "Neither dconf nor gsettings available; skipping desktop settings."
  fi
fi

# Restore helper for dconf
cat > "${dconf_dir}/restore.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if ! command -v dconf >/dev/null 2>&1; then
  echo "[restore] dconf not available; nothing to do." >&2
  exit 0
fi
shopt -s nullglob
loaded=0
for f in *.conf; do
  echo "[restore] dconf load from $f"
  dconf load / < "$f"
  loaded=1
done
[ "$loaded" -eq 0 ] && echo "[restore] No *.conf files found; nothing loaded."
echo "[restore] Done."
SH
chmod +x "${dconf_dir}/restore.sh" || true

# ---------- 2) Installed packages ----------
pkg_dir="${base}/packages"
mkdir -p "$pkg_dir"

# Debian/Ubuntu
if command -v dpkg >/dev/null 2>&1; then
  dpkg --get-selections > "${pkg_dir}/dpkg-selections.txt" 2>/dev/null || true
  if command -v apt-mark >/dev/null 2>&1; then
    apt-mark showmanual | sort -u > "${pkg_dir}/apt-manual.txt" 2>/dev/null || true
  fi
fi

# RPM (Fedora/RHEL/SUSE variants)
if command -v rpm >/dev/null 2>&1; then
  rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort \
    > "${pkg_dir}/rpm-qa.tsv" 2>/dev/null || true
fi

# Arch
if command -v pacman >/dev/null 2>&1; then
  pacman -Qqe > "${pkg_dir}/pacman-explicit.txt" 2>/dev/null || true
  pacman -Q   > "${pkg_dir}/pacman-all.txt"      2>/dev/null || true
fi

# Snaps
if command -v snap >/dev/null 2>&1; then
  snap list > "${pkg_dir}/snaps.txt" 2>/dev/null || true
fi

# Flatpaks (tab-separated)
if command -v flatpak >/dev/null 2>&1; then
  flatpak list --app --columns=application,arch,branch,origin \
    > "${pkg_dir}/flatpaks.tsv" 2>/dev/null || true
fi

# Restore helper for packages (best-effort)
cat > "${pkg_dir}/restore.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

# Debian/Ubuntu
if command -v apt >/dev/null 2>&1; then
  echo "[restore] APT: update"
  sudo apt-get update -y || true

  if [ -f apt-manual.txt ]; then
    echo "[restore] APT: installing manual packages"
    xargs -a apt-manual.txt -r sudo apt-get install -y || true
  fi

  if [ -f dpkg-selections.txt ]; then
    echo "[restore] APT/dpkg: applying selections (optional)"
    sudo apt-get install -y dselect || true
    sudo dpkg --set-selections < dpkg-selections.txt || true
    echo "[restore] You may run 'sudo dselect' to process selections interactively."
  fi
fi

# RPM family: informational
if command -v rpm >/dev/null 2>&1 && [ -f rpm-qa.tsv ]; then
  echo "[restore] RPM-based system: review rpm-qa.tsv and reinstall as needed."
fi

# Arch
if command -v pacman >/dev/null 2>&1 && [ -f pacman-explicit.txt ]; then
  echo "[restore] Pacman: reinstalling explicitly installed packages"
  sudo pacman -S --needed --noconfirm - < pacman-explicit.txt || true
fi

# Snaps
if command -v snap >/dev/null 2>&1 && [ -f snaps.txt ]; then
  echo "[restore] Snaps: reinstalling"
  tail -n +2 snaps.txt | awk '{print $1}' | xargs -r -n1 sudo snap install || true
fi

# Flatpaks
if command -v flatpak >/dev/null 2>&1 && [ -f flatpaks.tsv ]; then
  echo "[restore] Flatpaks: reinstalling"
  cut -f1 flatpaks.tsv | xargs -r -n1 flatpak install -y --noninteractive || true
fi

echo "[restore] Package restore complete (best-effort)."
SH
chmod +x "${pkg_dir}/restore.sh" || true

# ---------- 3) Nautilus items (scripts/actions/etc.) ----------
nautilus_src="${NAUTILUS_DIR:-$HOME/.local/share/nautilus}"
if [ -d "$nautilus_src" ]; then
  dst="${base}/nautilus"
  mkdir -p "$dst"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a -- "$nautilus_src"/ "$dst"/ 2>/dev/null || true
  else
    cp -a -- "$nautilus_src"/. "$dst"/ 2>/dev/null || true
  fi
fi

# ---------- README ----------
cat > "${base}/README.txt" <<EOF
This backup contains:
- dconf/: GNOME settings dumps (*.conf) and a restore.sh helper.
- packages/: Lists from your package managers (APT/dpkg, RPM, pacman, snap, flatpak)
             with a best-effort restore.sh helper.
- nautilus/: Your Nautilus user data (scripts/actions/etc.), copied verbatim.
EOF

log "OS settings backup complete: ${base}"
exit 0
