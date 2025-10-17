#!/usr/bin/env bash
# Portable, modular backup/restore driver
# Requirements: bash, tar, coreutils; optional: zstd/xz/gzip, gpg, flock, envsubst

###############################################################################
# Strict-ish mode & globals
###############################################################################
set -uo pipefail
IFS=$'\n\t'
umask 077

PROG="${0##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default paths (can be overridden by config/env/CLI)
CONFIG_FILE="${SCRIPT_DIR}/config.env"
INCLUDE_FILE="${SCRIPT_DIR}/include.txt"
EXCLUDE_FILE="${SCRIPT_DIR}/exclude.txt"
TASKS_DIR="${SCRIPT_DIR}/tasks.d"
LOG_DIR_DEFAULT="${SCRIPT_DIR}/logs"
OUTPUT_DIR_DEFAULT="${SCRIPT_DIR}/output"

START_EPOCH=$(date +%s)

# Defaults (overridable by config/env/CLI)
OUTPUT_DIR="${OUTPUT_DIR:-$OUTPUT_DIR_DEFAULT}"
ARCHIVE_PREFIX="${ARCHIVE_PREFIX:-system-backup}"
COMPRESS="${COMPRESS:-zstd}"          # zstd|xz|gz|none
ENCRYPTION="${ENCRYPTION:-gpg}"        # none|gpg
GPG_RECIPIENT="${GPG_RECIPIENT:-}"     # required if ENCRYPTION=gpg
KEEP_OLD_FILES="${KEEP_OLD_FILES:-1}"  # restore default: keep old files
STAGING_PREFIX="${STAGING_PREFIX:-__backup_extras}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"         # INFO|DEBUG
STREAM_TASK_LOGS="${STREAM_TASK_LOGS:-$([ -t 1 ] && echo 1 || echo 0)}"
LOCK_FILE_DEFAULT="${SCRIPT_DIR}/.backup.lock"
LOCK_FILE="${LOCK_FILE:-$LOCK_FILE_DEFAULT}"
VERIFY="${VERIFY:-0}"                  # verify archive after build
RETENTION="${RETENTION:-0}"            # keep N most-recent archives (0 = no prune)
HASH_ALGO="${HASH_ALGO:-sha256}"       # sha256|sha512|none
ONE_FS="${ONE_FS:-0}"                  # tar --one-file-system
EXCLUDE_CACHES="${EXCLUDE_CACHES:-1}"  # tar --exclude-caches-all --exclude-backups
SPARSE="${SPARSE:-1}"                  # tar --sparse when reasonable
TAG="${TAG:-}"                         # extra tag in filename, CLI --tag
TMPDIR_PARENT="${TMPDIR_PARENT:-$OUTPUT_DIR}"  # where to place working dir

# Bootstrap logging (moves after config is loaded)
BOOTSTRAP_LOG="${LOG_DIR_DEFAULT}/bootstrap-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR_DEFAULT" "$OUTPUT_DIR_DEFAULT" 2>/dev/null || true
LOG_FILE="$BOOTSTRAP_LOG"

###############################################################################
# Logging
###############################################################################
log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  printf "[%s] %-5s %s\n" "$ts" "$level" "$*" | tee -a "$LOG_FILE" >&2
}
info(){ log "INFO" "$@"; }
warn(){ log "WARN" "$@"; }
error(){ log "ERROR" "$@"; }
debug(){ [ "$LOG_LEVEL" = "DEBUG" ] && log "DEBUG" "$@" || true; }

init_logging() {
  local log_dir="${LOG_DIR:-$LOG_DIR_DEFAULT}"
  mkdir -p "$log_dir" "$OUTPUT_DIR" 2>/dev/null || true
  local new_log="${log_dir}/$(date +%Y%m%d-%H%M%S)-backup.log"
  # move bootstrap log if any content exists
  if [ -s "$BOOTSTRAP_LOG" ] && [ "$BOOTSTRAP_LOG" != "$new_log" ]; then
    mv -f "$BOOTSTRAP_LOG" "$new_log" 2>/dev/null || true
  fi
  LOG_FILE="$new_log"
  debug "Logging to $LOG_FILE"
}

