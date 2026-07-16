#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
FAILURES=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHONEDROP="${SCRIPT_DIR}/../scripts/phonedrop.sh"
EXIFTOOL_BIN="${EXIFTOOL_BIN:-/opt/homebrew/bin/exiftool}"

# Assert helpers
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc}"
    echo "       expected: $(printf '%q' "${expected}")"
    echo "       actual:   $(printf '%q' "${actual}")"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

assert_not_eq() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "${unexpected}" != "${actual}" ]]; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc}"
    echo "       unexpected: $(printf '%q' "${unexpected}")"
    echo "       actual:     $(printf '%q' "${actual}")"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

assert_empty() {
  local desc="$1" val="$2"
  if [[ -z "${val}" ]]; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc} — expected empty, got: ${val}"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

assert_not_empty() {
  local desc="$1" val="$2"
  if [[ -n "${val}" ]]; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc} — expected non-empty"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "${path}" ]]; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc} — file not found: ${path}"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

assert_file_not_exists() {
  local desc="$1" path="$2"
  if [[ ! -e "${path}" ]]; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc} — file should not exist: ${path}"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

assert_files_identical() {
  local desc="$1" a="$2" b="$3"
  if cmp -s "${a}" "${b}"; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc} — files differ"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc} — '${needle}' not found in output"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    echo "[PASS] ${desc}"
    PASS=$((PASS+1))
  else
    echo "[FAIL] ${desc} — '${needle}' should NOT be in output but was"
    FAILURES+=("${desc}")
    FAIL=$((FAIL+1))
  fi
}

# Test 1: Syntax check
echo "=== Test 1: syntax check ==="
if bash -n "${PHONEDROP}" 2>/dev/null; then
  echo "[PASS] phonedrop.sh passes bash -n"
  PASS=$((PASS+1))
else
  echo "[FAIL] phonedrop.sh has syntax errors"
  FAILURES+=("syntax check")
  FAIL=$((FAIL+1))
fi

# Test 2: Script executable
echo ""
echo "=== Test 2: script executable ==="
if [[ -x "${PHONEDROP}" ]]; then
  echo "[PASS] phonedrop.sh is executable"
  PASS=$((PASS+1))
else
  echo "[FAIL] phonedrop.sh is not executable"
  FAILURES+=("script executable")
  FAIL=$((FAIL+1))
fi

# Test 3: Config parse
echo ""
echo "=== Test 3: config parse ==="
TMP_CFG_DIR=$(mktemp -d)
TMP_CFG="${TMP_CFG_DIR}/config"
cat > "${TMP_CFG}" << 'CFG'
PHONE_HOST="test-phone"
ADB_PORT="9999"
DEST="/sdcard/DCIM/TestDrop/"
ADB_BIN="/opt/homebrew/bin/adb"
EXIFTOOL_BIN="/opt/homebrew/bin/exiftool"
TAILSCALE_BIN="/usr/local/bin/tailscale"
CFG

source "${TMP_CFG}"
assert_eq "PHONE_HOST parsed"  "test-phone"              "${PHONE_HOST}"
assert_eq "ADB_PORT parsed"    "9999"                    "${ADB_PORT}"
assert_eq "DEST parsed"        "/sdcard/DCIM/TestDrop/"  "${DEST}"
assert_eq "ADB_BIN parsed"     "/opt/homebrew/bin/adb"   "${ADB_BIN}"
rm -rf "${TMP_CFG_DIR}"
unset PHONE_HOST ADB_PORT DEST ADB_BIN TAILSCALE_BIN 2>/dev/null || true

# Test 4: Genuine exiftool EXIF/GPS strip (tool-level assertion)
echo ""
echo "=== Test 4: exiftool EXIF/GPS strip assertion ==="

if [[ ! -x "${EXIFTOOL_BIN}" ]]; then
  echo "[SKIP] exiftool not found at ${EXIFTOOL_BIN} — install with: brew install exiftool"
