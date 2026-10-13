SHELL := /bin/bash

# Override on the command line when needed, e.g.
#   make acceptance DEVICE=DEVICE_ID
DEVICE ?=
ARGS ?=
FLUTTER_BIN_DIR ?= $(HOME)/.local/share/flutter/bin
JAVA_HOME ?= /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
ANDROID_HOME ?= /opt/homebrew/share/android-commandlinetools
ADB ?= $(ANDROID_HOME)/platform-tools/adb
FLUTTER_BUILD_CACHE_KEEP ?= 12

export PATH := $(FLUTTER_BIN_DIR):$(PATH)
export JAVA_HOME
export ANDROID_HOME

APK_DEBUG := build/app/outputs/flutter-apk/app-debug.apk
APK_RELEASE := build/app/outputs/flutter-apk/app-release.apk

.PHONY: help deps analyze format test check verify-level build build-debug build-release \
        devices connect install install-debug install-release acceptance acceptance-per-file \
        restore-device verify-script clean clean-flutter-cache clean-flutter-cache-preview require-device require-backup

help:
	@printf '%s\n' \
	  'Usage: make <target> [DEVICE=<adb-serial>]' \
	  '' \
	  'Common:' \
	  '  make deps                  flutter pub get' \
	  '  make analyze               flutter analyze' \
	  '  make format                dart format lib test integration_test tool' \
	  '  make test                  unit/widget tests' \
	  '  make check                 analyze + Flutter tests + JS/tooling contracts' \
	  '  make verify-level         choose and run the smallest validation level' \
	  '  make build                 build debug and release APKs' \
	  '  make clean                 flutter clean (remove all generated state)' \
	  '  make clean-flutter-cache   remove old .dart_tool/flutter_build caches' \
	  '  make clean-flutter-cache-preview  preview cache cleanup' \
	  '' \
	  'Device:' \
	  '  make devices               list adb devices' \
	  '  make connect DEVICE=...    adb connect to a wireless device' \
	  '  make install DEVICE=...    build + install release APK' \
	  '  make install-debug DEVICE=...' \
	  '  make acceptance DEVICE=... full verification, combined tests + verified debug restore' \
	  '  make acceptance-per-file DEVICE=...  per-file debug installs' \
	  '  make restore-device DEVICE=... BACKUP=dir  finish a failed run from its backup' \
	  '  make verify-script SCRIPT=path/to/file.user.js' \
	  '' \
	  'Variables:' \
	  '  DEVICE=host:port       wireless adb device (required by device targets)' \
	  '  BACKUP=/tmp/...        retained backup dir printed by a previous run' \
	  '  ARGS=--restart-adb         extra flags passed to the acceptance script' \
	  '  FLUTTER_BUILD_CACHE_KEEP=N  keep the newest N Flutter build caches (default: 12)'

require-backup:
	@test -n "$(BACKUP)" || (printf '%s\n' 'BACKUP is required, e.g. make restore-device DEVICE=... BACKUP=/tmp/site-lens-android-backup-xxxx' >&2; exit 2)

require-device:
	@test -n "$(DEVICE)" || (printf '%s\n' 'DEVICE is required, e.g. make acceptance DEVICE=DEVICE_ID' >&2; exit 2)

deps:
	$(FLUTTER_BIN_DIR)/flutter pub get

analyze:
	$(FLUTTER_BIN_DIR)/flutter analyze

# No `format-check` gate on purpose: under Dart 3.13 (tall style) 22 of the 44
# tracked Dart files already diff, so a check would fail on a clean checkout.
# CI gates on ./tool/check.sh plus the Pigeon generated-code diff instead.
format:
	$(FLUTTER_BIN_DIR)/dart format lib test integration_test tool

test:
	$(FLUTTER_BIN_DIR)/flutter test

check:
	./tool/check.sh

verify-level:
	python3 tool/verify_level.py $(ARGS)

build-debug:
	$(FLUTTER_BIN_DIR)/flutter build apk --debug
	python3 tool/verify_android_artifact.py --debug

build-release:
	$(FLUTTER_BIN_DIR)/flutter build apk --release
	python3 tool/verify_android_artifact.py --formal

build: build-debug build-release

devices:
	$(ADB) devices -l

connect: require-device
	$(ADB) connect $(DEVICE)
	$(ADB) devices -l

install-debug: require-device build-debug
	$(ADB) -s $(DEVICE) install --no-streaming -r $(APK_DEBUG)

install-release: require-device build-release
	$(ADB) -s $(DEVICE) install --no-streaming -r $(APK_RELEASE)

install: install-release

# Default acceptance: build, check, run all integration suites through one
# app install, back up/restore the Drift database, then leave the normal debug build running.
acceptance: require-device
	python3 tool/run_android_acceptance.py $(DEVICE) --single-suite $(ARGS)

# Finish a run whose suites already passed but whose restore/install failed
# (wireless adb dropping mid-push): no test is replayed, no extra install.
restore-device: require-device require-backup
	python3 tool/run_android_acceptance.py $(DEVICE) --restore-from $(BACKUP) $(ARGS)

# Debugging fallback: same checks, but Flutter installs the debug APK per file.
acceptance-per-file: require-device
	python3 tool/run_android_acceptance.py $(DEVICE)

verify-script:
	@test -n "$(SCRIPT)" || (printf '%s\n' 'SCRIPT is required, e.g. make verify-script SCRIPT=MissPlayer.user.js' >&2; exit 2)
	$(FLUTTER_BIN_DIR)/dart run tool/verify_script.dart "$(SCRIPT)"

clean:
	$(FLUTTER_BIN_DIR)/flutter clean

clean-flutter-cache:
	python3 tool/clean_flutter_build_cache.py --keep "$(FLUTTER_BUILD_CACHE_KEEP)"

clean-flutter-cache-preview:
	python3 tool/clean_flutter_build_cache.py --keep "$(FLUTTER_BUILD_CACHE_KEEP)" --dry-run