run_safe() {
  # run_safe "description" cmd...
  local desc="$1"; shift
  "$@" >>"$LOG_FILE" 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    error "$desc failed (rc=$rc)"
  else
    debug "$desc OK"
  fi
  return 0  # do not hard-fail driver
}

###############################################################################
# Safety: locking & cleanup
###############################################################################
LOCK_FD=""
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
      error "Another run is in progress (lock: $LOCK_FILE)."
      exit 0
    fi
    debug "Acquired lock $LOCK_FILE (fd $LOCK_FD)"
  else
    warn "flock not found; continuing without concurrency lock."
  fi
}

TMP_WORK=""
cleanup() {
  local rc=$?
  [ -n "$TMP_WORK" ] && rm -rf "$TMP_WORK" 2>/dev/null || true
  debug "Cleanup complete (rc=$rc)."
  exit 0
}
trap cleanup EXIT INT TERM

###############################################################################
# Helpers
###############################################################################
ask_yes_no() {
  local prompt="$1"
  if [ "${NON_INTERACTIVE:-0}" = "1" ]; then
    debug "NON_INTERACTIVE=1 -> auto-yes: $prompt"
    return 0
  fi
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

WAIT_TO_PRESS_ENTER() {
  [ "${NON_INTERACTIVE:-0}" = "1" ] && return 0
  read -r -p "Press ENTER to continue..." _
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { warn "Missing command: $1"; return 1; }
}

# Expand env vars in a line but keep globs as patterns (no word splitting)
_expand_vars_only() {
  local line="$1"
  # strip trailing CR if the file is CRLF
  line="${line%$'\r'}"
  if command -v envsubst >/dev/null 2>&1; then
    printf '%s' "$line" | envsubst
  else
    case "$line" in *'$('*|*'`'*)
      printf '%s' "$line" ;;  # refuse command substitution
    *) set -f; eval printf '%s' "\"$line\""; set +f ;;
    esac
  fi
}

build_tar_excludes() {
  local file="$1"
  local -n out_arr=$2
  out_arr=()
  if [ -f "$file" ]; then
    while IFS= read -r raw || [ -n "$raw" ]; do
      raw="${raw%$'\r'}"                                # strip CR
      [[ -z "$raw" || "$raw" =~ ^[[:space:]]*# ]] && continue
      local expanded norm
      expanded=$(_expand_vars_only "$raw")
      norm="${expanded#/}"                              # relative form for -C /
      out_arr+=("--exclude=$expanded")
      [ "$norm" != "$expanded" ] && out_arr+=("--exclude=$norm")
      debug "exclude: $expanded${norm:+ (alt: $norm)}"
    done < "$file"
  fi
}

make_null_list_from_file() {
  local in="$1" out="$2"
  : > "$out"
  if [ -f "$in" ]; then
    while IFS= read -r raw || [ -n "$raw" ]; do
      raw="${raw%$'\r'}"                                # strip CR
      [[ -z "$raw" || "$raw" =~ ^[[:space:]]*# ]] && continue
      local expanded norm
      expanded=$(_expand_vars_only "$raw")
      expanded="${expanded%$'\r'}"                      # double-guard CR
      norm="${expanded#/}"                              # relative to /
      printf '%s\0' "$norm" >> "$out"
      debug "include: $expanded -> $norm"
    done < "$in"
  fi
}

human_size() {
  numfmt --to=iec --suffix=B --padding=7 "$1" 2>/dev/null || echo "$1"
}

write_checksum() {
  local f="$1"
  case "$HASH_ALGO" in
    sha256) command -v sha256sum >/dev/null 2>&1 && sha256sum "$f" > "${f}.sha256" ;;
    sha512) command -v sha512sum >/dev/null 2>&1 && sha512sum "$f" > "${f}.sha512" ;;
    none|"") ;;
    *) warn "Unknown HASH_ALGO=$HASH_ALGO" ;;
  esac
}

