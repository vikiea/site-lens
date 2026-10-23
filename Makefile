SHELL := /bin/bash

# Override on the command line when needed, e.g.
#   make acceptance DEVICE=DEVICE_ID
DEVICE ?=
ARGS ?=
BOOTSTRAP_ARGS ?=
ENV_FILE ?= .env.local
ENV_FILE_STATUS := $(shell python3 tool/bootstrap_dev.py validate-env --file "$(ENV_FILE)" >/dev/null 2>&1; echo $$?)
ifneq ($(ENV_FILE_STATUS),0)
$(error Could not parse ENV_FILE=$(ENV_FILE); run python3 tool/bootstrap_dev.py validate-env --file "$(ENV_FILE)" for details)
endif
# Environment values exported by an outer Make invocation carry an origin marker;
# they are project defaults, not new user overrides in a nested Make process.
FLUTTER_ROOT_EXTERNAL := $(if $(filter command line,$(origin FLUTTER_ROOT)),1,$(if $(filter environment,$(origin FLUTTER_ROOT)),$(if $(SITE_LENS_ENV_ORIGIN_FLUTTER_ROOT),$(if $(filter environment command line,$(SITE_LENS_ENV_ORIGIN_FLUTTER_ROOT)),1,0),1),0))
FLUTTER_BIN_EXTERNAL := $(if $(filter command line,$(origin FLUTTER_BIN_DIR)),1,$(if $(filter environment,$(origin FLUTTER_BIN_DIR)),$(if $(SITE_LENS_ENV_ORIGIN_FLUTTER_BIN_DIR),$(if $(filter environment command line,$(SITE_LENS_ENV_ORIGIN_FLUTTER_BIN_DIR)),1,0),1),0))
ANDROID_HOME_EXTERNAL := $(if $(filter command line,$(origin ANDROID_HOME)),1,$(if $(filter environment,$(origin ANDROID_HOME)),$(if $(SITE_LENS_ENV_ORIGIN_ANDROID_HOME),$(if $(filter environment command line,$(SITE_LENS_ENV_ORIGIN_ANDROID_HOME)),1,0),1),0))
ANDROID_SDK_ROOT_EXTERNAL := $(if $(filter command line,$(origin ANDROID_SDK_ROOT)),1,$(if $(filter environment,$(origin ANDROID_SDK_ROOT)),$(if $(SITE_LENS_ENV_ORIGIN_ANDROID_SDK_ROOT),$(if $(filter environment command line,$(SITE_LENS_ENV_ORIGIN_ANDROID_SDK_ROOT)),1,0),1),0))
# Command-line aliases take priority over environment aliases. Within the same
# layer, FLUTTER_BIN_DIR and ANDROID_HOME are the canonical choices.
ifeq ($(origin FLUTTER_ROOT),command line)
ifneq ($(origin FLUTTER_BIN_DIR),command line)
FLUTTER_BIN_EXTERNAL := 0
endif
endif
ifeq ($(origin FLUTTER_BIN_DIR),command line)
ifneq ($(origin FLUTTER_ROOT),command line)
FLUTTER_ROOT_EXTERNAL := 0
endif
endif
ifeq ($(origin ANDROID_HOME),command line)
ifneq ($(origin ANDROID_SDK_ROOT),command line)
ANDROID_SDK_ROOT_EXTERNAL := 0
endif
endif
ifeq ($(origin ANDROID_SDK_ROOT),command line)
ifneq ($(origin ANDROID_HOME),command line)
ANDROID_HOME_EXTERNAL := 0
endif
endif
ifeq ($(FLUTTER_ROOT_EXTERNAL)$(FLUTTER_BIN_EXTERNAL),10)
FLUTTER_BIN_DIR :=
else ifeq ($(FLUTTER_ROOT_EXTERNAL)$(FLUTTER_BIN_EXTERNAL),01)
FLUTTER_ROOT :=
else ifeq ($(FLUTTER_ROOT_EXTERNAL)$(FLUTTER_BIN_EXTERNAL),00)
FLUTTER_ROOT := $(shell python3 tool/bootstrap_dev.py env-value FLUTTER_ROOT --file "$(ENV_FILE)")
FLUTTER_BIN_DIR := $(shell python3 tool/bootstrap_dev.py env-value FLUTTER_BIN_DIR --file "$(ENV_FILE)")
endif
ifeq ($(ANDROID_HOME_EXTERNAL)$(ANDROID_SDK_ROOT_EXTERNAL),10)
ANDROID_SDK_ROOT :=
else ifeq ($(ANDROID_HOME_EXTERNAL)$(ANDROID_SDK_ROOT_EXTERNAL),01)
ANDROID_HOME :=
else ifeq ($(ANDROID_HOME_EXTERNAL)$(ANDROID_SDK_ROOT_EXTERNAL),00)
ANDROID_HOME := $(shell python3 tool/bootstrap_dev.py env-value ANDROID_HOME --file "$(ENV_FILE)")
ANDROID_SDK_ROOT := $(shell python3 tool/bootstrap_dev.py env-value ANDROID_SDK_ROOT --file "$(ENV_FILE)")
endif
JAVA_HOME ?= $(shell python3 tool/bootstrap_dev.py env-value JAVA_HOME --file "$(ENV_FILE)")
EMULATOR_AVD ?= $(shell python3 tool/bootstrap_dev.py env-value EMULATOR_AVD --file "$(ENV_FILE)")
AVD_NAME ?= $(shell python3 tool/bootstrap_dev.py env-value AVD_NAME --file "$(ENV_FILE)")
AVD_IMAGE ?= $(shell python3 tool/bootstrap_dev.py env-value AVD_IMAGE --file "$(ENV_FILE)")
SITE_LENS_SIGNING_PROPERTIES ?= $(shell python3 tool/bootstrap_dev.py env-value SITE_LENS_SIGNING_PROPERTIES --file "$(ENV_FILE)")
# Origin metadata lets doctor distinguish caller overrides from local defaults.
export SITE_LENS_ENV_ORIGIN_FLUTTER_ROOT := $(if $(filter environment command line,$(origin FLUTTER_ROOT)),$(origin FLUTTER_ROOT),$(if $(FLUTTER_ROOT),$(ENV_FILE),automatic discovery))
export SITE_LENS_ENV_ORIGIN_FLUTTER_BIN_DIR := $(if $(filter environment command line,$(origin FLUTTER_BIN_DIR)),$(origin FLUTTER_BIN_DIR),$(if $(FLUTTER_BIN_DIR),$(ENV_FILE),automatic discovery))
export SITE_LENS_ENV_ORIGIN_ANDROID_HOME := $(if $(filter environment command line,$(origin ANDROID_HOME)),$(origin ANDROID_HOME),$(if $(ANDROID_HOME),$(ENV_FILE),automatic discovery))
export SITE_LENS_ENV_ORIGIN_ANDROID_SDK_ROOT := $(if $(filter environment command line,$(origin ANDROID_SDK_ROOT)),$(origin ANDROID_SDK_ROOT),$(if $(ANDROID_SDK_ROOT),$(ENV_FILE),automatic discovery))
export SITE_LENS_ENV_ORIGIN_JAVA_HOME := $(if $(filter environment command line,$(origin JAVA_HOME)),$(origin JAVA_HOME),$(if $(JAVA_HOME),$(ENV_FILE),automatic discovery))
export SITE_LENS_ENV_ORIGIN_EMULATOR_AVD := $(if $(filter environment command line,$(origin EMULATOR_AVD)),$(origin EMULATOR_AVD),$(if $(EMULATOR_AVD),$(ENV_FILE),automatic discovery))
export SITE_LENS_ENV_ORIGIN_AVD_IMAGE := $(if $(filter environment command line,$(origin AVD_IMAGE)),$(origin AVD_IMAGE),$(if $(AVD_IMAGE),$(ENV_FILE),automatic discovery))
export SITE_LENS_ENV_ORIGIN_SITE_LENS_SIGNING_PROPERTIES := $(if $(filter environment command line,$(origin SITE_LENS_SIGNING_PROPERTIES)),$(origin SITE_LENS_SIGNING_PROPERTIES),$(if $(SITE_LENS_SIGNING_PROPERTIES),$(ENV_FILE),automatic discovery))
EMULATOR_AVD ?=
EMULATOR_SERIAL ?=
EMULATOR_TIMEOUT ?=45
EMULATOR_ARGS ?=
# Capture the calling environment before adding the selected SDK for recipes.
export SITE_LENS_ENV_FILE := $(ENV_FILE)
export SITE_LENS_PARENT_PATH := $(PATH)
FLUTTER_BIN_DIR := $(if $(FLUTTER_BIN_DIR),$(FLUTTER_BIN_DIR),$(if $(FLUTTER_ROOT),$(FLUTTER_ROOT)/bin,$(shell python3 tool/bootstrap_dev.py path flutter-bin)))
JAVA_HOME := $(if $(JAVA_HOME),$(JAVA_HOME),$(shell python3 tool/bootstrap_dev.py path java-home))
ANDROID_HOME := $(if $(ANDROID_HOME),$(ANDROID_HOME),$(if $(ANDROID_SDK_ROOT),$(ANDROID_SDK_ROOT),$(shell python3 tool/bootstrap_dev.py path android-home)))
ADB ?= $(ANDROID_HOME)/platform-tools/adb
FLUTTER_BUILD_CACHE_KEEP ?= 12

