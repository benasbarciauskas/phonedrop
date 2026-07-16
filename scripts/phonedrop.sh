#!/usr/bin/env bash
# PhoneDrop — multi-target photo drop to Android (adb) and iOS (AirDrop).
# Compatible with macOS /bin/bash 3.2 (launchd) and modern bash.
set -euo pipefail

CONFIG_DIR="${PHONEDROP_CONFIG_DIR:-${HOME}/.config/phonedrop}"
CONFIG_FILE="${PHONEDROP_CONFIG_FILE:-${CONFIG_DIR}/config}"
TARGETS_FILE="${PHONEDROP_TARGETS_FILE:-${CONFIG_DIR}/targets.conf}"
TARGETS_D="${PHONEDROP_TARGETS_D:-${CONFIG_DIR}/targets.d}"
SUPPORT_DIR="${HOME}/Library/Application Support/PhoneDrop"
APP_DEST="${HOME}/Applications/PhoneDrop.app"
DROP_ROOT_DEFAULT="${HOME}/PhoneDrop"
AUTOARM_LABEL="com.phonedrop.autoarm"
AUTOARM_PLIST="${HOME}/Library/LaunchAgents/${AUTOARM_LABEL}.plist"
AUTOARM_LOG="${HOME}/Library/Logs/phonedrop-autoarm.log"
WATCH_LABEL_PREFIX="com.phonedrop.watch"
WATCH_LOG_DIR="${HOME}/Library/Logs"

PHONE_HOST="${PHONE_HOST:-}"
ADB_PORT="${ADB_PORT:-5555}"
DEST="${DEST:-/sdcard/DCIM/PhoneDrop/}"
ADB_BIN="${ADB_BIN:-/opt/homebrew/bin/adb}"
OSASCRIPT_BIN="${OSASCRIPT_BIN:-osascript}"
EXIFTOOL_BIN="${EXIFTOOL_BIN:-/opt/homebrew/bin/exiftool}"
TAILSCALE_BIN="${TAILSCALE_BIN:-/usr/local/bin/tailscale}"
AIRDROP_BIN="${PHONEDROP_AIRDROP_BIN:-}"
SWIFT_BIN="${SWIFT_BIN:-/usr/bin/swift}"

IMAGE_EXTS="jpg jpeg png tif tiff heic heif webp bmp gif"

# Parallel target arrays (bash 3.2 — no associative arrays)
TARGET_NAMES=()
TARGET_PLATFORM=()
TARGET_PHONE_HOST=()
TARGET_ADB_PORT=()
TARGET_SERIAL=()
TARGET_DEST=()
TARGET_AIRDROP=()
TARGET_STRIP=()
TARGET_DROP_FOLDER=()
TARGET_ON_SEND=()

# ---------------------------------------------------------------------------
# Basics
# ---------------------------------------------------------------------------
load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
  fi
}

expand_path() {
  local p="$1"
  case "${p}" in
    "~")   printf '%s' "${HOME}" ;;
    "~/"*) printf '%s' "${HOME}/${p#~/}" ;;
    *)     printf '%s' "${p}" ;;
  esac
}

validate_dest() {
  if [[ ! "${DEST}" =~ ^[A-Za-z0-9./_-]+$ ]]; then
    echo "phonedrop: error: DEST config value contains unsafe characters: ${DEST}" >&2
    exit 1
  fi
}

sanitise_basename() {
  local name="$1"
  local safe
  safe=$(printf '%s' "${name}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')
  safe="${safe#-}"
  if [[ -z "${safe}" || "${safe}" == "." || "${safe}" == ".." ]]; then
    echo "phonedrop: error: sanitised filename is empty or reserved: '${name}'" >&2
    return 1
  fi
  printf '%s' "${safe}"
}

sanitise_target_name() {
  local name="$1"
  local safe
  safe=$(printf '%s' "${name}" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-')
  safe=$(printf '%s' "${safe}" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')
  if [[ -z "${safe}" ]]; then
    echo "phonedrop: error: invalid target name: '${name}'" >&2
    return 1
  fi
  printf '%s' "${safe}"
}

sq_escape() {
  local s="$1"
  printf '%s' "${s}" | sed "s/'/'\\\\''/g"
}

osa_argv() {
  local script="$1"; shift
  "${OSASCRIPT_BIN}" - "$@" <<OSA 2>/dev/null || true
$script
OSA
}

notify() {
  local title="$1" msg="$2"
  osa_argv 'on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run' "$title" "$msg"
}

notify_error() {
  local title="$1" msg="$2"
  osa_argv 'on run argv
  display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK" with icon stop
end run' "$title" "$msg"
}

die() {
  local msg="$*"
  echo "phonedrop: error: ${msg}" >&2
  notify_error "PhoneDrop Error" "${msg}"
  exit 1
}

require_tool() {
  local bin="$1"
  local name="$2"
  [[ -x "${bin}" ]] || die "${name} not found at ${bin}. Run: phonedrop.sh install"
}

is_image_ext() {
  local ext
  ext=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  local imgext
  for imgext in ${IMAGE_EXTS}; do
    [[ "${ext}" == "${imgext}" ]] && return 0
  done
  return 1
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# ---------------------------------------------------------------------------
# Multi-target config (targets.conf + targets.d/*.conf)
# ---------------------------------------------------------------------------
target_count() {
  printf '%s' "${#TARGET_NAMES[@]}"
}

target_index() {
  local want="$1" i
  i=0
  while [[ ${i} -lt ${#TARGET_NAMES[@]} ]]; do
    if [[ "${TARGET_NAMES[i]}" == "${want}" ]]; then
      printf '%s' "${i}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

target_exists() {
  target_index "$1" >/dev/null 2>&1
}

target_get() {
  # target_get <name> <field>
  local name="$1" field="$2" idx
  idx=$(target_index "${name}") || return 1
  case "${field}" in
    platform)    printf '%s' "${TARGET_PLATFORM[idx]}" ;;
    phone_host)  printf '%s' "${TARGET_PHONE_HOST[idx]}" ;;
    adb_port)    printf '%s' "${TARGET_ADB_PORT[idx]}" ;;
    serial)      printf '%s' "${TARGET_SERIAL[idx]}" ;;
    dest)        printf '%s' "${TARGET_DEST[idx]}" ;;
    airdrop)     printf '%s' "${TARGET_AIRDROP[idx]}" ;;
    strip)       printf '%s' "${TARGET_STRIP[idx]}" ;;
    drop_folder) printf '%s' "${TARGET_DROP_FOLDER[idx]}" ;;
    on_send)     printf '%s' "${TARGET_ON_SEND[idx]}" ;;
    *) return 1 ;;
  esac
}

target_set_field() {
  local name="$1" field="$2" val="$3" idx
  if ! idx=$(target_index "${name}"); then
    return 1
  fi
  case "${field}" in
    platform)    TARGET_PLATFORM[idx]="${val}" ;;
    phone_host)  TARGET_PHONE_HOST[idx]="${val}" ;;
    adb_port)    TARGET_ADB_PORT[idx]="${val}" ;;
    serial)      TARGET_SERIAL[idx]="${val}" ;;
    dest)        TARGET_DEST[idx]="${val}" ;;
    airdrop)     TARGET_AIRDROP[idx]="${val}" ;;
    strip)       TARGET_STRIP[idx]="${val}" ;;
    drop_folder) TARGET_DROP_FOLDER[idx]="${val}" ;;
    on_send)     TARGET_ON_SEND[idx]="${val}" ;;
    *) return 1 ;;
  esac
}

