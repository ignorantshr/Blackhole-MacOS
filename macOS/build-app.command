#!/bin/zsh
# 把黑洞覆盖层打包成可双击运行的 Blackhole.app。
# 产物位于 macOS/.build/Blackhole.app，可拖进「应用程序」或直接双击。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Blackhole"
BUNDLE_ID="com.ignorantshr.blackhole"
BUILD_DIR=".build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
EXE="$MACOS_DIR/BlackHoleOverlay"

echo "==> 编译可执行文件"
mkdir -p "$MACOS_DIR"
swiftc -parse-as-library -O \
  -module-cache-path /tmp/blackhole-screen-module-cache \
  -framework Cocoa -framework Carbon -framework CoreMedia -framework CoreVideo \
  -framework MetalKit -framework QuartzCore -framework ScreenCaptureKit \
  BlackHoleOverlay.swift -o "$EXE"

echo "==> 拷贝着色器（运行时从可执行文件同目录加载）"
cp BlackHoleShaders.metal "$MACOS_DIR/BlackHoleShaders.metal"

echo "==> 写入 Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>BlackHoleOverlay</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- 后台附件型 App：不占用程序坞图标，与 setActivationPolicy(.accessory) 对应 -->
    <key>LSUIElement</key>
    <true/>
    <!-- 屏幕录制权限的说明文案（系统在弹窗与「系统设置 > 隐私」中展示） -->
    <key>NSScreenCaptureUsageDescription</key>
    <string>用于捕获桌面画面，实现黑洞对桌面的引力透镜扭曲效果。</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc 代码签名（让权限授权绑定到稳定身份，重启后仍生效）"
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "完成：$PWD/$APP_DIR"
echo "  双击运行，或拖入「应用程序」文件夹。"
echo "  首次运行请在弹窗中允许「屏幕录制」，然后重新启动。"
echo "  退出：Control-Option-Command-Period（⌃⌥⌘.）。"