else
  TMP_EXIF_DIR=$(mktemp -d)

  TEST_ORIG="${TMP_EXIF_DIR}/orig.jpg"
  TEST_STRIPPED="${TMP_EXIF_DIR}/stripped.jpg"

  CREATED=0
  if command -v sips >/dev/null 2>&1; then
    TMP_PNG="${TMP_EXIF_DIR}/pixel.png"
    python3 - "${TMP_PNG}" << 'PYEOF'
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
    sips -s format jpeg "${TMP_PNG}" --out "${TEST_ORIG}" >/dev/null 2>&1 && CREATED=1
  fi

  if [[ "${CREATED}" -eq 0 ]]; then
    echo "[SKIP] could not create test JPEG"
  else
    assert_file_exists "test JPEG created" "${TEST_ORIG}"

    "${EXIFTOOL_BIN}" -overwrite_original \
      -GPSLatitude=51.5074 -GPSLongitude=-0.1278 \
      -GPSLatitudeRef=N -GPSLongitudeRef=W \
      "${TEST_ORIG}" >/dev/null 2>&1

    GPS_BEFORE=$("${EXIFTOOL_BIN}" -GPS:GPSLatitude "${TEST_ORIG}" 2>/dev/null || true)
    [[ -n "${GPS_BEFORE}" ]] && echo "[info] GPS injected: ${GPS_BEFORE}"

    cp "${TEST_ORIG}" "${TEST_STRIPPED}"
    "${EXIFTOOL_BIN}" -overwrite_original -all= "${TEST_STRIPPED}" >/dev/null 2>&1

    GPS_AFTER=$("${EXIFTOOL_BIN}" -GPS:all "${TEST_STRIPPED}" 2>/dev/null || true)
    assert_empty "GPS tags absent after strip" "${GPS_AFTER}"

    EXIF_AFTER=$("${EXIFTOOL_BIN}" -EXIF:all "${TEST_STRIPPED}" 2>/dev/null || true)
    assert_empty "EXIF tags absent after strip" "${EXIF_AFTER}"

    GPS_ORIG=$("${EXIFTOOL_BIN}" -GPS:GPSLatitude "${TEST_ORIG}" 2>/dev/null || true)
    assert_not_empty "original GPS untouched (original not mutated)" "${GPS_ORIG}"
  fi

  rm -rf "${TMP_EXIF_DIR}"
fi

# Test 5: cmd_push via stubs
echo ""
echo "=== Test 5: cmd_push with stubs (no phone required) ==="

STUB_DIR=$(mktemp -d)
ADB_LOG="${STUB_DIR}/adb.log"
EXIFTOOL_LOG="${STUB_DIR}/exiftool.log"

cat > "${STUB_DIR}/adb" << STUBEOF
#!/usr/bin/env bash
echo "\$@" >> "${ADB_LOG}"
if [[ "\${1:-}" == "connect" ]]; then
  if [[ -n "\${STUB_ADB_CONNECT_COUNTER_FILE:-}" ]]; then
    count=\$(cat "\${STUB_ADB_CONNECT_COUNTER_FILE}" 2>/dev/null || echo 0)
    count=\$((count+1))
    printf '%s\n' "\${count}" > "\${STUB_ADB_CONNECT_COUNTER_FILE}"
    if [[ "\${count}" -lt 3 ]]; then
      echo "error: Connection refused"
      exit 1
    fi
  fi
  if [[ "\${STUB_ADB_CONNECT_FAIL:-0}" == "1" ]]; then
    echo "failed to connect to \${2}"
    exit 1
  fi
  echo "connected to \${2}"
  exit 0
fi
if [[ "\${1:-}" == "devices" ]]; then
  echo "List of devices attached"
  printf "%b" "\${STUB_ADB_DEVICES-test-phone:5555	device\\n}"
  exit 0
fi
if [[ "\${1:-}" == "-s" && "\${3:-}" == "get-state" ]]; then
  if [[ "\${2:-}" == "test-phone:5555" ]]; then
    echo "\${STUB_ADB_REMOTE_STATE:-device}"
  else
    echo "\${STUB_ADB_USB_STATE:-device}"
  fi
  exit 0
fi
if [[ "\${1:-}" == "-s" && "\${3:-}" == "push" ]]; then
  exit 0
fi
if [[ "\${1:-}" == "-s" && "\${3:-}" == "shell" ]]; then
  exit 0
fi
exit 0
STUBEOF
chmod +x "${STUB_DIR}/adb"

if [[ -x "${EXIFTOOL_BIN}" ]]; then
  cat > "${STUB_DIR}/exiftool" << STUBEOF
#!/usr/bin/env bash
echo "\$@" >> "${EXIFTOOL_LOG}"
exec "${EXIFTOOL_BIN}" "\$@"
STUBEOF
else
  cat > "${STUB_DIR}/exiftool" << 'STUBEOF'