target_add_or_update() {
  # args: name platform host port serial dest airdrop strip drop on_send
  local name="$1" platform="$2" host="$3" port="$4" serial="$5"
  local dest="$6" airdrop="$7" strip="$8" drop="$9" on_send="${10}"
  local idx
  if idx=$(target_index "${name}"); then
    TARGET_PLATFORM[idx]="${platform}"
    TARGET_PHONE_HOST[idx]="${host}"
    TARGET_ADB_PORT[idx]="${port}"
    TARGET_SERIAL[idx]="${serial}"
    TARGET_DEST[idx]="${dest}"
    TARGET_AIRDROP[idx]="${airdrop}"
    TARGET_STRIP[idx]="${strip}"
    TARGET_DROP_FOLDER[idx]="${drop}"
    TARGET_ON_SEND[idx]="${on_send}"
  else
    TARGET_NAMES+=("${name}")
    TARGET_PLATFORM+=("${platform}")
    TARGET_PHONE_HOST+=("${host}")
    TARGET_ADB_PORT+=("${port}")
    TARGET_SERIAL+=("${serial}")
    TARGET_DEST+=("${dest}")
    TARGET_AIRDROP+=("${airdrop}")
    TARGET_STRIP+=("${strip}")
    TARGET_DROP_FOLDER+=("${drop}")
    TARGET_ON_SEND+=("${on_send}")
  fi
}

normalise_strip() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off) printf 'false' ;;
    *)              printf 'true' ;;
  esac
}

normalise_on_send() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    delete|remove|rm) printf 'delete' ;;
    *)                printf 'archive' ;;
  esac
}

normalise_platform() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    ios|iphone|ipad) printf 'ios' ;;
    *)               printf 'android' ;;
  esac
}

unquote_val() {
  local val="$1"
  if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "${val}"
  fi
}

parse_targets_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local section="" line key val
  local plat host port serial dest airdrop strip drop on_send
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    line=$(trim "${line}")
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ "${line}" =~ ^\[([^]]+)\]$ ]]; then
      # flush previous section is unnecessary — we set fields as we go
      section=$(sanitise_target_name "${BASH_REMATCH[1]}") || { section=""; continue; }
      if ! target_exists "${section}"; then
        target_add_or_update "${section}" "android" "" "5555" "" \
          "/sdcard/DCIM/PhoneDrop/" "" "true" \
          "${DROP_ROOT_DEFAULT}/${section}" "archive"
      fi
      continue
    fi
    [[ -z "${section}" ]] && continue
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
      val=$(unquote_val "${BASH_REMATCH[2]}")
      case "${key}" in
        platform)          target_set_field "${section}" platform "$(normalise_platform "${val}")" ;;
        phone_host|host)   target_set_field "${section}" phone_host "${val}" ;;
        adb_port|port)     target_set_field "${section}" adb_port "${val}" ;;
        serial)            target_set_field "${section}" serial "${val}" ;;
        dest)              target_set_field "${section}" dest "${val}" ;;
        airdrop_recipient|recipient|airdrop)
                           target_set_field "${section}" airdrop "${val}" ;;
        strip_metadata|strip)
                           target_set_field "${section}" strip "$(normalise_strip "${val}")" ;;
        drop_folder|folder)
                           target_set_field "${section}" drop_folder "$(expand_path "${val}")" ;;
        on_send|after_send)
                           target_set_field "${section}" on_send "$(normalise_on_send "${val}")" ;;
      esac
    fi
  done < "${file}"
}

clear_targets() {
  TARGET_NAMES=()
  TARGET_PLATFORM=()
  TARGET_PHONE_HOST=()
  TARGET_ADB_PORT=()
  TARGET_SERIAL=()
  TARGET_DEST=()
  TARGET_AIRDROP=()
  TARGET_STRIP=()
  TARGET_DROP_FOLDER=()
  TARGET_ON_SEND=()
}

