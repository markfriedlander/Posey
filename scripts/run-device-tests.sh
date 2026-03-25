#!/bin/bash

set -euo pipefail

MODE="${1:-unit}"
DEVICE_ID="${2:-${POSEY_DEVICE_ID:-}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Posey.xcodeproj"
SCHEME="Posey"
DERIVED_DATA="${POSEY_DEVICE_DERIVED_DATA_PATH:-/tmp/PoseyDeviceDerived}"

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
  json_path="$(mktemp "${TMPDIR:-/tmp}/posey-devices.XXXXXX.json")"

  if ! DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcrun devicectl list devices --json-output "${json_path}" --quiet >/dev/null 2>&1; then
    rm -f "${json_path}"
    return 1
  fi

  local device_id
  device_id="$(jq -r '
    .result.devices
    | map(select(.deviceProperties.name != null))
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
  bash scripts/run-device-tests.sh unit [device-udid]
  bash scripts/run-device-tests.sh ui [device-udid]
  bash scripts/run-device-tests.sh all [device-udid]

Environment overrides:
  POSEY_DEVICE_ID
  POSEY_DEVELOPER_DIR
  POSEY_DEVICE_DERIVED_DATA_PATH
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
  echo "Could not find a connected paired iPhone."
  echo "Pass a device UDID explicitly or set POSEY_DEVICE_ID."
  exit 1
fi

case "${MODE}" in
  unit)
    DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -destination "id=${DEVICE_ID}" \
      -derivedDataPath "${DERIVED_DATA}" \
      -only-testing:PoseyTests \
      test
    ;;
  ui)
    DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -destination "id=${DEVICE_ID}" \
      -derivedDataPath "${DERIVED_DATA}" \
      -only-testing:PoseyUITests \
      test
    ;;
  all)
    DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -destination "id=${DEVICE_ID}" \
      -derivedDataPath "${DERIVED_DATA}" \
      test
    ;;
  *)
    usage
    exit 1
    ;;
esac