#!/usr/bin/env bash
echo "$@" >> "${EXIFTOOL_LOG}"
exit 0
STUBEOF
fi
chmod +x "${STUB_DIR}/exiftool"

STUB_CFG_DIR=$(mktemp -d)
STUB_CFG="${STUB_CFG_DIR}/config"
cat > "${STUB_CFG}" << CFGEOF
PHONE_HOST="test-phone"
ADB_PORT="5555"
DEST="/sdcard/DCIM/PhoneDrop/"
ADB_BIN="${STUB_DIR}/adb"
EXIFTOOL_BIN="${STUB_DIR}/exiftool"
TAILSCALE_BIN="/usr/bin/true"
CFGEOF

# --- 5a: configured remote online ---
echo ""
echo "--- 5a: remote online target selection ---"

WORK_DIR=$(mktemp -d)
ORIG_FILE="${WORK_DIR}/photo.jpg"

# Create a 1x1 JPEG with injected GPS (requires real exiftool)
if [[ -x "${EXIFTOOL_BIN}" ]] && command -v sips >/dev/null 2>&1; then
  TMP_PNG="${WORK_DIR}/pixel.png"
  python3 - "${TMP_PNG}" << 'PYEOF'
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
  sips -s format jpeg "${TMP_PNG}" --out "${ORIG_FILE}" >/dev/null 2>&1
  "${EXIFTOOL_BIN}" -overwrite_original -GPSLatitude=51.5 -GPSLongitude=-0.1 -GPSLatitudeRef=N -GPSLongitudeRef=W "${ORIG_FILE}" >/dev/null 2>&1
else
  printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9' > "${ORIG_FILE}"
fi

ORIG_MD5=$(md5 -q "${ORIG_FILE}" 2>/dev/null || md5sum "${ORIG_FILE}" | awk '{print $1}')

> "${ADB_LOG}"
> "${EXIFTOOL_LOG}"
STUB_ADB_REMOTE_STATE="device" \
STUB_ADB_DEVICES=$'test-phone:5555\tdevice\nusb-one\tdevice\n' \
PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
  bash "${PHONEDROP}" push "${ORIG_FILE}" 2>&1 | grep -v "^$" || true

AFTER_MD5=$(md5 -q "${ORIG_FILE}" 2>/dev/null || md5sum "${ORIG_FILE}" | awk '{print $1}')
assert_eq "original file not modified by push" "${ORIG_MD5}" "${AFTER_MD5}"

ADB_LOG_CONTENT=$(cat "${ADB_LOG}" 2>/dev/null || true)
assert_contains "adb push was called" "push" "${ADB_LOG_CONTENT}"
assert_contains "adb push references photo.jpg" "photo.jpg" "${ADB_LOG_CONTENT}"
assert_contains "remote online push uses -s host:port" "-s test-phone:5555 push" "${ADB_LOG_CONTENT}"
assert_contains "remote online mkdir uses -s host:port" "-s test-phone:5555 shell mkdir" "${ADB_LOG_CONTENT}"

if [[ -x "${EXIFTOOL_BIN}" ]]; then
  EXIFTOOL_LOG_CONTENT=$(cat "${EXIFTOOL_LOG}" 2>/dev/null || true)
  assert_contains "exiftool was called on temp copy" "-all=" "${EXIFTOOL_LOG_CONTENT}"
fi

rm -rf "${WORK_DIR}"

# --- 5b: configured remote offline, one USB device present ---
echo ""
echo "--- 5b: USB fallback target selection ---"

WORK_DIR_USB=$(mktemp -d)
USB_FILE="${WORK_DIR_USB}/usb.jpg"
printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9' > "${USB_FILE}"

> "${ADB_LOG}"
STUB_ADB_CONNECT_FAIL="1" \
STUB_ADB_REMOTE_STATE="offline" \
STUB_ADB_DEVICES=$'usb-serial\tdevice\n' \
PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
  bash "${PHONEDROP}" push "${USB_FILE}" 2>&1 | grep -v "^$" || true

