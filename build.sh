#!/usr/bin/env bash
# One-shot release build + Desktop export for 听歌小窝.
# Reads version from pubspec.yaml, outputs 听歌小窝-<version>.apk on Desktop.
set -euo pipefail

export JAVA_HOME="$HOME/dev/jdk21"
export ANDROID_HOME="$HOME/dev/android-sdk"
export PATH="$JAVA_HOME/bin:$HOME/dev/flutter/bin:$PATH"

version=$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)
# 「关于」上那一行跟着 pubspec 走：版本号写旧了，她截图报来的版本就是错的，
# 而排查全靠那句版本。
sed -i "s/static const appVersion = '.*';/static const appVersion = '$version';/" \
  lib/settings/app_settings.dart
echo "Building 听歌小窝-$version (release, arm64-v8a)…"

flutter build apk --release --split-per-abi

src=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
out="听歌小窝-$version.apk"
cp "$src" "$out"
rm -f ~/Desktop/听歌小窝.apk ~/Desktop/听歌小窝-*.apk
cp "$out" ~/Desktop/"$out"
echo "✔ $(du -sh ~/Desktop/"$out" | awk '{print $1}') → ~/Desktop/$out"
