#!/usr/bin/env bash
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the GitJournal Android APK inside Docker, so the Android SDK/NDK
# and Flutter SDK never touch the host system.
#
# Usage:
#   docker-build-apk.sh [flavor] [mode] [variant]
#     flavor:  dev (default) | prod
#     mode:    release (default) | debug | profile
#     variant: pro (default) | nonpro
#
# android/secrets/key.properties (the real signing key) is git-crypt
# encrypted in this checkout, so release/profile builds can't use
# GitJournal's actual release key. Instead this script temporarily replaces
# that file with its own key.properties pointing at a throwaway self-signed
# keystore, generating that keystore at android/app/local if it doesn't
# already exist. android/app/build.gradle itself is untouched; it just reads
# whatever key.properties is on disk. That gets you a real release/profile
# build (AOT compiled, no debug banner, no debug symbols) that installs fine,
# just not signed with GitJournal's actual key — so it can't be an upgrade
# path for a Play Store install, and reinstalling over a debug build of the
# same flavor needs `adb install -r` to fail over to `adb uninstall` first
# (different signature).
#
# variant=pro similarly patches lib/settings/app_config.dart's proMode/
# validateProMode defaults on disk for the duration of the build only
# (source file is restored to its original committed content afterward, so
# this leaves no permanent diff either) instead of GitJournal's normal
# license-server-gated default.
#
# Output: build/app/outputs/flutter-apk/app-<flavor>-<mode>.apk

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

FLAVOR="${1:-dev}"
MODE="${2:-release}"
VARIANT="${3:-pro}"

case "$FLAVOR" in
  dev|prod) ;;
  *) echo "error: flavor must be 'dev' or 'prod', got '$FLAVOR'" >&2; exit 1 ;;
esac
case "$MODE" in
  debug|release|profile) ;;
  *) echo "error: mode must be 'debug', 'release' or 'profile', got '$MODE'" >&2; exit 1 ;;
esac
case "$VARIANT" in
  pro|nonpro) ;;
  *) echo "error: variant must be 'pro' or 'nonpro', got '$VARIANT'" >&2; exit 1 ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is not installed or not on PATH" >&2
  exit 1
fi

IMAGE_NAME="gitjournal-android-builder"

# Toolchain image for building the GitJournal Android APK without installing
# the Android SDK / Flutter on the host.
#
# Versions below are pinned to what this checkout's android/app/build.gradle
# and the Flutter Gradle plugin expect (compileSdk 36, ndk 28.2.13676358).
# Bump them if pubspec.yaml's flutter/dart SDK constraints change.
DOCKERFILE_DIR="$(mktemp -d)"
cat > "$DOCKERFILE_DIR/Dockerfile" <<'EOF'
FROM eclipse-temurin:17-jdk-jammy

# Pinned deliberately: newer Flutter (3.44.0+) made widgets.IconData a
# `final` class and dropped CupertinoPageTransitionsBuilder, which breaks
# this project's pinned font_awesome_flutter ^10.0.0 and lib/themes.dart.
# 3.41.9 is the last 3.41.x patch, satisfying pubspec.yaml's
# `flutter: ">=3.41.5"` while predating both breaking changes.
ARG FLUTTER_VERSION=3.41.9
ARG ANDROID_CMDLINE_TOOLS_URL=https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
ARG ANDROID_PLATFORM=android-36
ARG ANDROID_BUILD_TOOLS=36.0.0
ARG ANDROID_NDK=28.2.13676358

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    FLUTTER_HOME=/opt/flutter \
    PUB_CACHE=/opt/pub-cache
ENV PATH="${FLUTTER_HOME}/bin:${ANDROID_SDK_ROOT}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT}/platform-tools:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl git unzip xz-utils zip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Android command-line tools + the exact SDK/NDK pieces this project needs.
RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdline-tools.zip "${ANDROID_CMDLINE_TOOLS_URL}" \
    && unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip \
    && yes | sdkmanager --licenses > /dev/null \
    && sdkmanager \
        "platform-tools" \
        "platforms;${ANDROID_PLATFORM}" \
        "build-tools;${ANDROID_BUILD_TOOLS}" \
        "ndk;${ANDROID_NDK}" > /dev/null

# Flutter SDK, precached for Android only (skip ios/web/desktop artifacts).
RUN git clone --depth 1 -b "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
    && git config --global --add safe.directory "${FLUTTER_HOME}" \
    && flutter config --no-analytics --no-cli-animations \
    && flutter precache --android \
    && flutter doctor -v

WORKDIR /app
EOF

echo "==> Building builder image (cached after the first run)"
docker build -t "$IMAGE_NAME" "$DOCKERFILE_DIR"
rm -rf "$DOCKERFILE_DIR"

# android/local.properties is host-specific (SDK/Flutter paths) and
# gitignored. Point it at the paths inside the container for this run, then
# restore whatever was there before (or remove it) once we're done.
LOCAL_PROPS="$REPO_ROOT/android/local.properties"
BACKUP=""
if [ -f "$LOCAL_PROPS" ]; then
  BACKUP="$(mktemp)"
  cp "$LOCAL_PROPS" "$BACKUP"
