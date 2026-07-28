#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  resolved_destination="$IOS_TEST_DESTINATION"
else
  # Reuse an already booted Simulator when one exists. CI can otherwise select
  # any available iPhone/iPad runtime without coupling this smoke test to a beta name.
  simulator_id="$(xcrun simctl list devices available -j | ruby -rjson -e '
    devices = JSON.parse(STDIN.read).fetch("devices").values.flatten
    candidates = devices.select { |item| item["isAvailable"] && item["name"].match?(/iPad|iPhone/) }
    chosen = candidates.find { |item| item["state"] == "Booted" } || candidates.first
    print chosen.fetch("udid", "") if chosen
  ')"
  if [[ -z "$simulator_id" ]]; then
    echo "No available iOS Simulator. Install an iOS runtime or set IOS_TEST_DESTINATION." >&2
    exit 1
  fi
  resolved_destination="platform=iOS Simulator,id=$simulator_id"
fi

echo "==> iOS English localization smoke"
xcodebuild test -quiet \
  -project ios/mimitag/mimitag.xcodeproj \
  -scheme mimitag \
  -destination "$resolved_destination" \
  -testLanguage en \
  -testRegion US \
  -only-testing:mimitagTests/LocalizationTests