ADB_LOG_USB=$(cat "${ADB_LOG}" 2>/dev/null || true)
assert_contains "USB fallback push uses -s usb serial" "-s usb-serial push" "${ADB_LOG_USB}"
assert_contains "USB fallback shell uses -s usb serial" "-s usb-serial shell" "${ADB_LOG_USB}"
assert_not_contains "USB fallback does not push to offline host" "-s test-phone:5555 push" "${ADB_LOG_USB}"

rm -rf "${WORK_DIR_USB}"

# --- 5c: no reachable devices ---
echo ""
echo "--- 5c: no reachable devices ---"

WORK_DIR_NONE=$(mktemp -d)
NO_DEVICE_FILE="${WORK_DIR_NONE}/none.jpg"
printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9' > "${NO_DEVICE_FILE}"
OSA_LOG="${WORK_DIR_NONE}/osascript.log"
OSA_RECORDER="${WORK_DIR_NONE}/osascript-recorder"
cat > "${OSA_RECORDER}" << STUBEOF
#!/usr/bin/env bash
{
  printf 'ARGS:'
  printf ' [%s]' "\$@"
  printf '\\nSCRIPT:\\n'
  cat
  printf '\\n'
} >> "${OSA_LOG}"
exit 0
STUBEOF
chmod +x "${OSA_RECORDER}"

> "${ADB_LOG}"
set +e
NO_DEVICE_OUTPUT=$(
  STUB_ADB_CONNECT_FAIL="1" \
  STUB_ADB_REMOTE_STATE="offline" \
  STUB_ADB_DEVICES="" \
  OSASCRIPT_BIN="${OSA_RECORDER}" \
  PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
    bash "${PHONEDROP}" push "${NO_DEVICE_FILE}" 2>&1
)
NO_DEVICE_STATUS=$?
set -e
ADB_LOG_NONE=$(cat "${ADB_LOG}" 2>/dev/null || true)
if [[ "${NO_DEVICE_STATUS}" -ne 0 ]]; then
  echo "[PASS] no devices exits non-zero"
  PASS=$((PASS+1))
else
  echo "[FAIL] no devices exits non-zero — command succeeded"
  FAILURES+=("no devices exits non-zero")
  FAIL=$((FAIL+1))
fi
OSA_LOG_NONE=$(cat "${OSA_LOG}" 2>/dev/null || true)
assert_contains "no devices opens error dialog" "display dialog" "${OSA_LOG_NONE}"
assert_contains "no devices dialog says could not send" "couldn't send" "${OSA_LOG_NONE}"
assert_contains "no devices gives actionable message" "PhoneDrop couldn't send" "${NO_DEVICE_OUTPUT}"
assert_not_contains "no devices does not push" " push " "${ADB_LOG_NONE}"

rm -rf "${WORK_DIR_NONE}"

# --- 5d: INJECTION REGRESSION — adversarial filename ---
echo ""
echo "--- 5d: adversarial filename injection regression ---"

WORK_DIR2=$(mktemp -d)
ADVERSARIAL_NAME="a;touch INJECTED.jpg"
ADVERSARIAL_FILE="${WORK_DIR2}/${ADVERSARIAL_NAME}"
printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9' > "${ADVERSARIAL_FILE}"

INJECTED_SENTINEL="${WORK_DIR2}/INJECTED.jpg"
assert_file_not_exists "sentinel INJECTED.jpg does not exist before test" "${INJECTED_SENTINEL}"

> "${ADB_LOG}"
STUB_ADB_REMOTE_STATE="device" \
STUB_ADB_DEVICES=$'test-phone:5555\tdevice\n' \
PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
  bash "${PHONEDROP}" push "${ADVERSARIAL_FILE}" 2>&1 | grep -v "^$" || true

assert_file_not_exists "injection did not execute (INJECTED.jpg not created)" "${INJECTED_SENTINEL}"

ADB_LOG_CONTENT2=$(cat "${ADB_LOG}" 2>/dev/null || true)
assert_not_contains "adb log does not contain raw ';touch'" ";touch" "${ADB_LOG_CONTENT2}"

assert_contains "adb push received sanitised filename" "a_touch_INJECTED.jpg" "${ADB_LOG_CONTENT2}"

rm -rf "${WORK_DIR2}"

# --- 5e: file with spaces in path ---
echo ""
echo "--- 5e: file path with spaces ---"

WORK_DIR3=$(mktemp -d)
mkdir -p "${WORK_DIR3}/My Photos"
SPACE_FILE="${WORK_DIR3}/My Photos/vacation photo.jpg"
printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9' > "${SPACE_FILE}"