verify_archive() {
  local archive="$1"
  [ "${VERIFY:-0}" != "1" ] && return 0
  info "Verifying archive integrity: $(basename "$archive")"
  if [[ "$archive" =~ \.gpg$ ]]; then
    if [[ "$archive" =~ \.tar\.zst\.gpg$ ]]; then
      run_safe "verify gpg+zstd" sh -c 'gpg --batch -q --decrypt "$1" | zstd -dc -q | tar -t >/dev/null' _ "$archive"
    elif [[ "$archive" =~ \.tar\.xz\.gpg$ ]]; then
      run_safe "verify gpg+xz"   sh -c 'gpg --batch -q --decrypt "$1" | xz -dc    | tar -t >/dev/null' _ "$archive"
    elif [[ "$archive" =~ \.tar\.gz\.gpg$ ]]; then
      run_safe "verify gpg+gz"   sh -c 'gpg --batch -q --decrypt "$1" | gzip -dc  | tar -t >/dev/null' _ "$archive"
    else
      run_safe "verify gpg+tar"  sh -c 'gpg --batch -q --decrypt "$1" | tar -t >/dev/null' _ "$archive"
    fi
  elif [[ "$archive" =~ \.zst$ ]]; then
    run_safe "verify zstd" sh -c 'zstd -dc -q "$1" | tar -t >/dev/null' _ "$archive"
  elif [[ "$archive" =~ \.xz$ ]]; then
    run_safe "verify xz"   sh -c 'xz -dc "$1"    | tar -t >/dev/null' _ "$archive"
  elif [[ "$archive" =~ \.gz$ ]]; then
    run_safe "verify gz"   sh -c 'gzip -dc "$1"  | tar -t >/dev/null' _ "$archive"
  else
    run_safe "verify tar"  tar -tf "$archive" >/dev/null
  fi
}

prune_old_archives() {
  local n="${RETENTION:-0}"
  [ "$n" -gt 0 ] || return 0
  info "Retention: keeping latest $n archives with prefix '${ARCHIVE_PREFIX}'"
  # list matching archives sorted newest first
  mapfile -t existing < <(ls -1t "${OUTPUT_DIR}/${ARCHIVE_PREFIX}-"*.tar* 2>/dev/null || true)
  local count=${#existing[@]}
  if [ "$count" -le "$n" ]; then
    debug "Nothing to prune."
    return 0
  fi
  for i in "${existing[@]:$n}"; do
    info "Pruning old archive: $(basename "$i")"
    rm -f -- "$i" "$i.sha256" "$i.sha512" 2>/dev/null || true
  done
}

###############################################################################
# Config
###############################################################################
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    info "Loaded config from $CONFIG_FILE"
  else
    warn "Config file not found ($CONFIG_FILE), using defaults."
  fi
  # allow LOG_DIR override from config
  LOG_DIR="${LOG_DIR:-$LOG_DIR_DEFAULT}"
  OUTPUT_DIR="${OUTPUT_DIR:-$OUTPUT_DIR_DEFAULT}"
  mkdir -p "$OUTPUT_DIR" "$TASKS_DIR" "$LOG_DIR" 2>/dev/null || true
}

###############################################################################
# Tasks runner
###############################################################################
run_task_scripts() {
  local tmp_dir="$1"
  local count=0 ok=0 failed=0

  export TMP_BACKUP_DIR="$tmp_dir"
  export NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
  export LOG_FILE               # let tasks append to the same log if they want
  export -f WAIT_TO_PRESS_ENTER

  # sorted list, ignore *.sample
  mapfile -t scripts < <(find "$TASKS_DIR" -maxdepth 1 -type f -name "*.sh" ! -name "*.sample" -printf "%f\n" 2>/dev/null | sort)

  for s in "${scripts[@]}"; do
    count=$((count+1))
    info "Running task: $s"
    local t0=$(date +%s)

    local rc=0
    if [ "${STREAM_TASK_LOGS}" = "1" ]; then
      if command -v stdbuf >/dev/null 2>&1; then
        stdbuf -oL -eL bash "$TASKS_DIR/$s" 2>&1 \
          | sed -u "s/^/[TASK $s] /" \
          | tee -a "$LOG_FILE" >&2
      else
        bash "$TASKS_DIR/$s" 2>&1 \
          | sed -u "s/^/[TASK $s] /" \
          | tee -a "$LOG_FILE" >&2
      fi
      rc=${PIPESTATUS[0]}
    else
      bash "$TASKS_DIR/$s" >>"$LOG_FILE" 2>&1
      rc=$?
    fi

    local dur=$(( $(date +%s) - t0 ))
    if [ $rc -ne 0 ]; then
      error "Task $s exited with rc=$rc (dur ${dur}s)"
      failed=$((failed+1))
    else
      info "Task $s completed (dur ${dur}s)"
      ok=$((ok+1))
    fi
  done

  TASKS_TOTAL="$count"
  TASKS_OK="$ok"
  TASKS_FAIL="$failed"
}

