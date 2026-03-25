#!/bin/bash

set -euo pipefail

MODE="${1:-build}"
DESTINATION="${2:-${POSEY_TEST_DESTINATION:-}}"
PROJECT="Posey.xcodeproj"
SCHEME="Posey"
DERIVED_DATA="${POSEY_DERIVED_DATA_PATH:-/tmp/PoseyDerivedData}"

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

XCODE_DEVELOPER_DIR="$(default_developer_dir)"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run-tests.sh build
  bash scripts/run-tests.sh unit 'platform=iOS Simulator,name=iPhone 16'
  bash scripts/run-tests.sh ui 'platform=iOS Simulator,name=iPhone 16'
  bash scripts/run-tests.sh all 'platform=iOS Simulator,name=iPhone 16'

Environment overrides:
  POSEY_TEST_DESTINATION
  POSEY_DERIVED_DATA_PATH
EOF
}

require_destination() {
  if [[ -z "${DESTINATION}" ]]; then
    echo "A simulator or device destination is required for '${MODE}'."
    echo "Example: bash scripts/run-tests.sh ${MODE} 'platform=iOS Simulator,name=iPhone 16'"
    exit 1
  fi
}

require_developer_dir() {
  if [[ -z "${XCODE_DEVELOPER_DIR}" ]]; then
    echo "Could not find a usable Xcode developer directory."
    echo "Set POSEY_DEVELOPER_DIR to an installed Xcode app's Contents/Developer path."
    exit 1
  fi
}

case "${MODE}" in
  build)
    require_developer_dir
    DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "${DERIVED_DATA}" \
      CODE_SIGNING_ALLOWED=NO \
      build-for-testing
    ;;
  unit)
    require_destination
    require_developer_dir
    DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -destination "${DESTINATION}" \
      -only-testing:PoseyTests \
      test
    ;;
  ui)
    require_destination
    require_developer_dir
    DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -destination "${DESTINATION}" \
      -only-testing:PoseyUITests \
      test
    ;;
  all)
    require_destination
    require_developer_dir
    DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" xcodebuild \
      -project "${PROJECT}" \
      -scheme "${SCHEME}" \
      -destination "${DESTINATION}" \
      test
    ;;
  *)
    usage
    exit 1
    ;;
esac
