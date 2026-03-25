#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Posey.xcodeproj"
SCHEME="Posey"
BUNDLE_ID="com.MarkFriedlander.Posey"
DERIVED_DATA="${POSEY_DEVICE_DERIVED_DATA_PATH:-/tmp/PoseyDeviceDerived}"
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphoneos/Posey.app"
RUNTIME_DIR="${POSEY_DEVICE_RUNTIME_DIR:-/tmp/posey-device-smoke}"
DEVICE_ID="${POSEY_DEVICE_ID:-${1:-}}"
FIXTURE_PATH="${POSEY_SMOKE_FIXTURE_PATH:-$ROOT/TestFixtures/LongDenseSample.txt}"

default_developer_dir() {
  local candidates=(
    "${POSEY_DEVELOPER_DIR:-}"
    "/Applications/Xcode.app/Contents/Developer"
    "/Applications/Xcode Release.app/Contents/Developer"
    "/Applications/Xcode-beta.app/Contents/Developer"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -n "${candidate}" && -d "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  echo ""
}

discover_device_id() {
  local json_path
  json_path="$(mktemp "${TMPDIR:-/tmp}/posey-device.XXXXXX.json")"

  if ! DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcrun devicectl list devices --json-output "${json_path}" --quiet >/dev/null 2>&1; then
    rm -f "${json_path}"
    return 1
  fi

  local device_id
  device_id="$(jq -r '
    .result.devices
    | map(select(.hardwareProperties.deviceType == "iPhone"))
    | map(select(.deviceProperties.bootState == "booted"))
    | map(select(.connectionProperties.pairingState == "paired"))
    | .[0].hardwareProperties.udid // empty
  ' "${json_path}")"

  rm -f "${json_path}"

  if [[ -n "${device_id}" ]]; then
    echo "${device_id}"
    return 0
  fi

  return 1
}

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run-device-smoke.sh [device-udid]

Environment overrides:
  POSEY_DEVICE_ID
  POSEY_DEVELOPER_DIR
  POSEY_DEVICE_DERIVED_DATA_PATH
  POSEY_DEVICE_RUNTIME_DIR
  POSEY_SMOKE_FIXTURE_PATH
EOF
}

XCODE_DEVELOPER_DIR="$(default_developer_dir)"

if [[ -z "${XCODE_DEVELOPER_DIR}" ]]; then
  echo "Could not find a usable Xcode developer directory."
  echo "Set POSEY_DEVELOPER_DIR to an installed Xcode app's Contents/Developer path."
  exit 1
fi

if [[ -z "${DEVICE_ID}" ]]; then
  DEVICE_ID="$(discover_device_id || true)"
fi

if [[ -z "${DEVICE_ID}" ]]; then
  usage
  echo
  echo "Could not find a connected paired iPhone."
  exit 1
fi

if [[ ! -f "${FIXTURE_PATH}" ]]; then
  echo "Fixture not found at ${FIXTURE_PATH}"
  exit 1
fi

FIXTURE_BASE64="$(base64 < "${FIXTURE_PATH}" | tr -d '\n')"
FIXTURE_NAME="$(basename "${FIXTURE_PATH}")"
FIXTURE_STEM="${FIXTURE_NAME%.*}"
FIXTURE_EXTENSION="${FIXTURE_NAME##*.}"
FIXTURE_EXTENSION_LOWER="$(printf '%s' "${FIXTURE_EXTENSION}" | tr '[:upper:]' '[:lower:]')"

echo "== Build =="
DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -destination "id=${DEVICE_ID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Built app not found at ${APP_PATH}"
  exit 1
fi

echo
echo "== Install =="
DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}"

mkdir -p "${RUNTIME_DIR}"
rm -f "${RUNTIME_DIR}"/posey.sqlite "${RUNTIME_DIR}"/posey.sqlite-shm "${RUNTIME_DIR}"/posey.sqlite-wal

echo
echo "== Launch =="
LAUNCH_ENV=(
  "DEVICECTL_CHILD_POSEY_TEST_MODE=1"
  "DEVICECTL_CHILD_POSEY_RESET_DATABASE=1"
  "DEVICECTL_CHILD_POSEY_PLAYBACK_MODE=simulated"
  "DEVICECTL_CHILD_POSEY_AUTOMATION_OPEN_FIRST_DOCUMENT=1"
  "DEVICECTL_CHILD_POSEY_AUTOMATION_PLAY_ON_APPEAR=1"
  "DEVICECTL_CHILD_POSEY_AUTOMATION_CREATE_NOTE_ON_APPEAR=1"
  "DEVICECTL_CHILD_POSEY_AUTOMATION_CREATE_BOOKMARK_ON_APPEAR=1"
  "DEVICECTL_CHILD_POSEY_AUTOMATION_NOTE_BODY=Automated smoke note"
)