###############################################################################
# Backup
###############################################################################
do_backup() {
  acquire_lock
  load_config
  init_logging

  require_cmd tar || { error "tar required"; return 0; }

  local ts="$(date +%Y%m%d-%H%M%S)"
  local tag_part=""
  [ -n "$TAG" ] && tag_part="--${TAG//[^A-Za-z0-9._-]/_}"
  local base_name="${ARCHIVE_PREFIX}-${ts}${tag_part}"

  TMP_WORK="$(mktemp -d "${TMPDIR_PARENT}/.work.${ts}.XXXXXX")"
  local tmp_dir="${TMP_WORK}/extras"
  mkdir -p "$tmp_dir"

  info "Temp working dir: $TMP_WORK"
  info "Extras (task output) dir: $tmp_dir"

  run_task_scripts "$tmp_dir"

  local excludes=()
  build_tar_excludes "$EXCLUDE_FILE" excludes

  local include_list="${TMP_WORK}/includes.null"
  make_null_list_from_file "$INCLUDE_FILE" "$include_list"

  local tmp_tar="${TMP_WORK}/${base_name}.tar"
  local final_path=""
  local compressor=""

  # Determine final filename up-front (considering compress+encrypt)
  case "$COMPRESS" in
    zstd) final_path="${OUTPUT_DIR}/${base_name}.tar.zst" ;;
    xz)   final_path="${OUTPUT_DIR}/${base_name}.tar.xz" ;;
    gz|gzip) final_path="${OUTPUT_DIR}/${base_name}.tar.gz" ;;
    none|"") final_path="${OUTPUT_DIR}/${base_name}.tar" ;;
    *) warn "Unknown COMPRESS=$COMPRESS, falling back to no compression."; final_path="${OUTPUT_DIR}/${base_name}.tar" ;;
  esac
  [ "$ENCRYPTION" = "gpg" ] && final_path="${final_path}.gpg"

  # Honor overwrite/idempotence
  if [ -e "$final_path" ] && [ "${OVERWRITE:-0}" != "1" ]; then
    warn "Archive exists: $(basename "$final_path"); skipping backup (idempotent)."
    SUMMARY_SKIPPED=1
    return 0
  fi

  # Create manifest into extras (gets namespaced under $STAGING_PREFIX)
  {
    echo "name=$base_name"
    echo "date=$(date -Iseconds)"
    echo "host=$(hostname -f 2>/dev/null || hostname)"
    echo "user=$(id -un)"
    echo "compress=$COMPRESS"
    echo "encryption=$ENCRYPTION"
    echo "tasks_total=${TASKS_TOTAL:-0}"
    echo "tasks_ok=${TASKS_OK:-0}"
    echo "tasks_fail=${TASKS_FAIL:-0}"
  } > "${tmp_dir}/MANIFEST.txt"

  info "Creating TAR (phase 1: system paths from include list)"
  local tar_create_opts=(
    --create
    --file "$tmp_tar"
    --xattrs --acls --numeric-owner --preserve-permissions
    --ignore-failed-read
    --warning=no-file-ignored
  )
  [ "$ONE_FS" = "1" ] && tar_create_opts+=( --one-file-system )
  [ "$EXCLUDE_CACHES" = "1" ] && tar_create_opts+=( --exclude-caches-all --exclude-backups )
  [ "$SPARSE" = "1" ] && tar_create_opts+=( --sparse )

  info "Tar include list:"
  tr '\0' '\n' < "$include_list" | sed 's/^/  - /' | tee -a "$LOG_FILE" >&2
  run_safe "tar create (system paths)" \
    tar "${tar_create_opts[@]}" \
        "${excludes[@]}" \
        -C / --null --files-from="$include_list"

  info "Appending extras from tasks under ${STAGING_PREFIX}/"
  run_safe "tar append (extras)" \
    tar --append \
        --file "$tmp_tar" \
        --transform "s,^,${STAGING_PREFIX}/," \
        -C "$tmp_dir" .

  # Count files & size before compression/encryption
  local tar_files
  tar_files=$(tar -tf "$tmp_tar" 2>>"$LOG_FILE" | wc -l || echo 0)
  local tar_size
  tar_size=$(stat -c%s "$tmp_tar" 2>/dev/null || echo 0)

  # Compression
  local compressed_path="${TMP_WORK}/${base_name}.compressed"
  case "$COMPRESS" in
    zstd)
      compressor="zstd"
      info "Compressing with zstd"
      run_safe "zstd compress" zstd -q -T0 -19 -f -o "$compressed_path" "$tmp_tar"
      ;;
    xz)
      compressor="xz"
      info "Compressing with xz"
      run_safe "xz compress" xz -T0 -9 -c "$tmp_tar" > "$compressed_path"
      ;;
    gz|gzip)
      compressor="gzip"
      info "Compressing with gzip"
      run_safe "gzip compress" gzip -9 -c "$tmp_tar" > "$compressed_path"
      ;;
    none|"")
      info "No compression"
      run_safe "copy tar" cp -f "$tmp_tar" "$compressed_path"
      ;;
    *)
      warn "Unknown COMPRESS=$COMPRESS, falling back to no compression."
      run_safe "copy tar" cp -f "$tmp_tar" "$compressed_path"
      ;;
  esac

  # Encryption (optional)
  local staged_final="$compressed_path"
  if [ "$ENCRYPTION" = "gpg" ]; then
    if require_cmd gpg && [ -n "$GPG_RECIPIENT" ]; then
      local enc="${compressed_path}.gpg"
      info "Encrypting with GPG (recipient: $GPG_RECIPIENT)"
      run_safe "gpg encrypt" gpg --batch --yes --output "$enc" --encrypt --recipient "$GPG_RECIPIENT" "$compressed_path"
      if [ -f "$enc" ]; then
        chmod 600 "$enc"
        staged_final="$enc"
      else
        warn "GPG encryption failed; leaving unencrypted archive."
      fi
    else
      warn "ENCRYPTION=gpg but gpg or GPG_RECIPIENT missing; skipping encryption."
    fi
  fi

  # Move into place (supports overwrite)
  mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
  if [ -e "$final_path" ] && [ "${OVERWRITE:-0}" = "1" ]; then
    info "Overwrite enabled: replacing $(basename "$final_path")"
    rm -f "$final_path" 2>/dev/null || true
  fi
  mv -f "$staged_final" "$final_path"

  chmod 600 "$final_path" 2>/dev/null || true
  write_checksum "$final_path"
  verify_archive "$final_path"
  prune_old_archives

  END_EPOCH=$(date +%s)
  local elapsed=$((END_EPOCH - START_EPOCH))
  local final_size
  final_size=$(stat -c%s "$final_path" 2>/dev/null || echo 0)

  # Summary
  {
    echo "=== Backup Summary ==="
    echo "Date: $(date)"
    echo "Output: $final_path"
    echo "Compression: ${COMPRESS}"
    echo "Encryption: ${ENCRYPTION}"
    echo "Files in TAR: ${tar_files}"
    echo "TAR size (before compression): $(human_size "$tar_size")"
    echo "Final size: $(human_size "$final_size")"
    echo "Tasks: total=${TASKS_TOTAL:-0}, ok=${TASKS_OK:-0}, failed=${TASKS_FAIL:-0}"
    echo "Verify: ${VERIFY:-0}"
    echo "Checksum: ${HASH_ALGO}"
    echo "Elapsed: ${elapsed}s"
    echo "Logs: $LOG_FILE"
  } | tee -a "$LOG_FILE"
}

