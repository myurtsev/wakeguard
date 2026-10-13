#!/bin/bash
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")" && pwd)"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE/Packaging/Info.plist")
OUTPUT="${1:-$SOURCE/../WakeGuard-build}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
if [[ "$OUTPUT" == / || "$OUTPUT" == /Applications ]]; then
    echo 'Kies een gewone uitvoermap; dit script installeert niets.' >&2; exit 1
fi
BUILD="$SOURCE/.build"
PAYLOAD="$BUILD/payload"
NATIVE_ARCH=arm64
mkdir -p "$BUILD"
cd "$SOURCE"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/Shared.swift Tests/PolicyTests.swift -o "$BUILD/policy-tests"
"$BUILD/policy-tests"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/Shared.swift Sources/Session.swift Tests/SessionTests.swift -o "$BUILD/session-tests"
"$BUILD/session-tests"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/Shared.swift Sources/LeaseClient.swift Tests/IPCChecks.swift -o "$BUILD/ipc-tests"
"$BUILD/ipc-tests"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/Shared.swift Sources/Session.swift Sources/Audit.swift Sources/Helper.swift Tests/HelperTests.swift -o "$BUILD/helper-check" -framework Foundation -framework IOKit
"$BUILD/helper-check"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/Shared.swift Sources/Audit.swift Sources/AuditClient.swift Tests/AuditTests.swift -o "$BUILD/audit-tests"
"$BUILD/audit-tests"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/Shared.swift Sources/HelperSetup.swift Tests/HelperSetupTests.swift -o "$BUILD/helper-setup-tests" -framework Security
"$BUILD/helper-setup-tests"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/AgentActivity.swift Tests/AgentActivityTests.swift -o "$BUILD/agent-tests"
"$BUILD/agent-tests"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/AgentActivity.swift Sources/CodexActivity.swift Tests/CodexActivityTests.swift -o "$BUILD/codex-tests"
"$BUILD/codex-tests"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/AgentActivity.swift Sources/ClaudeActivity.swift Tests/ClaudeActivityTests.swift -o "$BUILD/claude-tests"
"$BUILD/claude-tests"
swiftc -target "$NATIVE_ARCH-apple-macos13" Sources/Shared.swift Sources/ClaudeHooks.swift Tests/ClaudeHooksTests.swift -o "$BUILD/claude-hook-tests"
"$BUILD/claude-hook-tests"
python3 Tests/InstallerTests.py
bash -n "$SOURCE/Packaging/preinstall" "$SOURCE/Packaging/postinstall" "$SOURCE/build.sh"
plutil -lint "$SOURCE/Packaging/Info.plist" "$SOURCE/Packaging/nl.local.WakeGuard.plist"
APP="$OUTPUT/WakeGuard.app"
rm -rf "$APP" "$PAYLOAD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SOURCE/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$SOURCE/Packaging/WakeGuard.icns" "$APP/Contents/Resources/"
swiftc -O -target arm64-apple-macos13 Sources/Shared.swift Sources/LeaseClient.swift Sources/Audit.swift Sources/AuditClient.swift Sources/HelperSetup.swift Sources/PanelView.swift Sources/AgentActivity.swift Sources/CodexActivity.swift Sources/ClaudeActivity.swift Sources/ClaudeHooks.swift Sources/App.swift -o "$APP/Contents/MacOS/WakeGuard" -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Security
swiftc -O -target arm64-apple-macos13 Sources/Shared.swift Sources/Session.swift Sources/Audit.swift Sources/Helper.swift Sources/HelperMain.swift -o "$BUILD/nl.local.WakeGuard.helper" -framework Foundation -framework IOKit
codesign --force --sign - "$BUILD/nl.local.WakeGuard.helper"
mkdir -p "$PAYLOAD/Library/PrivilegedHelperTools" "$PAYLOAD/Library/LaunchDaemons" "$BUILD/scripts"
cp "$BUILD/nl.local.WakeGuard.helper" "$PAYLOAD/Library/PrivilegedHelperTools/"
cp "$SOURCE/Packaging/nl.local.WakeGuard.plist" "$PAYLOAD/Library/LaunchDaemons/"
cp "$SOURCE/Packaging/preinstall" "$SOURCE/Packaging/postinstall" "$BUILD/scripts/"
chmod 0755 "$BUILD/scripts/preinstall" "$BUILD/scripts/postinstall" "$PAYLOAD/Library/PrivilegedHelperTools/nl.local.WakeGuard.helper"
chmod 0644 "$PAYLOAD/Library/LaunchDaemons/nl.local.WakeGuard.plist"
pkgbuild --root "$PAYLOAD" --scripts "$BUILD/scripts" --identifier nl.local.WakeGuard.helper-installer --version "$APP_VERSION" --install-location / --ownership recommended "$BUILD/WakeGuard-helper-raw.pkg"
rm -rf "$BUILD/package"
pkgutil --expand "$BUILD/WakeGuard-helper-raw.pkg" "$BUILD/package"
# Keep existing shared directories' permissions; postinstall sets only our own files.
python3 - "$BUILD/package/PackageInfo" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
tree = ET.parse(path)
assert tree.getroot().attrib.get('overwrite-permissions') == 'true'
tree.getroot().set('overwrite-permissions', 'false')
tree.write(path, encoding='utf-8', xml_declaration=True)
PY
pkgutil --flatten "$BUILD/package" "$APP/Contents/Resources/WakeGuard-helper.pkg"
python3 Tests/InstallerTests.py --package "$APP/Contents/Resources/WakeGuard-helper.pkg" --helper "$BUILD/nl.local.WakeGuard.helper"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
rm -rf "$BUILD/dmg"
mkdir -p "$BUILD/dmg"
ditto --norsrc --noextattr --noacl "$APP" "$BUILD/dmg/WakeGuard.app"
ln -s /Applications "$BUILD/dmg/Applications"
hdiutil create -volname WakeGuard -srcfolder "$BUILD/dmg" -format UDZO -ov "$OUTPUT/WakeGuard.dmg"
echo "Built $OUTPUT/WakeGuard.app and $OUTPUT/WakeGuard.dmg; nothing installed."