export PATH := $(FLUTTER_BIN_DIR):$(PATH)
export FLUTTER_ROOT
export FLUTTER_BIN_DIR
export JAVA_HOME
export ANDROID_HOME
export ANDROID_SDK_ROOT
export AVD_NAME
export AVD_IMAGE
export EMULATOR_AVD
export SITE_LENS_SIGNING_PROPERTIES

APK_DEBUG := build/app/outputs/flutter-apk/app-debug.apk
APK_RELEASE := build/app/outputs/flutter-apk/app-release.apk
BUILD_NAME ?=
BUILD_NUMBER ?=

.PHONY: help setup setup-system setup-agent doctor deps analyze format test check verify-level manual-evidence-template manual-evidence-approve build build-debug build-release \
        devices emulator-check connect install install-debug install-release acceptance acceptance-per-file \
        restore-device verify-script clean clean-flutter-cache clean-flutter-cache-preview require-device require-backup

help:
	@printf '%s\n' \
	  'Usage: make <target> [DEVICE=<adb-serial>]' \
	  '' \
	  'Common:' \
	  '  make setup                project dependencies + Pigeon generation' \
	  '  make setup-system         macOS host/Android SDK installation (explicit)' \
	  '  make setup-agent          install the official Codex Dart/Flutter plugin' \
	  '  make doctor               read-only toolchain and workspace diagnostics' \
	  '  make deps                  flutter pub get' \
	  '  make analyze               flutter analyze' \
	  '  make format                dart format lib test integration_test tool' \
	  '  make test                  unit/widget tests' \
	  '  make check                 analyze + Flutter tests + JS/tooling contracts' \
	  '  make verify-level         choose and run the smallest validation level' \
	  '  make manual-evidence-template LEVEL=L2 EVIDENCE=...  create a manual validation checklist' \
	  '  make manual-evidence-approve EVIDENCE=...            approve every manual checklist item' \
	  '  make build                 build debug and release APKs' \
	  '  make clean                 flutter clean (remove all generated state)' \
	  '  make clean-flutter-cache   remove old .dart_tool/flutter_build caches' \
	  '  make clean-flutter-cache-preview  preview cache cleanup' \
	  '' \
	  'Device:' \
	  '  make devices               list adb devices' \
	  '  make emulator-check        check or start an emulator and wait up to 45s' \
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
	  '  EMULATOR_AVD=name      AVD name to start for emulator-check' \
	  '  AVD_NAME=name          AVD name to create in setup-system' \
	  '  EMULATOR_SERIAL=id    adb serial to check, e.g. emulator-5554' \
	  '  EMULATOR_TIMEOUT=45   emulator startup timeout in seconds' \
	  '  EMULATOR_ARGS=...     extra arguments for tool/check_emulator.py' \
	  '  BACKUP=/tmp/...        retained backup dir printed by a previous run' \
	  '  ARGS=--restart-adb         extra flags passed to the acceptance script' \
	  '  BOOTSTRAP_ARGS=--dry-run   extra flags passed to setup targets' \
	  '  ENV_FILE=.env.local      project environment override file' \
	  '  FLUTTER_BUILD_CACHE_KEEP=N  keep the newest N Flutter build caches (default: 12)'

