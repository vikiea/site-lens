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
node tool/test_media_episode_identity.mjs
node tool/test_filter_runtime.mjs
python3 tool/test_android_tools.py
python3 tool/test_android_backup_identity.py
python3 tool/test_android_visual_acceptance.py
python3 tool/test_android_startup_trace.py
python3 tool/test_android_proxy_lease.py
python3 tool/test_android_proxy_fixture.py
python3 tool/test_run_android_proxy_acceptance.py
sh tool/test_fix_android_system_proxy.sh
python3 tool/test_native_crash_contract.py
python3 tool/test_native_media_contract.py
python3 tool/test_check_emulator.py
python3 tool/test_verify_level.py
python3 tool/test_bootstrap_dev.py
python3 tool/test_release_notes.py
python3 tool/test_release_version.py
python3 tool/test_release_pubspec.py
python3 tool/test_version_code.py
python3 tool/test_extract_release_version_codes.py
python3 tool/test_version_code_reservations.py
python3 tool/test_acceptance_evidence.py
python3 tool/generate_regression_matrix.py --check
python3 tool/check_regression_contracts.py
python3 tool/test_regression_contracts.py
python3 tool/check_ui_tokens.py
python3 tool/test_ui_tokens.py
python3 tool/test_release_identity.py