case "${FIXTURE_EXTENSION_LOWER}" in
  txt)
    LAUNCH_ENV+=(
      "DEVICECTL_CHILD_POSEY_PRELOAD_TXT_TITLE=${FIXTURE_STEM}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_TXT_FILENAME=${FIXTURE_NAME}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_TXT_INLINE_BASE64=${FIXTURE_BASE64}"
    )
    ;;
  md|markdown)
    LAUNCH_ENV+=(
      "DEVICECTL_CHILD_POSEY_PRELOAD_MARKDOWN_TITLE=${FIXTURE_STEM}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_MARKDOWN_FILENAME=${FIXTURE_NAME}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_MARKDOWN_INLINE_BASE64=${FIXTURE_BASE64}"
    )
    ;;
  rtf)
    LAUNCH_ENV+=(
      "DEVICECTL_CHILD_POSEY_PRELOAD_RTF_TITLE=${FIXTURE_STEM}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_RTF_FILENAME=${FIXTURE_NAME}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_RTF_INLINE_BASE64=${FIXTURE_BASE64}"
    )
    ;;
  docx)
    LAUNCH_ENV+=(
      "DEVICECTL_CHILD_POSEY_PRELOAD_DOCX_TITLE=${FIXTURE_STEM}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_DOCX_FILENAME=${FIXTURE_NAME}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_DOCX_INLINE_BASE64=${FIXTURE_BASE64}"
    )
    ;;
  html|htm)
    LAUNCH_ENV+=(
      "DEVICECTL_CHILD_POSEY_PRELOAD_HTML_TITLE=${FIXTURE_STEM}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_HTML_FILENAME=${FIXTURE_NAME}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_HTML_INLINE_BASE64=${FIXTURE_BASE64}"
    )
    ;;
  epub)
    LAUNCH_ENV+=(
      "DEVICECTL_CHILD_POSEY_PRELOAD_EPUB_TITLE=${FIXTURE_STEM}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_EPUB_FILENAME=${FIXTURE_NAME}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_EPUB_INLINE_BASE64=${FIXTURE_BASE64}"
    )
    ;;
  pdf)
    LAUNCH_ENV+=(
      "DEVICECTL_CHILD_POSEY_PRELOAD_PDF_TITLE=${FIXTURE_STEM}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_PDF_FILENAME=${FIXTURE_NAME}"
      "DEVICECTL_CHILD_POSEY_PRELOAD_PDF_INLINE_BASE64=${FIXTURE_BASE64}"
    )
    ;;
  *)
    echo "Unsupported smoke fixture type: ${FIXTURE_EXTENSION}"
    exit 1
    ;;
esac

env "${LAUNCH_ENV[@]}" \
  DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" \
  xcrun devicectl device process launch \
    --device "${DEVICE_ID}" \
    --terminate-existing \
    "${BUNDLE_ID}"

sleep 5

echo
echo "== Runtime Files =="
DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcrun devicectl device info files \
  --device "${DEVICE_ID}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --subdirectory "Library/Application Support/Posey"

echo
echo "== Runtime DB Copy =="
DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcrun devicectl device copy from \
  --device "${DEVICE_ID}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --source "Library/Application Support/Posey/posey.sqlite" \
  --destination "${RUNTIME_DIR}/posey.sqlite"

DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcrun devicectl device copy from \
  --device "${DEVICE_ID}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --source "Library/Application Support/Posey/posey.sqlite-shm" \
  --destination "${RUNTIME_DIR}/posey.sqlite-shm" || true

DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcrun devicectl device copy from \
  --device "${DEVICE_ID}" \
  --domain-type appDataContainer \
  --domain-identifier "${BUNDLE_ID}" \
  --source "Library/Application Support/Posey/posey.sqlite-wal" \
  --destination "${RUNTIME_DIR}/posey.sqlite-wal" || true

echo
echo "== Runtime DB Summary =="
sqlite3 "${RUNTIME_DIR}/posey.sqlite" <<'SQL'
.timeout 2000
select 'documents', count(*) from documents;
select 'reading_positions', count(*) from reading_positions;
select 'notes', count(*) from notes;
select 'max_sentence_index', coalesce(max(sentence_index), 0) from reading_positions;
select 'titles', group_concat(title, ', ') from documents;
SQL

documents_count="$(sqlite3 "${RUNTIME_DIR}/posey.sqlite" "select count(*) from documents;")"
positions_count="$(sqlite3 "${RUNTIME_DIR}/posey.sqlite" "select count(*) from reading_positions;")"
notes_count="$(sqlite3 "${RUNTIME_DIR}/posey.sqlite" "select count(*) from notes;")"
max_sentence_index="$(sqlite3 "${RUNTIME_DIR}/posey.sqlite" "select coalesce(max(sentence_index), 0) from reading_positions;")"

echo
echo "== Runtime Assertions =="
echo "documents: ${documents_count}"
echo "reading_positions: ${positions_count}"
echo "notes: ${notes_count}"
echo "max_sentence_index: ${max_sentence_index}"

if [[ "${documents_count}" -lt 1 ]]; then
  echo "Device smoke failed: no document was imported on device."
  exit 1
fi

if [[ "${positions_count}" -lt 1 ]]; then
  echo "Device smoke failed: no reading position was stored on device."
  exit 1
fi

if [[ "${notes_count}" -lt 2 ]]; then
  echo "Device smoke failed: expected automated note and bookmark records on device."
  exit 1
fi

if [[ "${max_sentence_index}" -lt 1 ]]; then
  echo "Device smoke failed: playback did not appear to advance beyond the first sentence."
  exit 1
fi

echo
echo "Device smoke completed for ${BUNDLE_ID} on ${DEVICE_ID}"