require-backup:
	@test -n "$(BACKUP)" || (printf '%s\n' 'BACKUP is required, e.g. make restore-device DEVICE=... BACKUP=/tmp/site-lens-android-backup-xxxx' >&2; exit 2)

require-device:
	@test -n "$(DEVICE)" || (printf '%s\n' 'DEVICE is required, e.g. make acceptance DEVICE=DEVICE_ID' >&2; exit 2)

setup:
	python3 tool/bootstrap_dev.py project $(BOOTSTRAP_ARGS)

setup-system:
	python3 tool/bootstrap_dev.py system $(BOOTSTRAP_ARGS)

setup-agent:
	python3 tool/bootstrap_dev.py agent $(BOOTSTRAP_ARGS)

doctor:
	python3 tool/bootstrap_dev.py doctor

deps:
	"$(FLUTTER_BIN_DIR)/flutter" pub get

analyze:
	"$(FLUTTER_BIN_DIR)/flutter" analyze

# No `format-check` gate on purpose: under Dart 3.13 (tall style) 22 of the 44
# tracked Dart files already diff, so a check would fail on a clean checkout.
# CI gates on ./tool/check.sh plus the Pigeon generated-code diff instead.
format:
	"$(FLUTTER_BIN_DIR)/dart" format lib test integration_test tool

