# AwayLatch

AwayLatch 是一个 macOS 菜单栏工具，在监控的蓝牙低功耗设备离开时锁定 Mac。Apple Watch、iPhone 等设备都可以作为监控对象。解锁可以使用 macOS 自带的 Apple Watch 解锁功能。

[English](README.md)

## 从源码构建

需要支持蓝牙低功耗的 Mac 和 macOS 15.6 或更高版本。工程已在 Xcode 27.2 上验证。

1. 克隆仓库并打开工程。

   ```sh
   git clone https://github.com/LFGN-S/AwayLatch.git
   cd AwayLatch
   open AwayLatch.xcodeproj
   ```

2. 选择 **AwayLatch** 方案和 **My Mac**，然后选择 **Product → Run**。首次启动时允许蓝牙访问。允许通知后，AwayLatch 可以告知是哪台设备触发了锁屏。
3. 打开菜单栏中的「监控设备」，勾选一台或多台附近设备。菜单默认列出 macOS 报告的已配对设备。打开「显示其他附近设备」可以查找更多设备。已选设备信号丢失时仍会显示在列表顶部。

菜单跟随 macOS 的首选语言，默认回退到英文。

## 锁屏逻辑

每台设备独立监控。已选设备首次被确认在附近后，持续弱信号或失联就可能触发锁屏。

对于靠蓝牙广播监控的设备，AwayLatch 每隔离开确认时间的四分之一开扫一次。所有这类设备都收到合格读数后，当轮立即停扫。一个完整窗口里没有收到某台设备的合格读数，就给该设备计一次失败。扫描窗口时长按已观测到的广播间隔估算。

同一设备连续失败三轮后，AwayLatch 持续扫描到截止时刻。确认时间从**首次失败那轮的开扫时刻**算起。收到合格读数会清除该设备的确认状态。设定为 120 秒时，前三轮相隔 30 秒开扫。

确认时间太短、放不下分段扫描和末段确认时，AwayLatch 使用连续监控。锁屏、睡眠或禁用自动锁屏时会暂停监控。打开「监控设备」子菜单时会连续扫描，以发现附近设备。

## 设置

| 选项 | 作用 |
| --- | --- |
| 锁屏信号阈值 | 默认 −70 dBm，可选 −45 到 −90 dBm，每 5 dBm 一档。选择「关闭自动锁屏」可暂停离开锁屏。 |
| 离开确认时间 | 10 至 600 秒的预设档位。全程连续监控时，从发现弱信号或失联算起。 |
| 用屏幕保护程序锁屏 | 启动屏幕保护程序。macOS 的「锁定屏幕」设置控制何时要求输入密码。 |
| 登录时启动 | 登录 macOS 时启动 AwayLatch。 |

## 从 BLELock 迁移

先退出并移除 BLELock，再打开 AwayLatch。AwayLatch 首次启动时会导入已选设备和锁屏设置。macOS 可能会再次请求蓝牙和通知权限。

## 签名

Debug 和 Release 均使用本机临时签名（ad hoc），并启用 Hardened Runtime。用这套配置即可在本机编译和运行。要分发可下载的应用，请用自己的 **Developer ID Application** 身份签名，并提交 Apple 公证。 [Apple 公证指南](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 致谢与许可证

AwayLatch 基于 Shawn Rain 的 BLELock，BLELock 基于 Takeshi Sone 的 BLEUnlock。 [BLELock](https://github.com/ShawnRn/BLELock) · [BLEUnlock](https://github.com/ts1/BLEUnlock)

采用 MIT 许可证。 [LICENSE](LICENSE)
