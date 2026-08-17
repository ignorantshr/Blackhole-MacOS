#!/bin/zsh
# 把黑洞覆盖层打包成可双击运行的 Blackhole.app。
# 产物位于 macOS/.build/Blackhole.app，可拖进「应用程序」或直接双击。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Blackhole"
BUNDLE_ID="com.ignorantshr.blackhole"

# 版本号来源（优先级从高到低）：
#   1) 环境变量 VERSION（如 VERSION=1.2.0 ./build-app.command，用于非 git 环境或临时覆盖）
#   2) git 最近的 v* tag（发版标准流程：打 git tag v1.2.0，此处自动解析出 1.2.0）
#   3) 兜底 0.0.0-dev（无 git 或无 tag 时）
# HEAD 若在 tag 之后还有提交，git describe 会得到 1.2.0-3-gabc123 这类后缀，
# 提示当前是“某发布版之后的开发构建”，便于区分正式发布与本地临时打包。
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git describe --tags --match 'v*' --dirty 2>/dev/null | sed 's/^v//')"
fi
: "${VERSION:=0.0.0-dev}"
# CFBundleShortVersionString 只接受形如 x.y.z 的纯数字版本，取版本号的第一段
# （去掉 -3-gabc123 / -dirty 等后缀）；完整字符串保留给 CFBundleVersion 做构建标识。
SHORT_VERSION="${VERSION%%-*}"
: "${SHORT_VERSION:=0.0.0}"

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
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
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

# 打包成可上传 GitHub Release 的单个 zip。必须用 ditto 而非普通 zip：
# ditto 能正确保留 .app 的代码签名与 bundle 结构，普通 zip 可能破坏签名、
# 导致用户下载后无法打开。文件名带版本号与芯片架构（arm64）。
ARCH="$(uname -m)"
ZIP_NAME="$APP_NAME-$VERSION-$ARCH.zip"
ZIP_PATH="$BUILD_DIR/$ZIP_NAME"
echo "==> 压缩为 $ZIP_NAME（ditto 保留签名）"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo ""
echo "完成：$PWD/$APP_DIR（版本 $VERSION）"
echo "  双击运行，或拖入「应用程序」文件夹。"
echo "  首次运行请在弹窗中允许「屏幕录制」，然后重新启动。"
echo "  退出：Control-Option-Command-Period（⌃⌥⌘.）。"
echo ""
echo "可上传 GitHub Release 的文件：$PWD/$ZIP_PATH"
