#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --sdk iphonesimulator --show-sdk-path >/dev/null
if [[ $# -ne 1 ]]; then echo 'Usage: tool/ios_acceptance.sh SIMULATOR_ID' >&2; exit 2; fi
flutter pub get
flutter build ios --simulator --no-codesign
flutter test integration_test/host_contract_test.dart -d "$1" --dart-define=ALLOW_LOCAL_TEST_PAGES=true
