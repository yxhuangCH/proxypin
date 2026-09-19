#!/bin/sh
# Re-apply local patches to ohos dependencies after `flutter pub get` / ohpm install
# overwrites oh_modules. Run from the repo root: sh harmony/patches/apply.sh
set -e
found=0
while IFS= read -r dir; do
  TARGET="$dir/src/main/ets/plugin/editing/OhosAutoFillHelper.ets"
  if [ -f "$TARGET" ]; then
    cp harmony/patches/OhosAutoFillHelper.ets "$TARGET"
    echo "patched: $TARGET"
    found=1
  fi
done <<EOF
$(find ohos/oh_modules/.ohpm -type d -name "flutter_ohos" -path "*@ohos*")
EOF
if [ "$found" = "0" ]; then
  echo "target not found under ohos/oh_modules/.ohpm" >&2
  exit 1
fi