load_targets() {
  clear_targets
  parse_targets_file "${TARGETS_FILE}"
  if [[ -d "${TARGETS_D}" ]]; then
    local f
    for f in "${TARGETS_D}"/*.conf; do
      [[ -f "${f}" ]] || continue
      parse_targets_file "${f}"
    done
  fi
  # expand any remaining ~ in drop folders
  local i drop
  i=0
  while [[ ${i} -lt ${#TARGET_NAMES[@]} ]]; do
    drop=$(expand_path "${TARGET_DROP_FOLDER[i]}")
    TARGET_DROP_FOLDER[i]="${drop}"
    TARGET_STRIP[i]=$(normalise_strip "${TARGET_STRIP[i]}")
    TARGET_ON_SEND[i]=$(normalise_on_send "${TARGET_ON_SEND[i]}")
    TARGET_PLATFORM[i]=$(normalise_platform "${TARGET_PLATFORM[i]}")
    i=$((i + 1))
  done
}

ensure_legacy_target() {
  load_config
  load_targets
  if [[ ${#TARGET_NAMES[@]} -eq 0 ]] && [[ -n "${PHONE_HOST}" ]] && [[ "${PHONE_HOST}" != "YOUR_PHONE_HOSTNAME" ]]; then
    target_add_or_update "default" "android" "${PHONE_HOST}" "${ADB_PORT}" "" \
      "${DEST}" "" "true" "${DROP_ROOT_DEFAULT}/default" "archive"
  fi
}

write_target_block() {
  local name="$1"
  cat <<EOF
[${name}]
platform=$(target_get "${name}" platform)
phone_host=$(target_get "${name}" phone_host)
adb_port=$(target_get "${name}" adb_port)
serial=$(target_get "${name}" serial)
dest=$(target_get "${name}" dest)
airdrop_recipient=$(target_get "${name}" airdrop)
strip_metadata=$(target_get "${name}" strip)
drop_folder=$(target_get "${name}" drop_folder)
on_send=$(target_get "${name}" on_send)
EOF
}

persist_all_targets() {
  mkdir -p "${CONFIG_DIR}"
  local i name
  {
    echo "# PhoneDrop multi-target configuration"
    echo "# Managed by phonedrop.sh — prefer: add-phone / remove-phone / config"
    echo "# You may also drop files into ${TARGETS_D}/*.conf"
    echo ""
    i=0
    while [[ ${i} -lt ${#TARGET_NAMES[@]} ]]; do
      name="${TARGET_NAMES[i]}"
      write_target_block "${name}"
      echo ""
      i=$((i + 1))
    done
  } > "${TARGETS_FILE}"
}

require_target() {
  local name="$1"
  ensure_legacy_target
  target_exists "${name}" || die "Unknown phone target '${name}'. Run: phonedrop.sh list"
}

apply_target_to_globals() {
  local name="$1"
  local plat
  plat=$(target_get "${name}" platform)
  if [[ "${plat}" == "android" ]]; then
    PHONE_HOST=$(target_get "${name}" phone_host)
    ADB_PORT=$(target_get "${name}" adb_port)
    DEST=$(target_get "${name}" dest)
  fi
}

resolve_push_target() {
  local explicit="${1:-}"
  ensure_legacy_target
  if [[ -n "${explicit}" ]]; then
    require_target "${explicit}"
    printf '%s' "${explicit}"
    return 0
  fi
  if [[ -n "${PHONEDROP_TARGET:-}" ]]; then
    require_target "${PHONEDROP_TARGET}"
    printf '%s' "${PHONEDROP_TARGET}"
    return 0
  fi
  if [[ ${#TARGET_NAMES[@]} -eq 1 ]]; then
    printf '%s' "${TARGET_NAMES[0]}"
    return 0
  fi
  if [[ ${#TARGET_NAMES[@]} -eq 0 ]]; then
    load_config
    [[ -n "${PHONE_HOST}" ]] || die "No targets configured. Run: phonedrop.sh add-phone  (or set PHONE_HOST in ${CONFIG_FILE})"
    printf '%s' ""
    return 0
  fi
  die "Multiple phone targets configured; specify one with: phonedrop.sh push --target <name> <files...>"
}

# ---------------------------------------------------------------------------
# adb helpers
# ---------------------------------------------------------------------------
adb_device_serials() {
  "${ADB_BIN}" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" {print $1}'
}

usb_adb_serials() {
  adb_device_serials | awk '$0 !~ /:/'
}

single_usb_device() {
  local serial first="" count=0
  while IFS= read -r serial; do
    [[ -n "${serial}" ]] || continue
    count=$((count + 1))
    [[ -z "${first}" ]] && first="${serial}"
  done < <(usb_adb_serials)
  [[ "${count}" -eq 1 ]] && { printf '%s\n' "${first}"; return 0; }
  [[ "${count}" -eq 0 ]] && return 1
  return 2
}

select_adb_target() {
  local preferred_serial="${1:-}"
  local remote="${PHONE_HOST}:${ADB_PORT}" state serials first count
  if [[ -n "${preferred_serial}" ]]; then
    state=$("${ADB_BIN}" -s "${preferred_serial}" get-state 2>/dev/null || true)
    [[ "${state}" == "device" ]] && { printf '%s\n' "${preferred_serial}"; return 0; }
  fi
  if [[ -n "${PHONE_HOST}" ]]; then
    state=$("${ADB_BIN}" -s "${remote}" get-state 2>/dev/null || true)
    [[ "${state}" == "device" ]] && { printf '%s\n' "${remote}"; return 0; }
  fi
  serials=$(adb_device_serials)
  first=$(printf '%s\n' "${serials}" | awk 'NF {print; exit}')
  count=$(printf '%s\n' "${serials}" | awk 'NF {c++} END {print c+0}')
  [[ "${count}" -gt 0 ]] || return 1
  [[ "${count}" -eq 1 ]] && { printf '%s\n' "${first}"; return 0; }
  printf '%s\n' "${serials}" | grep -Fxq "${remote}" && { printf '%s\n' "${remote}"; return 0; }
  printf '%s\n' "${first}"
}

arm_wireless() {
  local quiet="${1:-0}" usb_serial result="" attempt
  usb_serial=$(single_usb_device) || return $?
  [[ "${quiet}" == "1" ]] || echo "phonedrop: enabling adb tcpip ${ADB_PORT} on ${usb_serial} ..."
  if [[ "${quiet}" == "1" ]]; then
    "${ADB_BIN}" -s "${usb_serial}" tcpip "${ADB_PORT}" >/dev/null 2>&1 || true
  else
    "${ADB_BIN}" -s "${usb_serial}" tcpip "${ADB_PORT}"
    echo "phonedrop: reconnecting to ${PHONE_HOST}:${ADB_PORT} ..."
  fi
  for attempt in 1 2 3 4 5 6; do
    if [[ "${attempt}" -gt 1 ]]; then
      sleep "${PHONEDROP_REARM_SLEEP:-2}"
      [[ "${quiet}" == "1" ]] || echo "phonedrop: waiting for wireless adb to come up (attempt ${attempt}/6) ..."
    fi
    result=$("${ADB_BIN}" connect "${PHONE_HOST}:${ADB_PORT}" 2>&1) || true
    if echo "${result}" | grep -qiE "connected|already connected"; then
      [[ "${quiet}" == "1" ]] || echo "phonedrop: reconnected: ${result}"
      return 0
    fi
  done
  [[ "${quiet}" == "1" ]] || echo "phonedrop: wireless adb rearm sent; connect did not succeed yet — try again in a moment"
  return 1
}

autoarm_log() {
  echo "phonedrop autoarm $(date '+%Y-%m-%d %H:%M:%S'): $*" >&2
}

# ---------------------------------------------------------------------------
# Prepare copy (never mutates source). Strip only when strip_flag=true.
# ---------------------------------------------------------------------------
prepare_send_copy() {
  local src="$1" dest_path="$2" strip_flag="$3"
  cp -- "${src}" "${dest_path}"
  local base ext
  base=$(basename "${dest_path}")
  ext="${base##*.}"
  if [[ "${strip_flag}" == "true" ]] && is_image_ext "${ext}"; then
    require_tool "${EXIFTOOL_BIN}" "exiftool"
    "${EXIFTOOL_BIN}" -overwrite_original -all= "${dest_path}" >/dev/null 2>&1 || {
      echo "phonedrop: warning: exiftool strip failed for ${base}, sending copy as-is" >&2
    }
  fi
}

# ---------------------------------------------------------------------------
# iOS AirDrop helper resolution
# ---------------------------------------------------------------------------
resolve_airdrop_helper() {
  if [[ -n "${AIRDROP_BIN}" ]]; then
    printf '%s' "${AIRDROP_BIN}"
    return 0
  fi
  local installed="${SUPPORT_DIR}/phonedrop-airdrop.swift"
  local beside
  beside="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/phonedrop-airdrop.swift"
  if [[ -f "${installed}" ]]; then
    printf '%s' "${installed}"
    return 0
  fi
  if [[ -f "${beside}" ]]; then
    printf '%s' "${beside}"
    return 0
  fi
  return 1
}

send_ios_airdrop() {
  local recipient="$1"
  shift
  local helper
  if ! helper=$(resolve_airdrop_helper); then
    die "AirDrop helper not found. Re-run: phonedrop.sh install"
  fi
  local args=()
  if [[ -n "${recipient}" ]]; then
    args+=(--recipient "${recipient}")
  fi
  # append files
  local f
  for f in "$@"; do
    args+=("${f}")
  done
  if [[ "${helper}" == *.swift ]]; then
    require_tool "${SWIFT_BIN}" "swift"
    "${SWIFT_BIN}" "${helper}" "${args[@]}"
  else
    # external binary / test stub
    if [[ -x "${helper}" ]]; then
      "${helper}" "${args[@]}"
    else
      die "AirDrop helper not executable: ${helper}"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Push files to a named target (or legacy empty name)
# ---------------------------------------------------------------------------
push_files_to_target() {
  local target_name="$1"
  shift

  if [[ $# -eq 0 ]]; then
    echo "Usage: phonedrop.sh push [--target <name>] <file> [file ...]" >&2
    exit 1
  fi

  load_config
  local platform="android" strip="true" serial="" recipient=""
  if [[ -n "${target_name}" ]]; then
    require_target "${target_name}"
    platform=$(target_get "${target_name}" platform)
    strip=$(target_get "${target_name}" strip)
    serial=$(target_get "${target_name}" serial)
    recipient=$(target_get "${target_name}" airdrop)
    apply_target_to_globals "${target_name}"
  else
    [[ -f "${CONFIG_FILE}" ]] || die "Config not found. Run: phonedrop.sh install"
    [[ -n "${PHONE_HOST}" ]] || die "PHONE_HOST not set in ${CONFIG_FILE}. Edit it or run: phonedrop.sh add-phone"
    platform="android"
    strip="true"
  fi

  if [[ "${platform}" == "android" ]]; then
    require_tool "${ADB_BIN}" "adb"
    validate_dest
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)
  # Clean temp on exit of this shell process; nested EXIT traps overwrite — clean manually too
  local prepared_list="${tmp_dir}/.prepared"
  : > "${prepared_list}"

  local failed=0 last_error="" src raw_basename safe_basename tmp_copy ext
  for src in "$@"; do
    if [[ ! -f "${src}" ]]; then
      echo "phonedrop: skipping (not a file): ${src}" >&2
      failed=$((failed + 1))
      last_error="not a file: ${src}"
      continue
    fi
    raw_basename=$(basename "${src}")
    if ! safe_basename=$(sanitise_basename "${raw_basename}"); then
      echo "phonedrop: skipping (unsafe filename): ${raw_basename}" >&2
      failed=$((failed + 1))
      last_error="unsafe filename: ${raw_basename}"
      continue
    fi
    tmp_copy="${tmp_dir}/${safe_basename}"
    if [[ -e "${tmp_copy}" ]]; then
      local n=1
      if [[ "${safe_basename}" == *.* ]]; then
        while [[ -e "${tmp_dir}/${safe_basename%.*}_${n}.${safe_basename##*.}" ]]; do n=$((n + 1)); done
        tmp_copy="${tmp_dir}/${safe_basename%.*}_${n}.${safe_basename##*.}"
      else
        while [[ -e "${tmp_dir}/${safe_basename}_${n}" ]]; do n=$((n + 1)); done
        tmp_copy="${tmp_dir}/${safe_basename}_${n}"
      fi
    fi
    prepare_send_copy "${src}" "${tmp_copy}" "${strip}"
    printf '%s\0' "${tmp_copy}" >> "${prepared_list}"
  done

  local prepared=()
  # bash 3.2: read null-delimited
  while IFS= read -r -d '' src; do
    prepared+=("${src}")
  done < "${prepared_list}"

  if [[ ${#prepared[@]} -eq 0 ]]; then
    rm -rf "${tmp_dir}"
    die "All ${failed} file(s) failed. Last error: ${last_error}"
  fi

  local pushed=0 send_failed=0 stamp
  stamp="${PHONEDROP_STAMP:-$(date +%Y%m%d_%H%M%S)}"

  if [[ "${platform}" == "ios" ]]; then
    if send_ios_airdrop "${recipient}" "${prepared[@]}"; then
      pushed=${#prepared[@]}
      echo "phonedrop: AirDrop sent ${pushed} file(s) to '${recipient:-AirDrop}'"
    else
      send_failed=${#prepared[@]}
      last_error="AirDrop send failed"
    fi
  else
    # Android adb path (mirrors original single-target logic)
    "${ADB_BIN}" connect "${PHONE_HOST}:${ADB_PORT}" >/dev/null 2>&1 || true
    local adb_target dest_safe
    if ! adb_target=$(select_adb_target "${serial}"); then
      rm -rf "${tmp_dir}"
      die "PhoneDrop couldn't send — your phone isn't reachable (off, asleep, or wireless adb not armed after a reboot). Plug it into USB to re-arm, or check it's connected on Tailscale."
    fi
    dest_safe="$(sq_escape "${DEST}")"
    "${ADB_BIN}" -s "${adb_target}" shell "mkdir -p '${dest_safe}'" 2>/dev/null || true

    local seen_dir phone_path phone_path_safe base seen_file count stem fext
    seen_dir=$(mktemp -d)
    for src in "${prepared[@]}"; do
      base=$(basename "${src}")
      seen_file="${seen_dir}/${base}.count"
      if [[ -f "${seen_file}" ]]; then
        count=$(cat "${seen_file}")
        count=$((count + 1))
        printf '%s' "${count}" > "${seen_file}"
        stem="${base%.*}"
        fext="${base##*.}"
        if [[ "${fext}" == "${base}" ]]; then
          base="${base}_${count}"
        else
          base="${stem}_${count}.${fext}"
        fi
      else
        printf '0' > "${seen_file}"
      fi
      phone_path="${DEST}${stamp}_${base}"
      if "${ADB_BIN}" -s "${adb_target}" push "${src}" "${phone_path}" >/dev/null 2>&1; then
        phone_path_safe="$(sq_escape "${phone_path}")"
        "${ADB_BIN}" -s "${adb_target}" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://${phone_path_safe}'" >/dev/null 2>&1 || true
        pushed=$((pushed + 1))
        echo "phonedrop: pushed ${base} → ${phone_path}"
      else
        send_failed=$((send_failed + 1))
        last_error="adb push failed for ${base}"
        echo "phonedrop: error: ${last_error}" >&2
      fi
    done
    rm -rf "${seen_dir}"
  fi

  rm -rf "${tmp_dir}"

  if [[ "${pushed}" -gt 0 ]] && [[ "${send_failed}" -eq 0 ]] && [[ "${failed}" -eq 0 ]]; then
    if [[ -n "${target_name}" ]]; then
      notify "PhoneDrop" "Sent ${pushed} photo(s) to ${target_name}"
    else
      notify "PhoneDrop" "Sent ${pushed} photo(s) to phone"
    fi
    return 0
  elif [[ "${pushed}" -gt 0 ]]; then
    notify "PhoneDrop" "Sent ${pushed} photo(s); $((send_failed + failed)) failed"
    return 0
  else
    die "All $((send_failed + failed)) file(s) failed. Last error: ${last_error}"
  fi
}

# ---------------------------------------------------------------------------
# Drop folders
# ---------------------------------------------------------------------------
archive_or_delete() {
  local on_send="$1" drop_folder="$2" src="$3"
  if [[ "${on_send}" == "delete" ]]; then
    rm -f -- "${src}"
    echo "phonedrop: removed ${src}"
  else
    local sent_dir="${drop_folder}/sent"
    mkdir -p "${sent_dir}"
    local base dest
    base=$(basename "${src}")
    dest="${sent_dir}/${base}"
    if [[ -e "${dest}" ]]; then
      dest="${sent_dir}/$(date +%Y%m%d_%H%M%S)_${base}"
    fi
    mv -- "${src}" "${dest}"
    echo "phonedrop: archived → ${dest}"
  fi
}

process_drop_folder() {
  local target_name="$1"
  require_target "${target_name}"
  local drop_folder on_send
  drop_folder=$(target_get "${target_name}" drop_folder)
  on_send=$(target_get "${target_name}" on_send)
  [[ -d "${drop_folder}" ]] || mkdir -p "${drop_folder}"

  local f
  local files=()
  # top-level files only; skip sent/ and hidden
  for f in "${drop_folder}"/*; do
    [[ -e "${f}" ]] || continue
    [[ -f "${f}" ]] || continue
    case "$(basename "${f}")" in
      .*) continue ;;
    esac
    files+=("${f}")
  done

  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi

  echo "phonedrop: processing ${#files[@]} file(s) for target '${target_name}'"
  if push_files_to_target "${target_name}" "${files[@]}"; then
    for f in "${files[@]}"; do
      [[ -f "${f}" ]] || continue
      archive_or_delete "${on_send}" "${drop_folder}" "${f}"
    done
  fi
}

cmd_watch() {
  local target_name="${1:-}"
  load_config
  ensure_legacy_target
  if [[ -n "${target_name}" ]]; then
    process_drop_folder "${target_name}" || true
    return 0
  fi
  local i
  i=0
  while [[ ${i} -lt ${#TARGET_NAMES[@]} ]]; do
    process_drop_folder "${TARGET_NAMES[i]}" || true
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# launchd watch agents (one per target, WatchPaths on drop folder)
# ---------------------------------------------------------------------------
watch_plist_path() {
  printf '%s' "${HOME}/Library/LaunchAgents/${WATCH_LABEL_PREFIX}.$1.plist"
}

write_watch_plist() {
  local name="$1" drop_folder="$2"
  local plist label log
  plist=$(watch_plist_path "${name}")
  label="${WATCH_LABEL_PREFIX}.${name}"
  log="${WATCH_LOG_DIR}/phonedrop-watch-${name}.log"
  mkdir -p "$(dirname "${plist}")" "${WATCH_LOG_DIR}" "${drop_folder}" "${drop_folder}/sent"
  cat > "${plist}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SUPPORT_DIR}/phonedrop.sh</string>
    <string>watch</string>
    <string>${name}</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>${drop_folder}</string>
  </array>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${log}</string>
  <key>StandardErrorPath</key>
  <string>${log}</string>
  <key>ThrottleInterval</key>
  <integer>2</integer>
</dict>
</plist>
EOF
}

load_watch_agent() {
  local name="$1"
  local plist label
  plist=$(watch_plist_path "${name}")
  label="${WATCH_LABEL_PREFIX}.${name}"
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  if [[ -f "${plist}" ]]; then
    launchctl bootstrap "gui/$(id -u)" "${plist}" 2>/dev/null || \
      echo "phonedrop: warning: could not load watch agent for ${name}" >&2
  fi
}

unload_watch_agent() {
  local name="$1"
  local plist label
  plist=$(watch_plist_path "${name}")
  label="${WATCH_LABEL_PREFIX}.${name}"
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  rm -f "${plist}"
}

sync_all_watch_agents() {
  ensure_legacy_target
  local existing base tn i name drop_folder
  for existing in "${HOME}/Library/LaunchAgents/${WATCH_LABEL_PREFIX}".*.plist; do
    [[ -f "${existing}" ]] || continue
    base=$(basename "${existing}" .plist)
    tn="${base#${WATCH_LABEL_PREFIX}.}"
    if ! target_exists "${tn}"; then
      unload_watch_agent "${tn}"
    fi
  done
  i=0
  while [[ ${i} -lt ${#TARGET_NAMES[@]} ]]; do
    name="${TARGET_NAMES[i]}"
    drop_folder=$(target_get "${name}" drop_folder)
    mkdir -p "${drop_folder}" "${drop_folder}/sent"
    write_watch_plist "${name}" "${drop_folder}"
    load_watch_agent "${name}"
    echo "phonedrop: watch agent for '${name}' → ${drop_folder}"
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
# CLI: list / add / remove / config
# ---------------------------------------------------------------------------
cmd_list() {
  ensure_legacy_target
  if [[ ${#TARGET_NAMES[@]} -eq 0 ]]; then
    echo "No phone targets configured."
    echo "Add one:  phonedrop.sh add-phone"
    echo "Or set PHONE_HOST in ${CONFIG_FILE} (legacy single Android target)."
    return 0
  fi
  printf '%-16s %-8s %-8s %-36s %s\n' "NAME" "PLATFORM" "STRIP" "DROP_FOLDER" "TRANSPORT"
  local i name plat strip folder transport
  i=0
  while [[ ${i} -lt ${#TARGET_NAMES[@]} ]]; do
    name="${TARGET_NAMES[i]}"
    plat=$(target_get "${name}" platform)
    strip=$(target_get "${name}" strip)
    folder=$(target_get "${name}" drop_folder)
    if [[ "${plat}" == "ios" ]]; then
      transport="AirDrop:$(target_get "${name}" airdrop)"
    else
      transport="adb:$(target_get "${name}" phone_host):$(target_get "${name}" adb_port)"
    fi
    printf '%-16s %-8s %-8s %-36s %s\n' "${name}" "${plat}" "${strip}" "${folder}" "${transport}"
    i=$((i + 1))
  done
}

cmd_add_phone() {
  load_config
  load_targets
  local name="" platform="android" phone_host="" adb_port="5555" serial=""
  local dest="/sdcard/DCIM/PhoneDrop/" airdrop="" strip="true"
  local drop_folder="" on_send="archive"
  local nonint=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --platform) platform="$2"; shift 2 ;;
      --host|--phone-host) phone_host="$2"; shift 2 ;;
      --port|--adb-port) adb_port="$2"; shift 2 ;;
      --serial) serial="$2"; shift 2 ;;
      --dest) dest="$2"; shift 2 ;;
      --recipient|--airdrop) airdrop="$2"; shift 2 ;;
      --strip) strip="$2"; shift 2 ;;
      --no-strip) strip="false"; shift ;;
      --folder|--drop-folder) drop_folder="$2"; shift 2 ;;
      --on-send) on_send="$2"; shift 2 ;;
      --yes|-y) nonint=1; shift ;;
      -*) die "Unknown option: $1" ;;
      *)
        if [[ -z "${name}" ]]; then name="$1"; shift
        else die "Unexpected argument: $1"; fi
        ;;
    esac
  done

  if [[ -z "${name}" ]]; then
    if [[ -t 0 && "${nonint}" -eq 0 ]]; then
      read -r -p "Phone name (e.g. pixel, iphone): " name
    else
      die "Usage: phonedrop.sh add-phone --name <name> --platform android|ios [options]"
    fi
  fi
  name=$(sanitise_target_name "${name}") || exit 1

  if [[ -t 0 && "${nonint}" -eq 0 && -z "${platform}" ]]; then
    local p_in
    read -r -p "Platform [android/ios] (default android): " p_in
    platform="${p_in:-android}"
  fi
  platform=$(normalise_platform "${platform}")

  if [[ "${platform}" == "android" ]]; then
    if [[ -z "${phone_host}" ]]; then
      if [[ -t 0 && "${nonint}" -eq 0 ]]; then
        read -r -p "Tailscale hostname / PHONE_HOST: " phone_host
      fi
      [[ -n "${phone_host}" ]] || phone_host="${PHONE_HOST:-}"
      [[ -n "${phone_host}" ]] || die "Android targets need --host <PHONE_HOST>"
    fi
  else
    if [[ -z "${airdrop}" ]]; then
      if [[ -t 0 && "${nonint}" -eq 0 ]]; then
        read -r -p "AirDrop recipient name (as shown in AirDrop): " airdrop
      fi
      [[ -n "${airdrop}" ]] || die "iOS targets need --recipient <AirDrop device name>"
    fi
  fi

  if [[ -z "${drop_folder}" ]]; then
    drop_folder="${DROP_ROOT_DEFAULT}/${name}"
  fi
  drop_folder=$(expand_path "${drop_folder}")
  strip=$(normalise_strip "${strip}")
  on_send=$(normalise_on_send "${on_send}")

  if target_exists "${name}"; then
    echo "phonedrop: updating existing target '${name}'"
  else
    echo "phonedrop: adding target '${name}'"
  fi
  target_add_or_update "${name}" "${platform}" "${phone_host}" "${adb_port}" "${serial}" \
    "${dest}" "${airdrop}" "${strip}" "${drop_folder}" "${on_send}"
  persist_all_targets
  mkdir -p "${drop_folder}" "${drop_folder}/sent"

  if [[ "${platform}" == "android" ]]; then
    mkdir -p "${CONFIG_DIR}"
    if [[ ! -f "${CONFIG_FILE}" ]]; then
      cat > "${CONFIG_FILE}" << EOF
# PhoneDrop global / legacy configuration
PHONE_HOST="${phone_host}"
ADB_PORT="${adb_port}"
DEST="${dest}"
ADB_BIN="${ADB_BIN}"
EXIFTOOL_BIN="${EXIFTOOL_BIN}"
TAILSCALE_BIN="${TAILSCALE_BIN}"
EOF
    elif [[ -z "${PHONE_HOST}" || "${PHONE_HOST}" == "YOUR_PHONE_HOSTNAME" ]]; then
      if grep -q '^PHONE_HOST=' "${CONFIG_FILE}" 2>/dev/null; then
        sed -i '' -e "s|^PHONE_HOST=.*|PHONE_HOST=\"${phone_host}\"|" "${CONFIG_FILE}"
      else
        echo "PHONE_HOST=\"${phone_host}\"" >> "${CONFIG_FILE}"
      fi
    fi
  fi

  if [[ -x "${SUPPORT_DIR}/phonedrop.sh" ]]; then
    write_watch_plist "${name}" "${drop_folder}"
    load_watch_agent "${name}"
  fi

  echo "phonedrop: target '${name}' saved"
  echo "  platform:       ${platform}"
  echo "  strip_metadata: ${strip}"
  echo "  drop_folder:    ${drop_folder}"
  if [[ "${platform}" == "ios" ]]; then
    echo "  airdrop:        ${airdrop}"
  else
    echo "  phone_host:     ${phone_host}:${adb_port}"
  fi
  echo "Drop photos into ${drop_folder} (or: phonedrop.sh push --target ${name} <files>)."
}

cmd_remove_phone() {
  local name="${1:-}"
  [[ -n "${name}" ]] || die "Usage: phonedrop.sh remove-phone <name>"
  name=$(sanitise_target_name "${name}") || exit 1
  load_targets
  target_exists "${name}" || die "No target named '${name}'"

  local new_names=() new_plat=() new_host=() new_port=() new_serial=()
  local new_dest=() new_air=() new_strip=() new_drop=() new_on=()
  local i
  i=0
  while [[ ${i} -lt ${#TARGET_NAMES[@]} ]]; do
    if [[ "${TARGET_NAMES[i]}" != "${name}" ]]; then
      new_names+=("${TARGET_NAMES[i]}")
      new_plat+=("${TARGET_PLATFORM[i]}")
      new_host+=("${TARGET_PHONE_HOST[i]}")
      new_port+=("${TARGET_ADB_PORT[i]}")
      new_serial+=("${TARGET_SERIAL[i]}")
      new_dest+=("${TARGET_DEST[i]}")
      new_air+=("${TARGET_AIRDROP[i]}")
      new_strip+=("${TARGET_STRIP[i]}")
      new_drop+=("${TARGET_DROP_FOLDER[i]}")
      new_on+=("${TARGET_ON_SEND[i]}")
    fi
    i=$((i + 1))
  done
  TARGET_NAMES=("${new_names[@]+"${new_names[@]}"}")
  TARGET_PLATFORM=("${new_plat[@]+"${new_plat[@]}"}")
  TARGET_PHONE_HOST=("${new_host[@]+"${new_host[@]}"}")
  TARGET_ADB_PORT=("${new_port[@]+"${new_port[@]}"}")
  TARGET_SERIAL=("${new_serial[@]+"${new_serial[@]}"}")
  TARGET_DEST=("${new_dest[@]+"${new_dest[@]}"}")
  TARGET_AIRDROP=("${new_air[@]+"${new_air[@]}"}")
  TARGET_STRIP=("${new_strip[@]+"${new_strip[@]}"}")
  TARGET_DROP_FOLDER=("${new_drop[@]+"${new_drop[@]}"}")
  TARGET_ON_SEND=("${new_on[@]+"${new_on[@]}"}")

  # bash 3.2 empty-array safety
  if [[ ${#new_names[@]} -eq 0 ]]; then
    clear_targets
  fi

  persist_all_targets
  unload_watch_agent "${name}"
  echo "phonedrop: removed target '${name}' (drop folder left in place)"
}

cmd_config() {
  local name="${1:-}"
  if [[ -z "${name}" ]]; then
    echo "=== Global config: ${CONFIG_FILE} ==="
    if [[ -f "${CONFIG_FILE}" ]]; then
      cat "${CONFIG_FILE}"
    else
      echo "(missing — run: phonedrop.sh install)"
    fi
    echo ""
    echo "=== Targets: ${TARGETS_FILE} ==="
    ensure_legacy_target
    if [[ ${#TARGET_NAMES[@]} -eq 0 ]]; then
      echo "(no targets)"
    else
      if [[ -f "${TARGETS_FILE}" ]]; then
        cat "${TARGETS_FILE}"
      else
        cmd_list
      fi
    fi
    return 0
  fi
  name=$(sanitise_target_name "${name}") || exit 1
  require_target "${name}"
  echo "=== Target: ${name} ==="
  write_target_block "${name}"
}

# ---------------------------------------------------------------------------
# connect / status / rearm / autoarm
# ---------------------------------------------------------------------------
cmd_connect() {
  load_config
  ensure_legacy_target
  local target_name="${1:-}"
  if [[ -n "${target_name}" ]]; then
    require_target "${target_name}"
    [[ "$(target_get "${target_name}" platform)" == "android" ]] || \
      die "connect is only for android targets (got ios)"
    apply_target_to_globals "${target_name}"
  fi
  [[ -n "${PHONE_HOST}" ]] || die "PHONE_HOST not set. Edit ${CONFIG_FILE} or: phonedrop.sh add-phone"
  require_tool "${ADB_BIN}" "adb"
  echo "phonedrop: connecting to ${PHONE_HOST}:${ADB_PORT} ..."
  local result
  result=$("${ADB_BIN}" connect "${PHONE_HOST}:${ADB_PORT}" 2>&1) || true
  if echo "${result}" | grep -qiE "connected|already connected"; then
    echo "phonedrop: ${result}"
    return 0
  else
    die "Could not connect to ${PHONE_HOST}:${ADB_PORT}. Re-pair Wireless Debugging on the phone and try again. (adb said: ${result})"
  fi
}

cmd_status() {
  load_config
  ensure_legacy_target
  echo "=== PhoneDrop status ==="
  echo "Config:       ${CONFIG_FILE}"
  echo "Targets file: ${TARGETS_FILE}"
  echo "PHONE_HOST:   ${PHONE_HOST:-<not set>} (legacy default)"
  echo "ADB_PORT:     ${ADB_PORT}"
  echo "DEST:         ${DEST}"
  echo "ADB_BIN:      ${ADB_BIN} $([ -x "${ADB_BIN}" ] && echo "(ok)" || echo "(NOT FOUND)")"
  echo "EXIFTOOL_BIN: ${EXIFTOOL_BIN} $([ -x "${EXIFTOOL_BIN}" ] && echo "(ok)" || echo "(NOT FOUND)")"
  echo "TAILSCALE_BIN:${TAILSCALE_BIN} $([ -x "${TAILSCALE_BIN}" ] && echo "(ok)" || echo "(NOT FOUND)")"
  launchctl list 2>/dev/null | grep -q "${AUTOARM_LABEL}" && echo "Auto-arm:     loaded" || echo "Auto-arm:     not loaded"
  echo ""
  cmd_list
  echo ""
  if [[ -x "${ADB_BIN}" ]]; then
    echo "=== adb devices ==="
    "${ADB_BIN}" devices 2>&1 || true
    echo ""
    local selected="none"
    if selected=$(select_adb_target 2>/dev/null); then
      :
    else
      selected="none"
    fi
    echo "Selected adb target: ${selected}"
  fi
}

cmd_rearm() {
  load_config
  ensure_legacy_target
  local target_name="${1:-}"
  if [[ -n "${target_name}" ]]; then
    require_target "${target_name}"
    apply_target_to_globals "${target_name}"
  fi
  [[ -n "${PHONE_HOST}" ]] || die "PHONE_HOST not set in config. Edit ${CONFIG_FILE}."
  require_tool "${ADB_BIN}" "adb"
  local count
  count=$(usb_adb_serials | awk 'NF {c++} END {print c+0}')
  [[ "${count}" -gt 0 ]] || die "No USB device found. Plug in USB cable first."
  [[ "${count}" -eq 1 ]] || die "Multiple USB devices found. Plug in one phone, then run: phonedrop.sh rearm"
  arm_wireless 0 || true
}

cmd_autoarm() {
  load_config
  ensure_legacy_target
  if [[ -z "${PHONE_HOST}" ]]; then
    local i
    i=0
    while [[ ${i} -lt ${#TARGET_NAMES[@]} ]]; do
      if [[ "${TARGET_PLATFORM[i]}" == "android" ]]; then
        apply_target_to_globals "${TARGET_NAMES[i]}"
        break
      fi
      i=$((i + 1))
    done
  fi
  [[ -n "${PHONE_HOST}" ]] || exit 0
  [[ -x "${ADB_BIN}" ]] || { autoarm_log "adb not executable at ${ADB_BIN}"; exit 0; }
  [[ "$("${ADB_BIN}" -s "${PHONE_HOST}:${ADB_PORT}" get-state 2>/dev/null || true)" == "device" ]] && exit 0
  local usb_serial
  if usb_serial=$(single_usb_device); then
    autoarm_log "arming ${usb_serial} for ${PHONE_HOST}:${ADB_PORT}"
    arm_wireless 1 >/dev/null 2>&1 || true
  else
    case "$?" in
      1) autoarm_log "no USB device; skip" ;;
      *) autoarm_log "multiple USB devices; skip" ;;
    esac
  fi
  exit 0
}

write_autoarm_plist() {
  mkdir -p "$(dirname "${AUTOARM_PLIST}")" "$(dirname "${AUTOARM_LOG}")"
  cat > "${AUTOARM_PLIST}" << EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>${AUTOARM_LABEL}</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>${SUPPORT_DIR}/phonedrop.sh</string><string>autoarm</string></array><key>StartInterval</key><integer>30</integer><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>${AUTOARM_LOG}</string><key>StandardErrorPath</key><string>${AUTOARM_LOG}</string></dict></plist>
EOF
}

cmd_autoarm_disable() {
  launchctl bootout "gui/$(id -u)/${AUTOARM_LABEL}" 2>/dev/null || true
  rm -f "${AUTOARM_PLIST}"
  echo "phonedrop: auto-arm disabled"
}

# ---------------------------------------------------------------------------
# install / uninstall
# ---------------------------------------------------------------------------
cmd_install() {
  local adb_bin exiftool_bin tailscale_bin
  adb_bin=$(command -v adb 2>/dev/null || echo "/opt/homebrew/bin/adb")
  exiftool_bin=$(command -v exiftool 2>/dev/null || echo "/opt/homebrew/bin/exiftool")
  tailscale_bin=$(command -v tailscale 2>/dev/null || echo "/usr/local/bin/tailscale")
  [[ -x "${adb_bin}" ]]       || adb_bin="/opt/homebrew/bin/adb"
  [[ -x "${exiftool_bin}" ]]  || exiftool_bin="/opt/homebrew/bin/exiftool"
  [[ -x "${tailscale_bin}" ]] || tailscale_bin="/usr/local/bin/tailscale"
  ADB_BIN="${adb_bin}"
  EXIFTOOL_BIN="${exiftool_bin}"
  TAILSCALE_BIN="${tailscale_bin}"

  mkdir -p "${CONFIG_DIR}" "${TARGETS_D}"
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    local phone_host=""
    if [[ -t 0 ]]; then
      read -r -p "Enter default Android Tailscale hostname (or leave blank): " phone_host
    fi
    cat > "${CONFIG_FILE}" << EOF
# PhoneDrop global / legacy configuration
# Multi-target phones live in targets.conf (phonedrop.sh add-phone).
# PHONE_HOST here is used as a backward-compatible single Android target.
PHONE_HOST="${phone_host:-YOUR_PHONE_HOSTNAME}"
ADB_PORT="5555"
DEST="/sdcard/DCIM/PhoneDrop/"
ADB_BIN="${adb_bin}"
EXIFTOOL_BIN="${exiftool_bin}"
TAILSCALE_BIN="${tailscale_bin}"
EOF
    echo "phonedrop: config written to ${CONFIG_FILE}"
  else
    echo "phonedrop: config already exists at ${CONFIG_FILE} (not overwritten)"
    sed -i '' \
      -e "s|^ADB_BIN=.*|ADB_BIN=\"${adb_bin}\"|" \
      -e "s|^EXIFTOOL_BIN=.*|EXIFTOOL_BIN=\"${exiftool_bin}\"|" \
      -e "s|^TAILSCALE_BIN=.*|TAILSCALE_BIN=\"${tailscale_bin}\"|" \
      "${CONFIG_FILE}"
    echo "phonedrop: updated tool paths in existing config"
  fi

  load_config
  load_targets
  if [[ ${#TARGET_NAMES[@]} -eq 0 ]] && [[ -n "${PHONE_HOST}" ]] && [[ "${PHONE_HOST}" != "YOUR_PHONE_HOSTNAME" ]]; then
    target_add_or_update "default" "android" "${PHONE_HOST}" "${ADB_PORT}" "" \
      "${DEST}" "" "true" "${DROP_ROOT_DEFAULT}/default" "archive"
    persist_all_targets
    echo "phonedrop: migrated legacy PHONE_HOST → targets.conf as [default]"
  fi

  mkdir -p "${SUPPORT_DIR}"
  local self script_dir
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cp "${self}" "${SUPPORT_DIR}/phonedrop.sh"
  chmod +x "${SUPPORT_DIR}/phonedrop.sh"
  if [[ -f "${script_dir}/phonedrop-airdrop.swift" ]]; then
    cp "${script_dir}/phonedrop-airdrop.swift" "${SUPPORT_DIR}/phonedrop-airdrop.swift"
  fi
  echo "phonedrop: logic script installed to ${SUPPORT_DIR}/phonedrop.sh"

  write_autoarm_plist
  launchctl bootout "gui/$(id -u)/${AUTOARM_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "${AUTOARM_PLIST}" || \
    echo "phonedrop: warning: could not load auto-arm agent now; re-run install to retry"
  echo "phonedrop: auto-arm agent installed and active"

  ensure_legacy_target
  sync_all_watch_agents

  local droplet_src="${script_dir}/phonedrop-droplet.applescript"
  if [[ ! -f "${droplet_src}" ]]; then
    die "Droplet source not found at ${droplet_src}. Clone the repo first."
  fi
  mkdir -p "${HOME}/Applications"
  osacompile -o "${APP_DEST}" "${droplet_src}"
  echo "phonedrop: droplet compiled → ${APP_DEST}"
  echo ""
  echo "Done!"
  echo "  • Dock droplet: drag ${APP_DEST} to your Dock (default/legacy Android target)"
  echo "  • Per-phone folders: drop photos into ~/PhoneDrop/<name>/"
  echo "  • Manage phones: phonedrop.sh add-phone | remove-phone | list"
}

cmd_uninstall() {
  launchctl bootout "gui/$(id -u)/${AUTOARM_LABEL}" 2>/dev/null || true
  rm -f "${AUTOARM_PLIST}"
  local existing base tn
  for existing in "${HOME}/Library/LaunchAgents/${WATCH_LABEL_PREFIX}".*.plist; do
    [[ -f "${existing}" ]] || continue
    base=$(basename "${existing}" .plist)
    tn="${base#${WATCH_LABEL_PREFIX}.}"
    unload_watch_agent "${tn}"
  done
  echo "phonedrop: launchd agents removed (config and drop folders kept)"
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
cmd_check() {
  load_config
  ensure_legacy_target
  local errors=0
  echo "=== PhoneDrop smoke test ==="
  if [[ -f "${CONFIG_FILE}" ]]; then
    echo "[ok] config: ${CONFIG_FILE}"
  else
    echo "[FAIL] config not found: ${CONFIG_FILE}"
    errors=$((errors + 1))
  fi
  for pair in "${ADB_BIN}:adb" "${EXIFTOOL_BIN}:exiftool" "${TAILSCALE_BIN}:tailscale"; do
    local bin="${pair%%:*}"
    local name="${pair##*:}"
    if [[ -x "${bin}" ]]; then
      echo "[ok] ${name}: ${bin}"
    else
      echo "[FAIL] ${name} not executable: ${bin}"
      errors=$((errors + 1))
    fi
  done
  echo "--- targets ---"
  if [[ ${#TARGET_NAMES[@]} -gt 0 ]]; then
    echo "[ok] ${#TARGET_NAMES[@]} target(s) loaded"
    cmd_list
  else
    echo "[info] no multi-target entries (legacy single-host mode ok)"
  fi
  echo "--- EXIF strip test ---"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  local orig="${tmp_dir}/orig.jpg"
  local stripped="${tmp_dir}/stripped.jpg"
  if command -v sips >/dev/null 2>&1; then
    local tmp_png="${tmp_dir}/pixel.png"
    python3 - "${tmp_png}" << 'PYEOF'
import sys, struct, zlib
def write_png(path):
    raw = b'\x00\x00'
    compressed = zlib.compress(raw)
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        crc = zlib.crc32(c[4:]) & 0xffffffff
        return c + struct.pack('>I', crc)
    sig = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 0, 0, 0, 0))
    idat = chunk(b'IDAT', compressed)
    iend = chunk(b'IEND', b'')
    open(path, 'wb').write(sig + ihdr + idat + iend)
write_png(sys.argv[1])
PYEOF
    sips -s format jpeg "${tmp_png}" --out "${orig}" >/dev/null 2>&1 || true
  fi
  if [[ ! -f "${orig}" ]]; then
    echo "[SKIP] could not create test JPEG (sips unavailable)"
  elif [[ ! -x "${EXIFTOOL_BIN}" ]]; then
    echo "[SKIP] exiftool not found — cannot run strip assertion"
    errors=$((errors + 1))
  else
    "${EXIFTOOL_BIN}" -overwrite_original \
      -GPSLatitude=51.5 -GPSLongitude=-0.1 \
      -GPSLatitudeRef=N -GPSLongitudeRef=W \
      "${orig}" >/dev/null 2>&1
    cp "${orig}" "${stripped}"
    "${EXIFTOOL_BIN}" -overwrite_original -all= "${stripped}" >/dev/null 2>&1
    local gps_after
    gps_after=$("${EXIFTOOL_BIN}" -GPS:all "${stripped}" 2>/dev/null || true)
    if [[ -z "${gps_after}" ]]; then
      echo "[ok] EXIF/GPS strip: no GPS tags after strip"
    else
      echo "[FAIL] EXIF/GPS strip: GPS tags still present"
      errors=$((errors + 1))
    fi
  fi
  rm -rf "${tmp_dir}"
  if [[ -n "${PHONE_HOST}" ]] && [[ "${PHONE_HOST}" != "YOUR_PHONE_HOSTNAME" ]]; then
    echo "--- adb connect test ---"
    if [[ -x "${ADB_BIN}" ]]; then
      local result
      result=$("${ADB_BIN}" connect "${PHONE_HOST}:${ADB_PORT}" 2>&1) || true
      if echo "${result}" | grep -qiE "connected|already connected"; then
        echo "[ok] adb connect: ${result}"
      else
        echo "[FAIL] adb connect failed: ${result}"
        errors=$((errors + 1))
      fi
    fi
  else
    echo "[skip] adb connect: PHONE_HOST not configured"
  fi
  echo ""
  if [[ "${errors}" -eq 0 ]]; then
    echo "=== All checks passed ==="
    return 0
  else
    echo "=== ${errors} check(s) failed ==="
    notify "PhoneDrop" "smoke test: ${errors} check(s) failed — see terminal"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# cmd_push
# ---------------------------------------------------------------------------
cmd_push() {
  local target_name=""
  local files=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target|-t)
        target_name="${2:-}"
        [[ -n "${target_name}" ]] || die "--target requires a name"
        shift 2
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do files+=("$1"); shift; done
        break
        ;;
      -*)
        die "Unknown push option: $1"
        ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Usage: phonedrop.sh push [--target <name>] <file> [file ...]" >&2
    exit 1
  fi
  local resolved
  resolved=$(resolve_push_target "${target_name}")
  push_files_to_target "${resolved}" "${files[@]}"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: phonedrop.sh <command> [args...]

Phone targets:
  add-phone [opts]       Add or update a named phone target
  remove-phone <name>    Remove a phone target
  list                   List configured phone targets
  config [name]          Show global or per-target config

Transfer:
  push [--target name] <files...>
                         Optionally strip metadata and send files to a phone
  watch [name]           Process drop folder(s) — used by launchd WatchPaths

Android helpers:
  connect [name]         adb connect over Tailscale
  rearm [name]           Re-enable wireless adb over USB
  autoarm                LaunchAgent wireless auto-arm check
  autoarm-disable        Disable auto-arm LaunchAgent

Lifecycle:
  install                Install droplet, config, drop folders, launchd agents
  uninstall              Remove launchd agents (keep config/folders)
  status                 Show config, targets, tools, adb state
  check                  Smoke tests (phone optional)

add-phone options:
  --name NAME --platform android|ios
  --host HOST --port PORT --serial SERIAL --dest DEST   (android)
  --recipient NAME                                       (ios AirDrop)
  --strip true|false | --no-strip
  --folder PATH --on-send archive|delete
EOF
}

VERB="${1:-}"
shift || true
case "${VERB}" in
  push)            load_config; cmd_push "$@" ;;
  watch)           cmd_watch "$@" ;;
  add-phone)       cmd_add_phone "$@" ;;
  remove-phone)    cmd_remove_phone "$@" ;;
  list)            cmd_list "$@" ;;
  config)          cmd_config "$@" ;;
  autoarm)         cmd_autoarm "$@" ;;
  autoarm-disable) cmd_autoarm_disable "$@" ;;
  connect)         cmd_connect "$@" ;;
  rearm)           cmd_rearm "$@" ;;
  status)          cmd_status "$@" ;;
  install)         cmd_install "$@" ;;
  uninstall)       cmd_uninstall "$@" ;;
  check)           cmd_check "$@" ;;
  ""|-h|--help|help) usage; exit 0 ;;
  *)
    echo "phonedrop: unknown command: ${VERB}" >&2
    usage >&2
    exit 1
    ;;
esac
