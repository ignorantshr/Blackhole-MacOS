# Blackhole · 桌面上的一颗黑洞（macOS）

> 一颗会在屏幕上缓缓游荡的黑洞，用引力透镜扭曲你的桌面——而你照常工作。

在桌面最上层放一个会缓慢漫游的黑洞：它悬浮在所有窗口之上，用引力透镜把周围的桌面和应用真实地扭曲、拉出光子环和吸积盘光晕，而鼠标、点击、滚动照常穿透到下方的应用——你可以一边正常干活，一边让黑洞在屏幕上游荡。

- 真实的引力透镜：黑洞附近的桌面被弯曲、镜像，并显示明亮的吸积盘与光子环
- 缓慢自由漫游，覆盖所有显示器、桌面空间和全屏应用
- 完全鼠标穿透，不影响下方应用的任何操作
- 尺寸、速度、屏幕数量、是否随时间膨胀均可通过命令行参数调整

视觉实现参考 [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole)。

## 环境要求

- macOS，且已安装 Xcode 或 Command Line Tools（首次启动会自动编译，无需额外安装其他工具）
- 首次运行会弹出系统提示，请允许“屏幕录制”权限，否则只显示黑洞本身、没有桌面扭曲效果；授权后重新启动即可生效

## 运行

    chmod +x macOS/run-overlay.command
    ./macOS/run-overlay.command

首次启动需要编译，稍等片刻即可看到黑洞出现。之后启动会直接运行。

## 打包成 App

如果想要一个可以双击运行、拖进「应用程序」的正式 App，执行：

    chmod +x macOS/build-app.command
    ./macOS/build-app.command

完成后会在 `macOS/.build/` 下生成 `Blackhole.app`。双击即可运行（它是后台运行的，不会在程序坞占图标），首次运行同样需要在弹窗中允许「屏幕录制」权限并重新启动。想放进启动项、或分享给同一芯片架构（Apple 芯片 / Intel）的 Mac，用这个 App 最方便。

参数用法与下方相同：给 App 传参可在「终端」里运行 `open -a Blackhole --args --size 8`，日常双击则使用默认设置。

## 参数

所有参数都可以组合使用，例如：

    ./macOS/run-overlay.command --size 8 --speed 6 --screens 1

### 尺寸 `--size [0-10]`

调整黑洞大小，`0` 最小、`10` 最大，默认 `5`。数值越大，扭曲范围越广，画面开销也越高。

    ./macOS/run-overlay.command --size 2      # 较小
    ./macOS/run-overlay.command --size 8      # 较大

### 漂移速度 `--speed [0-10]`

调整黑洞在屏幕上漫游的快慢，`0` 静止、`10` 最快，默认 `5`。只影响移动速度，不改变吸积盘的旋转。

    ./macOS/run-overlay.command --speed 8

多显示器时，每块屏幕的漂移轨迹互不相同、互不同步，每次启动也都不一样。

### 屏幕数量 `--screens N`

限制只在前 `N` 块显示器上显示黑洞，默认覆盖所有显示器。`N` 最小为 `1`。

    ./macOS/run-overlay.command --screens 1   # 只在第一块屏幕显示

### 吸附增大 `--growth [0-10]`

让黑洞随时间缓慢“吞噬”桌面、逐渐变大，`0` 关闭（大小恒定，默认），数值越大膨胀越快。

    ./macOS/run-overlay.command --size 3 --growth 10   # 从小体积起步、持续变大

黑洞会从 `--size` 设定的初始大小逐渐逼近最大尺寸（`--growth 10` 约 1 分钟接近上限），能长到的最大体积与 `--size 10` 一致。

## 退出

- 全局快捷键 **Control-Option-Command-Period（⌃⌥⌘.）**：无论当前在用哪个应用，随时按下即可退出。
- 兜底方式：在启动它的“终端”窗口里按 Control-C。

## 省电说明

黑洞是持续渲染的动画，会占用一定的 GPU 和 CPU。为降低闲时功耗，超过 5 秒无鼠标/键盘操作时会自动降低刷新率，一有操作立刻恢复流畅——黑洞始终连续移动，只是闲置时更省电、机器更凉。尺寸越大开销越高，若在意功耗可适当调小 `--size` 或用 `--screens` 减少显示器数量。

## 许可与致谢

本项目以 MIT 协议发布，详见 [`LICENSE`](LICENSE)。

黑洞的视觉与物理模型改编自 [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole)（MIT 协议）。作为衍生作品，上游的完整版权与许可声明原样收录于 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。感谢原作者的开源工作。
