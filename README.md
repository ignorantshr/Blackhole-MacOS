# 黑洞桌面覆盖层（macOS）

这是透明、鼠标穿透的原生 AppKit + Metal 覆盖层：黑洞会直接在当前桌面和所有应用窗口的上方游荡，而不是显示在浏览器页面中。视觉实现参考 [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole)。

- 使用 Metal 逐像素积分 Schwarzschild 光子轨迹
- 光线可多次穿过倾斜吸积盘，形成上下弧、光子环和黑洞阴影
- 吸积盘包含开普勒旋转、温度梯度、相对论多普勒偏色与亮度增强
- 黑洞沿缓慢的 Lissajous 轨迹漂移，所有显示器分别实时渲染
- 使用 ScreenCaptureKit 捕获每块显示器，并排除本进程窗口以避免递归
- 按光子轨迹对桌面和应用窗口实时重采样，形成真实引力透镜畸变
- 鼠标、滚动和点击会正常传递给下方应用
- 覆盖所有显示器、桌面空间和全屏应用

首次运行需要在系统提示中允许“屏幕与系统音频录制”。如果权限尚未授予，应用仍会以透明覆盖层模式显示黑洞，但桌面畸变会在授权并重新启动后生效。

## 运行

    chmod +x macOS/run-overlay.command
    ./macOS/run-overlay.command

首次启动会调用系统 Swift 编译器，Metal 着色器由应用启动时编译，无需单独安装 Metal Toolchain。需要安装 Xcode 或 Command Line Tools。编译产物位于 `macOS/.build`，源码变动后会自动重新编译。

## 退出

- 全局退出快捷键：Control-Option-Command-Period（⌃⌥⌘.）。无论当前焦点在哪个应用，均可退出覆盖层。
- 该快捷键通过 macOS 系统热键 API 注册，不需要辅助功能或输入监控权限。
- 兜底方式：在启动它的 Terminal 中按 Control-C。

实现约束：所有后续图形逻辑必须在注册此全局退出热键之后执行，且不得移除 `registerGlobalQuitHotKey()` 调用。

## 代码位置

- `macOS/BlackHoleOverlay.swift`：透明覆盖窗口、ScreenCaptureKit 捕获、Metal 渲染管线与多屏管理
- `macOS/BlackHoleShaders.metal`：光线积分、吸积盘和光子环着色器
- `macOS/run-overlay.command`：自动构建和启动脚本
