#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR="${PHONEDROP_CONFIG_DIR:-${HOME}/.config/phonedrop}"
CONFIG_FILE="${PHONEDROP_CONFIG_FILE:-${CONFIG_DIR}/config}"
SUPPORT_DIR="${HOME}/Library/Application Support/PhoneDrop"
APP_DEST="${HOME}/Applications/PhoneDrop.app"
AUTOARM_LABEL="com.phonedrop.autoarm"
AUTOARM_PLIST="${HOME}/Library/LaunchAgents/${AUTOARM_LABEL}.plist"
AUTOARM_LOG="${HOME}/Library/Logs/phonedrop-autoarm.log"
load_config() {
  if [[ -f "${CONFIG_FILE}" ]]; then
    source "${CONFIG_FILE}"
  fi
}
PHONE_HOST="${PHONE_HOST:-}"
ADB_PORT="${ADB_PORT:-5555}"
DEST="${DEST:-/sdcard/DCIM/PhoneDrop/}"
ADB_BIN="${ADB_BIN:-/opt/homebrew/bin/adb}"
OSASCRIPT_BIN="${OSASCRIPT_BIN:-osascript}"
EXIFTOOL_BIN="${EXIFTOOL_BIN:-/opt/homebrew/bin/exiftool}"
TAILSCALE_BIN="${TAILSCALE_BIN:-/usr/local/bin/tailscale}"
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
  safe="${safe##*( )}"
  if [[ -z "${safe}" || "${safe}" == "." || "${safe}" == ".." ]]; then
    echo "phonedrop: error: sanitised filename is empty or reserved: '${name}'" >&2
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
require_config() {
  load_config
  [[ -f "${CONFIG_FILE}" ]] || die "Config not found. Run: phonedrop.sh install"
  [[ -n "${PHONE_HOST}" ]] || die "PHONE_HOST not set in ${CONFIG_FILE}. Edit it and set PHONE_HOST."
}
require_tool() {
  local bin="$1"
  local name="$2"
  [[ -x "${bin}" ]] || die "${name} not found at ${bin}. Run: phonedrop.sh install"
}
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
    count=$((count+1)); [[ -z "${first}" ]] && first="${serial}"
  done < <(usb_adb_serials)
  [[ "${count}" -eq 1 ]] && { printf '%s\n' "${first}"; return 0; }
  [[ "${count}" -eq 0 ]] && return 1
  return 2
}
select_adb_target() {
  local remote="${PHONE_HOST}:${ADB_PORT}" state serials first count
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
cmd_connect() {
  load_config
  [[ -n "${PHONE_HOST}" ]] || die "PHONE_HOST not set in config. Edit ${CONFIG_FILE}."
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
  echo "=== PhoneDrop status ==="
  echo "Config:       ${CONFIG_FILE}"
  echo "PHONE_HOST:   ${PHONE_HOST:-<not set>}"
  echo "ADB_PORT:     ${ADB_PORT}"
  echo "DEST:         ${DEST}"
  echo "ADB_BIN:      ${ADB_BIN} $([ -x "${ADB_BIN}" ] && echo "(ok)" || echo "(NOT FOUND)")"
  echo "EXIFTOOL_BIN: ${EXIFTOOL_BIN} $([ -x "${EXIFTOOL_BIN}" ] && echo "(ok)" || echo "(NOT FOUND)")"
  echo "TAILSCALE_BIN:${TAILSCALE_BIN} $([ -x "${TAILSCALE_BIN}" ] && echo "(ok)" || echo "(NOT FOUND)")"
  launchctl list 2>/dev/null | grep -q "${AUTOARM_LABEL}" && echo "Auto-arm:     loaded" || echo "Auto-arm:     not loaded"
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
    echo "Selected target: ${selected}"
  fi
}
cmd_rearm() {
  require_config
  require_tool "${ADB_BIN}" "adb"
  local count
  count=$(usb_adb_serials | awk 'NF {c++} END {print c+0}')
  [[ "${count}" -gt 0 ]] || die "No USB device found. Plug in USB cable first."
  [[ "${count}" -eq 1 ]] || die "Multiple USB devices found. Plug in one phone, then run: phonedrop.sh rearm"
  arm_wireless 0 || true
}
cmd_autoarm() {
  load_config
  [[ -n "${PHONE_HOST}" ]] || exit 0
  [[ -x "${ADB_BIN}" ]] || { autoarm_log "adb not executable at ${ADB_BIN}"; exit 0; }
  [[ "$("${ADB_BIN}" -s "${PHONE_HOST}:${ADB_PORT}" get-state 2>/dev/null || true)" == "device" ]] && exit 0
  local usb_serial
  if usb_serial=$(single_usb_device); then
    autoarm_log "arming ${usb_serial} for ${PHONE_HOST}:${ADB_PORT}"
    arm_wireless 1 >/dev/null 2>&1 || true
  else
    case "$?" in 1) autoarm_log "no USB device; skip" ;; *) autoarm_log "multiple USB devices; skip" ;; esac
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
cmd_config() {
  echo "Config path: ${CONFIG_FILE}"
  if [[ -f "${CONFIG_FILE}" ]]; then
    cat "${CONFIG_FILE}"
  else
    echo "(config file does not exist yet — run: phonedrop.sh install)"
  fi
}
cmd_install() {
  local adb_bin exiftool_bin tailscale_bin
  adb_bin=$(command -v adb 2>/dev/null || echo "/opt/homebrew/bin/adb")
  exiftool_bin=$(command -v exiftool 2>/dev/null || echo "/opt/homebrew/bin/exiftool")
  tailscale_bin=$(command -v tailscale 2>/dev/null || echo "/usr/local/bin/tailscale")
  [[ -x "${adb_bin}" ]]       || adb_bin="/opt/homebrew/bin/adb"
  [[ -x "${exiftool_bin}" ]]  || exiftool_bin="/opt/homebrew/bin/exiftool"
  [[ -x "${tailscale_bin}" ]] || tailscale_bin="/usr/local/bin/tailscale"
  mkdir -p "${CONFIG_DIR}"
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    local phone_host=""
    if [[ -t 0 ]]; then
      read -r -p "Enter phone Tailscale MagicDNS hostname (e.g. android-phone): " phone_host
    fi
    cat > "${CONFIG_FILE}" << EOF
# PhoneDrop configuration
# Edit PHONE_HOST to match your phone's Tailscale MagicDNS name.
PHONE_HOST="${phone_host:-YOUR_PHONE_HOSTNAME}"
ADB_PORT="5555"
DEST="/sdcard/DCIM/PhoneDrop/"
ADB_BIN="${adb_bin}"
EXIFTOOL_BIN="${exiftool_bin}"
TAILSCALE_BIN="${tailscale_bin}"
EOF
    echo "phonedrop: config written to ${CONFIG_FILE}"
    if [[ -z "${phone_host}" ]]; then
      echo "phonedrop: Set PHONE_HOST in ${CONFIG_FILE} before using PhoneDrop."
    fi
  else
    echo "phonedrop: config already exists at ${CONFIG_FILE} (not overwritten)"
    sed -i '' \
      -e "s|^ADB_BIN=.*|ADB_BIN=\"${adb_bin}\"|" \
      -e "s|^EXIFTOOL_BIN=.*|EXIFTOOL_BIN=\"${exiftool_bin}\"|" \
      -e "s|^TAILSCALE_BIN=.*|TAILSCALE_BIN=\"${tailscale_bin}\"|" \
      "${CONFIG_FILE}"
    echo "phonedrop: updated tool paths in existing config"
  fi
  mkdir -p "${SUPPORT_DIR}"
  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  cp "${self}" "${SUPPORT_DIR}/phonedrop.sh"
  chmod +x "${SUPPORT_DIR}/phonedrop.sh"
  echo "phonedrop: logic script installed to ${SUPPORT_DIR}/phonedrop.sh"
  write_autoarm_plist
  launchctl bootout "gui/$(id -u)/${AUTOARM_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "${AUTOARM_PLIST}" || echo "phonedrop: warning: could not load auto-arm agent now; re-run install or: phonedrop.sh install to retry"
  echo "phonedrop: auto-arm agent installed and active"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local droplet_src="${script_dir}/phonedrop-droplet.applescript"
  if [[ ! -f "${droplet_src}" ]]; then
    die "Droplet source not found at ${droplet_src}. Clone the repo first."
  fi
  mkdir -p "${HOME}/Applications"
  osacompile -o "${APP_DEST}" "${droplet_src}"
  echo "phonedrop: droplet compiled → ${APP_DEST}"
  echo ""
  echo "Done! Auto-arm is active. Drag ${APP_DEST} to your Dock, then drop photos onto it."
}
cmd_check() {
  load_config
  local errors=0
  echo "=== PhoneDrop smoke test ==="
  if [[ -f "${CONFIG_FILE}" ]]; then
    echo "[ok] config: ${CONFIG_FILE}"
  else
    echo "[FAIL] config not found: ${CONFIG_FILE}"
    errors=$((errors+1))
  fi
  for pair in "${ADB_BIN}:adb" "${EXIFTOOL_BIN}:exiftool" "${TAILSCALE_BIN}:tailscale"; do
    local bin="${pair%%:*}"
    local name="${pair##*:}"
    if [[ -x "${bin}" ]]; then
      echo "[ok] ${name}: ${bin}"
    else
      echo "[FAIL] ${name} not executable: ${bin}"
      errors=$((errors+1))
    fi
  done
  echo "--- EXIF strip test ---"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap '[[ -n "${tmp_dir:-}" ]] && rm -rf "${tmp_dir}"' EXIT
  local orig="${tmp_dir}/orig.jpg"
  local stripped="${tmp_dir}/stripped.jpg"
  if command -v sips >/dev/null 2>&1; then
    local tmp_png="${tmp_dir}/pixel.png"
    python3 - "${tmp_png}" << 'PYEOF'
import sys, struct, zlib
def write_png(path):
    raw = b'\x00\x00'  # filter byte + 1-byte gray pixel
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
    errors=$((errors+1))
  else
    "${EXIFTOOL_BIN}" -overwrite_original \
      -GPSLatitude=51.5 -GPSLongitude=-0.1 \
      -GPSLatitudeRef=N -GPSLongitudeRef=W \
      "${orig}" >/dev/null 2>&1
    local gps_before
    gps_before=$("${EXIFTOOL_BIN}" -GPSLatitude "${orig}" 2>/dev/null || true)
    [[ -z "${gps_before}" ]] && echo "[WARN] GPS injection may have failed"
    cp "${orig}" "${stripped}"
    "${EXIFTOOL_BIN}" -overwrite_original -all= "${stripped}" >/dev/null 2>&1
    local gps_after
    gps_after=$("${EXIFTOOL_BIN}" -GPS:all "${stripped}" 2>/dev/null || true)
    if [[ -z "${gps_after}" ]]; then
      echo "[ok] EXIF/GPS strip: no GPS tags after strip"
    else
      echo "[FAIL] EXIF/GPS strip: GPS tags still present:"
      echo "  ${gps_after}"
      errors=$((errors+1))
    fi
  fi
  if [[ -n "${PHONE_HOST}" ]] && [[ "${PHONE_HOST}" != "YOUR_PHONE_HOSTNAME" ]]; then
    echo "--- adb connect test ---"
    if [[ -x "${ADB_BIN}" ]]; then
      local result
      result=$("${ADB_BIN}" connect "${PHONE_HOST}:${ADB_PORT}" 2>&1) || true
      if echo "${result}" | grep -qiE "connected|already connected"; then
        echo "[ok] adb connect: ${result}"
        local dest_safe
        dest_safe="$(sq_escape "${DEST}")"
        local writable
        local check_target=""
        check_target=$(select_adb_target 2>/dev/null || true)
        if [[ -n "${check_target}" ]]; then
          writable=$("${ADB_BIN}" -s "${check_target}" shell "test -w '${dest_safe}' && echo yes || echo no" 2>/dev/null || echo "unknown")
        else
          writable="no device"
        fi
        echo "[info] DEST writable: ${writable}"
      else
        echo "[FAIL] adb connect failed: ${result}"
        errors=$((errors+1))
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
cmd_push() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: phonedrop.sh push <file> [file ...]" >&2
    exit 1
  fi
  require_config
  validate_dest
  require_tool "${ADB_BIN}" "adb"
  require_tool "${EXIFTOOL_BIN}" "exiftool"
  local stamp="${PHONEDROP_STAMP:-$(date +%Y%m%d_%H%M%S)}"
  "${ADB_BIN}" connect "${PHONE_HOST}:${ADB_PORT}" >/dev/null 2>&1 || true
  local adb_target
  adb_target=$(select_adb_target) || die "PhoneDrop couldn't send — your phone isn't reachable (off, asleep, or wireless adb not armed after a reboot). Plug it into USB to re-arm, or check it's connected on Tailscale."
  local dest_safe
  dest_safe="$(sq_escape "${DEST}")"
  "${ADB_BIN}" -s "${adb_target}" shell "mkdir -p '${dest_safe}'" 2>/dev/null || true
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap '[[ -n "${tmp_dir:-}" ]] && rm -rf "${tmp_dir}"' EXIT
  local pushed=0 failed=0 last_error="" image_exts="jpg jpeg png tif tiff heic heif webp bmp gif"
  local seen_dir
  seen_dir=$(mktemp -d)
  for src in "$@"; do
    if [[ ! -f "${src}" ]]; then
      echo "phonedrop: skipping (not a file): ${src}" >&2
      failed=$((failed+1))
      last_error="not a file: ${src}"
      continue
    fi
    local raw_basename safe_basename
    raw_basename=$(basename "${src}")
    if ! safe_basename=$(sanitise_basename "${raw_basename}"); then
      echo "phonedrop: skipping (unsafe filename): ${raw_basename}" >&2
      failed=$((failed+1))
      last_error="unsafe filename: ${raw_basename}"
      continue
    fi
    local seen_file="${seen_dir}/${safe_basename}.count"
    if [[ -f "${seen_file}" ]]; then
      local count
      count=$(cat "${seen_file}")
      count=$((count+1))
      printf '%s' "${count}" > "${seen_file}"
      local stem="${safe_basename%.*}"
      local fext="${safe_basename##*.}"
      if [[ "${fext}" == "${safe_basename}" ]]; then
        safe_basename="${safe_basename}_${count}"
      else
        safe_basename="${stem}_${count}.${fext}"
      fi
    else
      printf '0' > "${seen_file}"
    fi
    local tmp_copy="${tmp_dir}/${safe_basename}"
    cp -- "${src}" "${tmp_copy}"
    local ext="${safe_basename##*.}"
    ext=$(printf '%s' "${ext}" | tr '[:upper:]' '[:lower:]')
    local is_image=0
    for imgext in ${image_exts}; do
      if [[ "${ext}" == "${imgext}" ]]; then
        is_image=1
        break
      fi
    done
    if [[ "${is_image}" -eq 1 ]]; then
      "${EXIFTOOL_BIN}" -overwrite_original -all= "${tmp_copy}" >/dev/null 2>&1 || {
        echo "phonedrop: warning: exiftool strip failed for ${safe_basename}, pushing anyway" >&2
      }
    fi
    local phone_path="${DEST}${stamp}_${safe_basename}"
    if "${ADB_BIN}" -s "${adb_target}" push "${tmp_copy}" "${phone_path}" >/dev/null 2>&1; then
      local phone_path_safe
      phone_path_safe="$(sq_escape "${phone_path}")"
      "${ADB_BIN}" -s "${adb_target}" shell "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://${phone_path_safe}'" >/dev/null 2>&1 || true
      pushed=$((pushed+1))
      echo "phonedrop: pushed ${safe_basename} → ${phone_path}"
    else
      failed=$((failed+1))
      last_error="adb push failed for ${safe_basename}"
      echo "phonedrop: error: ${last_error}" >&2
    fi
  done
  rm -rf "${seen_dir}"
  if [[ "${pushed}" -gt 0 ]] && [[ "${failed}" -eq 0 ]]; then
    notify "PhoneDrop" "Sent ${pushed} photo(s) to phone"
  elif [[ "${pushed}" -gt 0 ]]; then
    notify "PhoneDrop" "Sent ${pushed} photo(s); ${failed} failed"
  else
    die "All ${failed} file(s) failed. Last error: ${last_error}"
  fi
}
VERB="${1:-}"
shift || true
case "${VERB}" in
  push)    load_config; cmd_push "$@" ;;
  autoarm) cmd_autoarm "$@" ;;
  autoarm-disable) cmd_autoarm_disable "$@" ;;
  connect) cmd_connect "$@" ;;
  rearm)   cmd_rearm "$@" ;;
  status)  cmd_status "$@" ;;
  install) cmd_install "$@" ;;
  config)  cmd_config "$@" ;;
  check)   cmd_check "$@" ;;
  *)
    echo "Usage: phonedrop.sh <push|autoarm|autoarm-disable|connect|rearm|status|install|config|check> [args...]" >&2
    echo ""
    echo "  push <files...>  Strip EXIF/GPS and push files to phone gallery"
    echo "  autoarm          LaunchAgent-safe wireless adb auto-arm check"
    echo "  autoarm-disable  Disable and remove the auto-arm LaunchAgent"
    echo "  connect          Connect to phone via adb over Tailscale"
    echo "  rearm            Re-enable wireless adb over USB after a phone reboot"
    echo "  status           Show config, tool paths, and adb connection state"
    echo "  install          Install PhoneDrop.app and seed config"
    echo "  config           Print config path and current values"
    echo "  check            Run smoke tests (no phone required for EXIF strip test)"
    exit 1
    ;;
esac
