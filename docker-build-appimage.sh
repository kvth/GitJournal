#!/usr/bin/env bash
#
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Builds the GitJournal Linux AppImage inside Docker, so the Flutter SDK and
# appimage-builder toolchain never touch the host system.
#
# Usage:
#   docker-build-appimage.sh [variant]
#     variant: pro (default) | nonpro
#
# This wraps the same `flutter build linux` + `appimage-builder` steps as
# scripts/build_linux.sh, just run inside a container. AppImageBuilder.yml's
# _CODE_PATH_ placeholder gets substituted with the in-container checkout
# path for the duration of the build and restored to its committed form
# afterward, so this leaves no permanent diff either.
#
# variant=pro patches lib/settings/app_config.dart's proMode/validateProMode
# defaults on disk for the duration of the build only (source file is
# restored to its original committed content afterward) instead of
# GitJournal's normal license-server-gated default, same as
# docker-build-apk.sh.
#
# Output: GitJournal-latest-x86_64.AppImage

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

VARIANT="${1:-pro}"

case "$VARIANT" in
  pro|nonpro) ;;
  *) echo "error: variant must be 'pro' or 'nonpro', got '$VARIANT'" >&2; exit 1 ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is not installed or not on PATH" >&2
  exit 1
fi

IMAGE_NAME="gitjournal-linux-builder"

# Toolchain image for building the GitJournal Linux AppImage without
# installing Flutter / the GTK dev headers / appimage-builder on the host.
DOCKERFILE_DIR="$(mktemp -d)"
cat > "$DOCKERFILE_DIR/Dockerfile" <<'EOF'
FROM ubuntu:22.04

# Pinned to match docker-build-apk.sh: newer Flutter (3.44.0+) made
# widgets.IconData a `final` class and dropped
# CupertinoPageTransitionsBuilder, which breaks this project's pinned
# font_awesome_flutter ^10.0.0 and lib/themes.dart. 3.41.9 is the last
# 3.41.x patch, satisfying pubspec.yaml's `flutter: ">=3.41.5"` while
# predating both breaking changes.
ARG FLUTTER_VERSION=3.41.9

ENV DEBIAN_FRONTEND=noninteractive \
    FLUTTER_HOME=/opt/flutter \
    PUB_CACHE=/opt/pub-cache \
    APPIMAGE_EXTRACT_AND_RUN=1 \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="${FLUTTER_HOME}/bin:${PATH}"

# clang/cmake/ninja/pkg-config/libgtk-3-dev/liblzma-dev: flutter build linux
#   toolchain requirements.
# libcurl4-openssl-dev: needed by sentry-native (pulled in via sentry_flutter
#   as a CMake FetchContent dependency) to find CURL at configure time.
# openjdk-17-jdk: the `jni` package's native CMakeLists.txt runs CMake's
#   FindJNI unconditionally (even for a desktop-only build), which needs
#   JNI/AWT headers and libjawt.so from a full JDK — headless JDK/JRE
#   packages don't include those.
# python3-pip/patchelf/desktop-file-utils/libgdk-pixbuf2.0-dev/fakeroot/
#   strace/squashfs-tools/zsync/appstream/file: appimage-builder's own
#   dependencies (https://appimage-builder.readthedocs.io).
# APPIMAGE_EXTRACT_AND_RUN=1 above makes the appimagetool/runtime binaries
# appimage-builder downloads extract-and-run instead of needing a FUSE
# mount, which containers don't have by default.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl git unzip xz-utils zip ca-certificates \
        clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
        libcurl4-openssl-dev openjdk-17-jdk \
        python3-pip patchelf desktop-file-utils libgdk-pixbuf2.0-dev \
        fakeroot strace squashfs-tools zsync appstream file \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir appimage-builder

# Flutter SDK, precached for Linux desktop only (skip android/ios/web
# artifacts).
RUN git clone --depth 1 -b "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${FLUTTER_HOME}" \
    && git config --global --add safe.directory "${FLUTTER_HOME}" \
    && flutter config --no-analytics --no-cli-animations --enable-linux-desktop \
    && flutter precache --linux \
    && flutter doctor -v

WORKDIR /app
EOF

echo "==> Building builder image (cached after the first run)"
docker build -t "$IMAGE_NAME" "$DOCKERFILE_DIR"
rm -rf "$DOCKERFILE_DIR"

# AppImageBuilder.yml's AppDir path is a placeholder (_CODE_PATH_) that
# scripts/build_linux.sh normally sed's in place. Since we bind-mount the
# real checkout into the container, do the same substitution but restore
# the original file afterward so this doesn't leave a permanent diff.
APPIMAGE_YML="$REPO_ROOT/AppImageBuilder.yml"
APPIMAGE_YML_BACKUP="$(mktemp)"
cp "$APPIMAGE_YML" "$APPIMAGE_YML_BACKUP"
restore_appimage_yml() {
  cp "$APPIMAGE_YML_BACKUP" "$APPIMAGE_YML"
  rm -f "$APPIMAGE_YML_BACKUP"
}
trap restore_appimage_yml EXIT
sed -i "s|_CODE_PATH_|/app|" "$APPIMAGE_YML"

# variant=pro: flip AppConfig's proMode/validateProMode defaults on disk for
# this build only, then restore the original file afterward — same
# temporary-patch approach as docker-build-apk.sh, so the checkout is left
# with no permanent diff either way.
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
trap 'restore_appimage_yml; restore_app_config' EXIT

echo "==> Building $VARIANT AppImage inside Docker"
docker run --rm \
  -v "$REPO_ROOT":/app \
  -v gitjournal-pub-cache:/opt/pub-cache \
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
    flutter build linux --release
    appimage-builder --skip-test
  '

# The container runs as root, so build/ and AppDir output (the AppImage
# itself, appimage-build/'s apt cache, and the .zsync/.bundle.yml
# byproducts) would otherwise end up root-owned on the host. Glob expansion
# needs to happen inside the container, against the mounted tree, not on
# the host.
docker run --rm \
  -v "$REPO_ROOT":/app \
  -w /app \
  alpine sh -c 'chown -R "$1:$2" build AppDir appimage-build *.AppImage *.zsync .bundle.yml 2>/dev/null || true' -- "$(id -u)" "$(id -g)"

APPIMAGE_PATH="$(find "$REPO_ROOT" -maxdepth 1 -name '*.AppImage' -print -quit)"
if [ -n "$APPIMAGE_PATH" ]; then
  echo "==> AppImage ready: $APPIMAGE_PATH"
else
  echo "==> Build finished but no .AppImage was found in $REPO_ROOT" >&2
fi
