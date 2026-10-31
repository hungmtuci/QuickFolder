#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

APP_NAME="QuickFolder"
BUNDLE_ID="com.hunglx.QuickFolder"
VERSION="1.3.3"
BUILD_NUM="7"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DIST_DIR="$PROJECT_DIR/dist"

echo "==> [1/5] Đang biên dịch $APP_NAME v$VERSION (Universal Binary arm64 + x86_64 Release)..."
if swift build -c release --product "$APP_NAME" --arch arm64 --arch x86_64 2>/dev/null; then
    BIN_PATH="$(swift build -c release --product "$APP_NAME" --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
else
    swift build -c release --product "$APP_NAME"
    BIN_PATH="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
fi

echo "==> [2/5] Đang tạo biểu tượng ứng dụng (AppIcon.icns)..."
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

swift - "$ICONSET_DIR" << 'SWIFT_ICON'
import AppKit

let args = CommandLine.arguments
let outDir = args[1]

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, name) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
    let inset = CGFloat(px) * 0.08
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let radius = bgRect.width * 0.225

    let path = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.45, blue: 0.96, alpha: 1.0),
        NSColor(calibratedRed: 0.04, green: 0.72, blue: 0.92, alpha: 1.0)
    ])!
    gradient.draw(in: path, angle: -45)

    if let symbol = NSImage(systemSymbolName: "folder.fill.badge.gearshape", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.46, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let configured = symbol.withSymbolConfiguration(config) {
            let symSize = configured.size
            let drawRect = NSRect(
                x: (CGFloat(px) - symSize.width) / 2.0,
                y: (CGFloat(px) - symSize.height) / 2.0,
                width: symSize.width,
                height: symSize.height
            )
            configured.draw(in: drawRect)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
SWIFT_ICON

echo "==> [3/5] Đang đóng gói $APP_NAME.app..."
TMP_STAGE="$(mktemp -d /tmp/quickfolder_pkg.XXXXXX)"
trap 'rm -rf "$TMP_STAGE"' EXIT
STAGE_APP="$TMP_STAGE/$APP_NAME.app"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"

ditto --noextattr "$BIN_PATH" "$STAGE_APP/Contents/MacOS/$APP_NAME"
chmod +x "$STAGE_APP/Contents/MacOS/$APP_NAME"
iconutil -c icns "$ICONSET_DIR" -o "$STAGE_APP/Contents/Resources/AppIcon.icns" || true

cat > "$STAGE_APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>vi</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUM}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>QuickFolder cần quyền đọc danh sách các cửa sổ đang mở trong Finder để giúp bạn chọn nhanh thư mục khi lưu hoặc mở file.</string>
</dict>
</plist>
EOF

cat > "$PROJECT_DIR/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
EOF

echo "==> [4/5] Đang ký số (Codesign)..."
xattr -cr "$STAGE_APP" 2>/dev/null || true

SIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -n1 | awk -F'"' '{print $2}')"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep "Apple Development" | head -n1 | awk -F'"' '{print $2}')"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "QuickFolder Developer"; then
    SIGN_IDENTITY="QuickFolder Developer"
fi

echo "    -> Sử dụng danh tính ký số: $SIGN_IDENTITY"
if ! codesign --force --deep --entitlements "$PROJECT_DIR/entitlements.plist" --sign "$SIGN_IDENTITY" "$STAGE_APP" 2>/dev/null; then
    codesign --force --deep --entitlements "$PROJECT_DIR/entitlements.plist" --sign - "$STAGE_APP"
fi

rm -rf "$APP_BUNDLE"
ditto --noextattr "$STAGE_APP" "$APP_BUNDLE"

echo "==> [5/5] Đang tạo bộ cài đặt .DMG và .ZIP tại thư mục dist/..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

DMG_STAGING="$TMP_STAGE/dmg_staging"
mkdir -p "$DMG_STAGING"

ditto --noextattr "$STAGE_APP" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

cat > "$DMG_STAGING/Cai_Dat_QuickFolder.command" << 'INSTALLER_EOF'
#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$DIR/QuickFolder.app"
APP_DST="/Applications/QuickFolder.app"

echo "===================================================="
echo "  Đang cài đặt QuickFolder vào /Applications..."
echo "===================================================="

pkill -f QuickFolder 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# Gỡ cờ cách ly Gatekeeper (Quarantine) khi chép từ máy khác sang
xattr -cr "$APP_DST" 2>/dev/null || true

echo "✓ Đã cài đặt thành công tại: $APP_DST"
echo "✓ Đang khởi chạy QuickFolder..."
open "$APP_DST"
echo ""
echo "Lưu ý: Trong lần chạy đầu tiên trên máy mới, hãy bấm 'Cấp quyền Accessibility' trong cửa sổ QuickFolder để ứng dụng có thể tự động điền đường dẫn thư mục."
sleep 2
INSTALLER_EOF
chmod +x "$DMG_STAGING/Cai_Dat_QuickFolder.command"
xattr -cr "$DMG_STAGING" 2>/dev/null || true

DMG_PATH="$DIST_DIR/${APP_NAME}-Installer-v${VERSION}.dmg"
hdiutil create -volname "${APP_NAME} Installer" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

ZIP_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}-macOS.zip"
ditto -c -k --noextattr --keepParent "$STAGE_APP" "$ZIP_PATH"

rm -rf "$DMG_STAGING"

echo "==> Hoàn tất!"
echo "    - Ứng dụng: $APP_BUNDLE"
echo "    - Bộ cài DMG: $DMG_PATH"
echo "    - Bản nén ZIP: $ZIP_PATH"