###############################################################################
# Restore
###############################################################################
do_restore() {
  acquire_lock
  load_config
  init_logging

  local archive="${1:-}"
  if [ -z "$archive" ]; then
    error "No archive provided. Use: $0 restore /path/to/archive.tar[.zst|.xz|.gz|.gpg]"
    return 0
  fi
  if [ ! -f "$archive" ]; then
    error "Archive not found: $archive"
    return 0
  fi

  local target="${TARGET_DIR:-/}"
  if [ "${NON_INTERACTIVE:-0}" != "1" ]; then
    read -r -p "Restore target directory [default=/]: " ans
    [ -n "$ans" ] && target="$ans"
  fi
  mkdir -p "$target" 2>/dev/null || true

  local tar_opts=(
    --extract
    --xattrs --acls --numeric-owner --preserve-permissions
    -C "$target"
  )

  if [ "${KEEP_OLD_FILES:-1}" = "1" ]; then
    tar_opts+=( --keep-old-files )
  fi
  [ "${OVERWRITE:-0}" = "1" ] && tar_opts+=( --overwrite )

  info "Restoring to: $target"
  info "Keep old files: ${KEEP_OLD_FILES:-1} (use --overwrite to replace)"
  info "Archive: $archive"

  # Preview?
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "Dry-run: listing archive contents only."
    if [[ "$archive" =~ \.gpg$ ]]; then
      run_safe "gpg decrypt | list" \
        sh -c 'gpg --batch -q --decrypt "$1" | tar -t' _ "$archive"
    elif [[ "$archive" =~ \.zst$ ]]; then
      run_safe "zstdcat | list" sh -c 'zstd -dc -q "$1" | tar -t' _ "$archive"
    elif [[ "$archive" =~ \.xz$ ]]; then
      run_safe "xzcat | list" sh -c 'xz -dc "$1" | tar -t' _ "$archive"
    elif [[ "$archive" =~ \.gz$ ]]; then
      run_safe "gzcat | list" sh -c 'gzip -dc "$1" | tar -t' _ "$archive"
    else
      run_safe "tar -t" tar -tf "$archive"
    fi
    return 0
  fi

  # Confirm if interactive
  if ! ask_yes_no "Proceed with restore to '$target'?"; then
    info "Restore cancelled."
    return 0
  fi

  # Extraction pipeline (streaming)
  if [[ "$archive" =~ \.gpg$ ]]; then
    if ! require_cmd gpg; then
      error "gpg not available; cannot decrypt."
      return 0
    fi
    if [[ "$archive" =~ \.tar\.zst\.gpg$ ]]; then
      run_safe "restore gpg+zstd" sh -c 'gpg --batch -q --decrypt "$1" | zstd -dc -q | tar "${@:2}"' _ "$archive" "${tar_opts[@]}"
    elif [[ "$archive" =~ \.tar\.xz\.gpg$ ]]; then
      run_safe "restore gpg+xz"   sh -c 'gpg --batch -q --decrypt "$1" | xz -dc    | tar "${@:2}"' _ "$archive" "${tar_opts[@]}"
    elif [[ "$archive" =~ \.tar\.gz\.gpg$ ]]; then
      run_safe "restore gpg+gz"   sh -c 'gpg --batch -q --decrypt "$1" | gzip -dc  | tar "${@:2}"' _ "$archive" "${tar_opts[@]}"
    else
      run_safe "restore gpg+tar"  sh -c 'gpg --batch -q --decrypt "$1" | tar "${@:2}"' _ "$archive" "${tar_opts[@]}"
    fi
  elif [[ "$archive" =~ \.zst$ ]]; then
    run_safe "restore zstd" sh -c 'zstd -dc -q "$1" | tar "${@:2}"' _ "$archive" "${tar_opts[@]}"
  elif [[ "$archive" =~ \.xz$ ]]; then
    run_safe "restore xz"   sh -c 'xz -dc "$1" | tar "${@:2}"' _ "$archive" "${tar_opts[@]}"
  elif [[ "$archive" =~ \.gz$ ]]; then
    run_safe "restore gz"   sh -c 'gzip -dc "$1" | tar "${@:2}"' _ "$archive" "${tar_opts[@]}"
  else
    run_safe "restore tar" tar "${tar_opts[@]}" -f "$archive"
  fi

  info "Restore completed. Look for '${STAGING_PREFIX}/' inside '$target' for task outputs (e.g., MANIFEST.txt)."
}

