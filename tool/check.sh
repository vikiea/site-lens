#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
flutter pub get
# Use the locked Pigeon version and verify regeneration is deterministic.
dart run pigeon --input pigeons/web_host.dart
flutter analyze
flutter test
node tool/test_runtime.mjs
node tool/test_page_inspector.mjs

node tool/test_media_lifecycle.mjs
python3 tool/test_android_tools.py
python3 tool/test_check_emulator.py
python3 tool/test_verify_level.py
python3 tool/test_bootstrap_dev.py
