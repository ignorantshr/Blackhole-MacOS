# 黑洞桌面覆盖层（macOS）

这是透明、鼠标穿透的原生 AppKit 覆盖层：黑洞会直接在当前桌面和所有应用窗口的上方游荡，而不是显示在浏览器页面中。

- 使用原生 AppKit 绘制移动的黑洞、阴影和微弱光环
- 不读取或截取屏幕内容，不需要“屏幕录制”权限
- 鼠标、滚动和点击会正常传递给下方应用
- 覆盖所有显示器、桌面空间和全屏应用

## 运行

    chmod +x macOS/run-overlay.command
    ./macOS/run-overlay.command

首次启动会调用系统自带的 Swift 编译器。编译产物位于 macOS/.build/BlackHoleOverlay；源码变动后会自动重新编译。

## 退出

- 全局退出快捷键：Control-Option-Command-Period（⌃⌥⌘.）。无论当前焦点在哪个应用，均可退出覆盖层。
- 该快捷键通过 macOS 系统热键 API 注册，不需要辅助功能或输入监控权限。
- 兜底方式：在启动它的 Terminal 中按 Control-C。

实现约束：所有后续图形逻辑必须在注册此全局退出热键之后执行，且不得移除 `registerGlobalQuitHotKey()` 调用。

## 代码位置

- macOS/BlackHoleOverlay.swift：透明覆盖窗口与黑洞动画
- macOS/run-overlay.command：构建和启动脚本