ORIG_MD5_SPACE=$(md5 -q "${SPACE_FILE}" 2>/dev/null || md5sum "${SPACE_FILE}" | awk '{print $1}')

> "${ADB_LOG}"
STUB_ADB_REMOTE_STATE="device" \
STUB_ADB_DEVICES=$'test-phone:5555\tdevice\n' \
PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
  bash "${PHONEDROP}" push "${SPACE_FILE}" 2>&1 | grep -v "^$" || true

AFTER_MD5_SPACE=$(md5 -q "${SPACE_FILE}" 2>/dev/null || md5sum "${SPACE_FILE}" | awk '{print $1}')
assert_eq "original with spaces not modified" "${ORIG_MD5_SPACE}" "${AFTER_MD5_SPACE}"

ADB_LOG_SPACE=$(cat "${ADB_LOG}" 2>/dev/null || true)
assert_contains "adb push called for space-named file" "vacation_photo.jpg" "${ADB_LOG_SPACE}"

rm -rf "${WORK_DIR3}"

echo ""
echo "--- 5f: repeated basename across drops gets unique phone destinations ---"

WORK_DIR4=$(mktemp -d)
mkdir -p "${WORK_DIR4}/first" "${WORK_DIR4}/second"
FIRST_REPEAT_FILE="${WORK_DIR4}/first/photo.jpg"
SECOND_REPEAT_FILE="${WORK_DIR4}/second/photo.jpg"
printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9' > "${FIRST_REPEAT_FILE}"
printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9' > "${SECOND_REPEAT_FILE}"

> "${ADB_LOG}"
STUB_ADB_REMOTE_STATE="device" \
STUB_ADB_DEVICES=$'test-phone:5555\tdevice\n' \
PHONEDROP_STAMP="20260101_000000" \
PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
  bash "${PHONEDROP}" push "${FIRST_REPEAT_FILE}" 2>&1 | grep -v "^$" || true

STUB_ADB_REMOTE_STATE="device" \
STUB_ADB_DEVICES=$'test-phone:5555\tdevice\n' \
PHONEDROP_STAMP="20260101_000001" \
PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
  bash "${PHONEDROP}" push "${SECOND_REPEAT_FILE}" 2>&1 | grep -v "^$" || true

REPEAT_DESTS=()
while IFS= read -r dest; do
  REPEAT_DESTS+=("${dest}")
done < <(awk '$1 == "-s" && $3 == "push" {print $5}' "${ADB_LOG}")
assert_eq "two repeated-name pushes recorded" "2" "${#REPEAT_DESTS[@]}"
if [[ "${#REPEAT_DESTS[@]}" -eq 2 ]]; then
  assert_eq "first repeated-name destination is stamped" "/sdcard/DCIM/PhoneDrop/20260101_000000_photo.jpg" "${REPEAT_DESTS[0]}"
  assert_eq "second repeated-name destination is stamped" "/sdcard/DCIM/PhoneDrop/20260101_000001_photo.jpg" "${REPEAT_DESTS[1]}"
  assert_not_eq "separate drops do not reuse phone destination" "${REPEAT_DESTS[0]}" "${REPEAT_DESTS[1]}"
fi

rm -rf "${WORK_DIR4}"

echo ""
echo "--- 5g: rearm retries connect ---"

REARM_COUNTER=$(mktemp "${TMPDIR:-/tmp}/phonedrop-rearm-connect.XXXXXX")
printf '0\n' > "${REARM_COUNTER}"
> "${ADB_LOG}"
set +e
REARM_OUTPUT=$(
  STUB_ADB_CONNECT_COUNTER_FILE="${REARM_COUNTER}" \
  STUB_ADB_DEVICES=$'usb-serial\tdevice\n' \
  PHONEDROP_REARM_SLEEP=0 \
  PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
    bash "${PHONEDROP}" rearm 2>&1
)
REARM_STATUS=$?
set -e
assert_eq "rearm retry exits zero" "0" "${REARM_STATUS}"
assert_contains "rearm retry reports reconnect" "reconnected:" "${REARM_OUTPUT}"
rm -f "${REARM_COUNTER}"

echo ""
echo "--- 5h: autoarm no USB exits zero without tcpip ---"

