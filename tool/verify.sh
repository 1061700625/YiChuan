#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# FLUTTER_ROOT supports standalone SDK installations; FVM is optional.
if [[ -n "${FLUTTER_ROOT:-}" ]]; then
  flutter_bin="$FLUTTER_ROOT/bin/flutter"
elif [[ -x .fvm/flutter_sdk/bin/flutter ]]; then
  flutter_bin="$PWD/.fvm/flutter_sdk/bin/flutter"
else
  flutter_bin="$(command -v flutter || true)"
fi
if [[ -z "$flutter_bin" || ! -x "$flutter_bin" ]]; then
  echo 'Install Flutter 3.44.7 (or fvm install), then set FLUTTER_ROOT.' >&2
  exit 1
fi
flutter_bin="$(cd "$(dirname "$flutter_bin")" && pwd)/$(basename "$flutter_bin")"
version_json="$("$flutter_bin" --version --machine)"
if ! printf '%s\n' "$version_json" | /usr/bin/grep -Eq '"frameworkVersion"[[:space:]]*:[[:space:]]*"3\.44\.7"'; then
  echo 'Expected Flutter 3.44.7; select the SDK pinned in .fvmrc.' >&2
  exit 1
fi

if [[ "${1:-}" != '--no-android' ]]; then
  if [[ -z "${JAVA_HOME:-}" && "$(uname -s)" == Darwin ]]; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  fi
  java_bin="${JAVA_HOME:+$JAVA_HOME/bin/}java"
  if ! "$java_bin" -version 2>&1 | /usr/bin/grep -Eq 'version "17[.\"]'; then
    echo 'Android verification requires JDK 17; set JAVA_HOME.' >&2
    exit 1
  fi
  if [[ -n "${JAVA_HOME:-}" ]]; then export PATH="$JAVA_HOME/bin:$PATH"; fi
fi

"$flutter_bin" pub get
"$flutter_bin" analyze
"$flutter_bin" test
if [[ "${1:-}" != '--no-android' ]]; then
  "$flutter_bin" build apk --debug
fi