###############################################################################
# CLI parsing
###############################################################################
print_help() {
cat <<EOF
Usage:
  $0 backup [options]
  $0 restore <archive> [options]

Global options:
  -y, --yes                  Non-interactive (assume yes)
  -c, --config FILE          Use a specific config file
  --log-level LEVEL          INFO (default) or DEBUG

Backup options:
  --overwrite                Overwrite if an archive with same name exists
  --compress TYPE            zstd|xz|gz|none (overrides config)
  --encrypt gpg|none         Enable/disable GPG encryption (overrides config)
  --recipient EMAIL          GPG recipient (if --encrypt gpg)
  --verify|--no-verify       Verify archive contents after creation
  --hash ALGO                sha256|sha512|none (sidecar checksum)
  --retention N              Keep N most recent archives (prune older)
  --one-fs                   Use tar --one-file-system
  --no-caches                Disable default cache/backups excludes
  --no-sparse                Disable tar --sparse
  --tag NAME                 Append --NAME to archive file
  --no-task-logs             Do not stream task logs to console
  --tmpdir DIR               Working dir parent (default: OUTPUT_DIR)

Restore options:
  --target DIR               Restore target directory (default: /)
  --dry-run                  List contents only
  --overwrite                Overwrite existing files on restore

Examples:
  $0 backup -y --compress xz --encrypt gpg --recipient you@example.com --verify --retention 7 --tag weekly
  $0 restore ./output/system-backup-20250101-010101.tar.zst --target / --overwrite
EOF
}

