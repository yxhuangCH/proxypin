#!/bin/sh
# Re-apply local patches to ohos dependencies after `flutter pub get` / ohpm install
# overwrites oh_modules. Run from the repo root: sh harmony/patches/apply.sh
set -e
TARGET=$(find ohos/oh_modules/.ohpm -type d -name "flutter_ohos" -path "*@ohos*" | head -1)/src/main/ets/plugin/editing/OhosAutoFillHelper.ets
if [ ! -f "$TARGET" ]; then
  echo "target not found: $TARGET" >&2
  exit 1
fi
cp harmony/patches/OhosAutoFillHelper.ets "$TARGET"
echo "patched: $TARGET"
