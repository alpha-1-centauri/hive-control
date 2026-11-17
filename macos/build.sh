#!/bin/zsh
set -eu
ROOT="${0:A:h:h}"
APP="$ROOT/build/Hive Control.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx13.0 \
  "$ROOT/macos/HiveMenu.swift" -o "$APP/Contents/MacOS/HiveControl" \
  -framework SwiftUI -framework AppKit -framework ServiceManagement
cp "$ROOT/hive_control.py" "$APP/Contents/Resources/hive_control.py"
"$ROOT/.venv/bin/python" - "$APP" "$ROOT" <<'PY'
import json, plistlib, sys
from pathlib import Path
app, root = map(Path, sys.argv[1:])
(app / 'Contents/Resources/runtime.json').write_text(json.dumps({'python': str(root / '.venv/bin/python')}))
with (app / 'Contents/Info.plist').open('wb') as f:
    plistlib.dump({
        'CFBundleName': 'Hive Control', 'CFBundleDisplayName': 'Hive Control',
        'CFBundleIdentifier': 'uk.local.hive-control.menubar',
        'CFBundleExecutable': 'HiveControl', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1.0', 'CFBundleVersion': '1',
        'LSMinimumSystemVersion': '13.0', 'LSUIElement': True,
        'NSHighResolutionCapable': True,
        'NSAppleEventsUsageDescription': 'Hive Control opens local dialogs when you reconnect your Hive account.',
    }, f)
PY
codesign --force --sign - "$APP"
echo "$APP"