fi
restore_local_props() {
  if [ -n "$BACKUP" ]; then
    cp "$BACKUP" "$LOCAL_PROPS"
    rm -f "$BACKUP"
  else
    rm -f "$LOCAL_PROPS"
  fi
}
trap restore_local_props EXIT

cat > "$LOCAL_PROPS" <<'EOF'
flutter.sdk=/opt/flutter
sdk.dir=/opt/android-sdk
EOF

# release/profile need *a* signingConfig; GitJournal's real key isn't
# available (git-crypt encrypted), so move it out of the way for the
# duration of the build and substitute our own key.properties pointing at
# the throwaway keystore generated below. keytool refuses passwords under
# 6 chars, so this uses "locallocal" rather than build.gradle's built-in
# "local" placeholder (which is left untouched for plain debug builds).
KEY_PROPS="$REPO_ROOT/android/secrets/key.properties"
KEY_PROPS_BACKUP=""
if [ "$MODE" != "debug" ]; then
  if [ -f "$KEY_PROPS" ]; then
    KEY_PROPS_BACKUP="$(mktemp)"
    mv "$KEY_PROPS" "$KEY_PROPS_BACKUP"
  fi
  cat > "$KEY_PROPS" <<'EOF'
keyAlias=local
keyPassword=locallocal
storeFile=local
storePassword=locallocal
EOF
fi
restore_key_props() {
  if [ "$MODE" != "debug" ]; then
    rm -f "$KEY_PROPS"
    if [ -n "$KEY_PROPS_BACKUP" ]; then
      mv "$KEY_PROPS_BACKUP" "$KEY_PROPS"
    fi
  fi
}
trap 'restore_local_props; restore_key_props' EXIT

# variant=pro: flip AppConfig's proMode/validateProMode defaults on disk for
# this build only, then restore the original file afterward — same
# temporary-patch approach as local.properties/key.properties above, so the
# checkout is left with no permanent diff either way.
APP_CONFIG="$REPO_ROOT/lib/settings/app_config.dart"
APP_CONFIG_BACKUP=""
if [ "$VARIANT" = "pro" ]; then
  APP_CONFIG_BACKUP="$(mktemp)"
  cp "$APP_CONFIG" "$APP_CONFIG_BACKUP"
  sed -i \
    -e 's/bool proMode = false;/bool proMode = true;/' \
    -e 's/var validateProMode = true;/var validateProMode = false;/' \
    "$APP_CONFIG"
fi
restore_app_config() {
  if [ -n "$APP_CONFIG_BACKUP" ]; then
    cp "$APP_CONFIG_BACKUP" "$APP_CONFIG"
    rm -f "$APP_CONFIG_BACKUP"
  fi
}
trap 'restore_local_props; restore_key_props; restore_app_config' EXIT

echo "==> Building $FLAVOR/$MODE ($VARIANT) APK inside Docker"
docker run --rm \
  -v "$REPO_ROOT":/app \
  -v gitjournal-pub-cache:/opt/pub-cache \
  -v gitjournal-gradle-cache:/root/.gradle \
  -w /app \
  "$IMAGE_NAME" \
  bash -lc '
    set -euo pipefail
    # lib/.env.dart is gitignored; regenerate the blank placeholder if this
    # is a fresh clone that never had secrets/env.json decrypted.
    if [ ! -f lib/.env.dart ]; then
      dart scripts/setup_env.dart gen
    fi
    flutter pub get
    if [ "'"$MODE"'" != "debug" ] && [ ! -f android/app/local ]; then
      keytool -genkeypair -v -storetype PKCS12 \
        -keystore android/app/local -alias local \
        -storepass locallocal -keypass locallocal \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Local Build, OU=Local, O=Local, L=Local, S=Local, C=US"
    fi
    # This checkout pins Gradle 8.12 (android/gradle/wrapper/gradle-wrapper.properties),
    # older than what newer Flutter stable releases want as a minimum. Skip that
    # validation rather than bumping the project'"'"'s pinned Gradle version.
    flutter build apk --flavor '"$FLAVOR"' --'"$MODE"' --android-skip-build-dependency-validation
  '

# The container runs as root, so build/ output (and the generated
# keystore, if any) would otherwise end up root-owned on the host.
docker run --rm \
  -v "$REPO_ROOT/build":/build \
  -v "$REPO_ROOT/android/app":/android-app \
  alpine chown -R "$(id -u):$(id -g)" /build /android-app

APK_PATH="$REPO_ROOT/build/app/outputs/flutter-apk/app-${FLAVOR}-${MODE}.apk"
if [ -f "$APK_PATH" ]; then
  echo "==> APK ready: $APK_PATH"
else
  echo "==> Build finished but APK wasn't found at the expected path; check build/app/outputs/flutter-apk/" >&2
fi