> "${ADB_LOG}"
set +e
AUTOARM_NO_USB_OUTPUT=$(
  STUB_ADB_REMOTE_STATE="offline" \
  STUB_ADB_DEVICES="" \
  PHONEDROP_REARM_SLEEP=0 \
  PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
    bash "${PHONEDROP}" autoarm 2>&1
)
AUTOARM_NO_USB_STATUS=$?
set -e
ADB_LOG_AUTOARM_NO_USB=$(cat "${ADB_LOG}" 2>/dev/null || true)
assert_eq "autoarm no USB exits zero" "0" "${AUTOARM_NO_USB_STATUS}"
assert_contains "autoarm no USB logs skip" "no USB device; skip" "${AUTOARM_NO_USB_OUTPUT}"
assert_not_contains "autoarm no USB does not run tcpip" "tcpip" "${ADB_LOG_AUTOARM_NO_USB}"

echo ""
echo "--- 5i: autoarm USB arms wireless adb ---"

> "${ADB_LOG}"
set +e
AUTOARM_USB_OUTPUT=$(
  STUB_ADB_REMOTE_STATE="offline" \
  STUB_ADB_DEVICES=$'usb-auto\tdevice\n' \
  PHONEDROP_REARM_SLEEP=0 \
  PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
    bash "${PHONEDROP}" autoarm 2>&1
)
AUTOARM_USB_STATUS=$?
set -e
ADB_LOG_AUTOARM_USB=$(cat "${ADB_LOG}" 2>/dev/null || true)
assert_eq "autoarm USB exits zero" "0" "${AUTOARM_USB_STATUS}"
assert_contains "autoarm USB logs arming" "arming usb-auto" "${AUTOARM_USB_OUTPUT}"
assert_contains "autoarm USB runs tcpip on USB serial" "-s usb-auto tcpip 5555" "${ADB_LOG_AUTOARM_USB}"
assert_contains "autoarm USB connects to host" "connect test-phone:5555" "${ADB_LOG_AUTOARM_USB}"

echo ""
echo "--- 5j: autoarm already armed is idempotent ---"

> "${ADB_LOG}"
set +e
AUTOARM_ARMED_OUTPUT=$(
  STUB_ADB_REMOTE_STATE="device" \
  STUB_ADB_DEVICES=$'usb-auto\tdevice\n' \
  PHONEDROP_REARM_SLEEP=0 \
  PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
    bash "${PHONEDROP}" autoarm 2>&1
)
AUTOARM_ARMED_STATUS=$?
set -e
ADB_LOG_AUTOARM_ARMED=$(cat "${ADB_LOG}" 2>/dev/null || true)
assert_eq "autoarm already armed exits zero" "0" "${AUTOARM_ARMED_STATUS}"
assert_empty "autoarm already armed is quiet" "${AUTOARM_ARMED_OUTPUT}"
assert_not_contains "autoarm already armed does not run tcpip" "tcpip" "${ADB_LOG_AUTOARM_ARMED}"

echo ""
echo "--- 5k: autoarm multiple USB devices skips ---"

> "${ADB_LOG}"
set +e
AUTOARM_MULTI_USB_OUTPUT=$(
  STUB_ADB_REMOTE_STATE="offline" \
  STUB_ADB_DEVICES=$'usb-a\tdevice\nusb-b\tdevice\n' \
  PHONEDROP_REARM_SLEEP=0 \
  PHONEDROP_CONFIG_FILE="${STUB_CFG}" \
    bash "${PHONEDROP}" autoarm 2>&1
)
AUTOARM_MULTI_USB_STATUS=$?
set -e
ADB_LOG_AUTOARM_MULTI_USB=$(cat "${ADB_LOG}" 2>/dev/null || true)
assert_eq "autoarm multiple USB exits zero" "0" "${AUTOARM_MULTI_USB_STATUS}"
assert_contains "autoarm multiple USB logs skip" "multiple USB" "${AUTOARM_MULTI_USB_OUTPUT}"
assert_not_contains "autoarm multiple USB does not run tcpip" "tcpip" "${ADB_LOG_AUTOARM_MULTI_USB}"

rm -rf "${STUB_DIR}" "${STUB_CFG_DIR}"

# Summary
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -gt 0 ]]; then
  echo "Failed tests:"
  for f in "${FAILURES[@]}"; do
    echo "  - ${f}"
  done
  exit 1
fi
exit 0