test:
	"$(FLUTTER_BIN_DIR)/flutter" test

check:
	./tool/check.sh

verify-level:
	python3 tool/verify_level.py $(ARGS)

LEVEL ?= L2
EVIDENCE ?= .ci_cache/site-lens-manual-$(LEVEL).json

manual-evidence-template:
	python3 tool/manual_validation.py template \
		--level "$(LEVEL)" \
		$(if $(DEVICE),--device "$(DEVICE)",) \
		--output "$(EVIDENCE)"

manual-evidence-approve:
	@test -n "$(EVIDENCE)" || (printf '%s\n' 'EVIDENCE is required' >&2; exit 2)
	python3 tool/manual_validation.py approve --evidence "$(EVIDENCE)"

build-debug:
	"$(FLUTTER_BIN_DIR)/flutter" build apk --debug
	python3 tool/verify_android_artifact.py --debug

build-release:
	"$(FLUTTER_BIN_DIR)/flutter" build apk --release \
		$(if $(BUILD_NAME),--build-name "$(BUILD_NAME)",) \
		$(if $(BUILD_NUMBER),--build-number "$(BUILD_NUMBER)",)
	python3 tool/verify_android_artifact.py --formal \
		$(if $(BUILD_NAME),--version-name "$(BUILD_NAME)",) \
		$(if $(BUILD_NUMBER),--version-code "$(BUILD_NUMBER)",)

build: build-debug build-release

devices:
	"$(ADB)" devices -l

emulator-check:
	python3 tool/check_emulator.py --timeout "$(EMULATOR_TIMEOUT)" \
		$(if $(EMULATOR_AVD),--avd "$(EMULATOR_AVD)",) \
		$(if $(EMULATOR_SERIAL),--serial "$(EMULATOR_SERIAL)",) \
		$(EMULATOR_ARGS)

connect: require-device
	"$(ADB)" connect $(DEVICE)
	"$(ADB)" devices -l

install-debug: require-device build-debug
	"$(ADB)" -s $(DEVICE) install --no-streaming -r $(APK_DEBUG)

install-release: require-device build-release
	"$(ADB)" -s $(DEVICE) install --no-streaming -r $(APK_RELEASE)

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
	"$(FLUTTER_BIN_DIR)/dart" run tool/verify_script.dart "$(SCRIPT)"

clean:
	"$(FLUTTER_BIN_DIR)/flutter" clean

clean-flutter-cache:
	python3 tool/clean_flutter_build_cache.py --keep "$(FLUTTER_BUILD_CACHE_KEEP)"

clean-flutter-cache-preview:
	python3 tool/clean_flutter_build_cache.py --keep "$(FLUTTER_BUILD_CACHE_KEEP)" --dry-run
