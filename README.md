# 黑洞桌面覆盖层（macOS）

这是透明、鼠标穿透的原生 AppKit + Metal 覆盖层：黑洞会直接在当前桌面和所有应用窗口的上方游荡，而不是显示在浏览器页面中。视觉实现参考 [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole)。

- 使用 Metal 逐像素积分 Schwarzschild 光子轨迹
- 光线可多次穿过倾斜吸积盘，形成上下弧、光子环和黑洞阴影
- 吸积盘包含开普勒旋转、温度梯度、相对论多普勒偏色与亮度增强
- 黑洞沿缓慢的 Lissajous 轨迹漂移，每块屏幕使用独立随机种子，轨迹互不相同且不同步，每次启动也不重复
- 使用 ScreenCaptureKit 捕获每块显示器，并排除本进程窗口以避免递归
- 按光子轨迹对桌面和应用窗口实时重采样，形成真实引力透镜畸变
- 重采样限定在黑洞周围的有界区域内，区域之外的像素完全透明，直接透出桌面本身，而不是绘制一份整屏桌面副本
- 鼠标、滚动和点击会正常传递给下方应用
- 覆盖所有显示器、桌面空间和全屏应用

首次运行需要在系统提示中允许“屏幕与系统音频录制”。如果权限尚未授予，应用仍会以透明覆盖层模式显示黑洞，只是没有桌面畸变；授权并重新启动后即可生效。

## 运行

    chmod +x macOS/run-overlay.command
    ./macOS/run-overlay.command

首次启动会调用系统 Swift 编译器，Metal 着色器由应用启动时编译，无需单独安装 Metal Toolchain。需要安装 Xcode 或 Command Line Tools。编译产物位于 `macOS/.build`，源码变动后会自动重新编译。

## 尺寸

通过 `--size [0-10]` 调整黑洞大小，`0` 最小、`10` 最大，默认 `5`：

    ./macOS/run-overlay.command --size 2          # 较小
    ./macOS/run-overlay.command --size 8          # 较大
    ./macOS/run-overlay.command --size 8 --speed 6   # 可与速度组合

刻度分段线性映射到阴影半径占屏幕高度的比例，锚定三点（`0`→0.02、`5`→0.055、`10`→0.16），使刻度 `5` 稳定保持默认观感、上半段拉到更大的上限。超出 `0-10` 会被截断，缺省或非法时回退到默认 `5`。数值越大，引力透镜作用范围越广，重采样区域也越大，GPU 开销随之升高。

## 漂移速度

通过 `--speed [0-10]` 调整黑洞漫游速度，`0` 静止、`10` 最快，默认 `5`，仅影响黑洞在屏幕上漂移的快慢，不改变吸积盘转速：

    ./macOS/run-overlay.command --speed 8
    ./macOS/run-overlay.command --size 8 --speed 6   # 可与尺寸组合

刻度线性映射到速度倍率（`0`→静止、`5`→1.0、`10`→2.0）。超出 `0-10` 会被截断，缺省或非法时回退到默认 `5`。每块屏幕的漂移轨迹带独立随机相位与时间偏移，各屏互不相同、互不同步，且每次启动都不一样。

## 屏幕数量

通过 `--screens N` 限制只在前 `N` 块显示器上渲染黑洞，缺省时覆盖所有显示器：

    ./macOS/run-overlay.command --screens 1          # 只在第一块屏幕渲染
    ./macOS/run-overlay.command --screens 2 --size 8   # 可与其他参数组合

`N` 最小为 `1`，非法输入按缺省处理（所有屏幕）。屏幕的取用顺序即系统 `NSScreen.screens` 的顺序，通常首块为主显示器。

## 吸附增大

通过 `--growth [0-10]` 让黑洞随时间“吞噬”桌面而缓慢膨胀，`0` 关闭（尺寸恒定，默认），数值越大膨胀越快：

    ./macOS/run-overlay.command --growth 5
    ./macOS/run-overlay.command --size 3 --growth 10   # 从小体积起步、持续变大

半径以指数方式从初始 `--size` 渐近逼近上限，上限对齐到 `--size` 的最大值（即 `--size 10` 对应的体积），`--growth 10` 时约 1 分钟接近上限。因此吸附能长到的最大体积恰好等于手动能设的最大尺寸。膨胀按帧间时间累积，与帧率无关；上限同时兜住引力透镜重采样区域的 GPU 开销。若 `--size` 本身已接近最大值，则几乎没有可增长的空间。

## 退出

- 全局退出快捷键：Control-Option-Command-Period（⌃⌥⌘.）。无论当前焦点在哪个应用，均可退出覆盖层。
- 该快捷键通过 macOS 系统热键 API 注册，不需要辅助功能或输入监控权限。
- 兜底方式：在启动它的 Terminal 中按 Control-C。

实现约束：所有后续图形逻辑必须在注册此全局退出热键之后执行，且不得移除 `registerGlobalQuitHotKey()` 调用。

## 代码位置

- `macOS/BlackHoleOverlay.swift`：透明覆盖窗口、ScreenCaptureKit 捕获、Metal 渲染管线与多屏管理
- `macOS/BlackHoleShaders.metal`：Schwarzschild 测地线积分、吸积盘、光子环着色器，以及黑洞周围有界重采样场
- `macOS/run-overlay.command`：自动构建和启动脚本