MODE=""
OVERWRITE=0
NON_INTERACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    backup) MODE="backup"; shift ;;
    restore) MODE="restore"; shift; ARCHIVE_ARG="${1:-}"; [ -n "${ARCHIVE_ARG:-}" ] && shift ;;
    -y|--yes) NON_INTERACTIVE=1; shift ;;
    -c|--config) CONFIG_FILE="$2"; shift 2 ;;
    --log-level) LOG_LEVEL="$2"; shift 2 ;;
    --overwrite) OVERWRITE=1; KEEP_OLD_FILES=0; shift ;;
    --compress) COMPRESS="$2"; shift 2 ;;
    --encrypt)
      case "$2" in
        gpg) ENCRYPTION="gpg" ;;
        none) ENCRYPTION="none" ;;
        *) ENCRYPTION="none"; warn "Unknown encryption '$2', using none." ;;
      esac
      shift 2
      ;;
    --recipient) GPG_RECIPIENT="$2"; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    --no-verify) VERIFY=0; shift ;;
    --hash) HASH_ALGO="$2"; shift 2 ;;
    --retention) RETENTION="$2"; shift 2 ;;
    --one-fs) ONE_FS=1; shift ;;
    --no-caches) EXCLUDE_CACHES=0; shift ;;
    --no-sparse) SPARSE=0; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --no-task-logs) STREAM_TASK_LOGS=0; shift ;;
    --tmpdir) TMPDIR_PARENT="$2"; shift 2 ;;
    --target) TARGET_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) warn "Unknown arg: $1"; shift ;;
  esac
done

export OVERWRITE KEEP_OLD_FILES NON_INTERACTIVE

if [ "$MODE" = "backup" ]; then
  do_backup
elif [ "$MODE" = "restore" ]; then
  do_restore "${ARCHIVE_ARG:-}"
else
  print_help
fi
