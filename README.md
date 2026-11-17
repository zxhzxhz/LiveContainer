> [!IMPORTANT]
> **This is a personal fork of [LiveContainer](https://github.com/LiveContainer/LiveContainer)**.
>
> 本项目为个人维护的 LiveContainer 增强分支，在官方最新主线基础上增加了 **iOS 26+ 后台保活（Continued Processing Task + 静音音频兜底）、主程序与子应用持续 HTTP API 远程控制、SideStore 重签名兼容、源刷新逻辑优化、应用列表文件夹分类、游戏模式优化** 等特性。
>
> 📦 **下载最新编译 IPA**: 见 [Releases](../../releases)  
> 📝 **改动详情**: 见文末 [相比官方版本的改动列表](#相比官方版本的改动列表-changes-compared-to-upstream)

<div align="center">
   <img width="217" height="217" src="./screenshots/livecontainer_icon.png" alt="Logo">
</div>
   

<div align="center">
  <h1><b>LiveContainer</b></h1>
  <p><i>An app launcher that runs iOS apps without actually installing them! </i></p>
</div>
<h6 align="center">

Crowdin Project: [![Crowdin](https://badges.crowdin.net/livecontainer/localized.svg)](https://crowdin.com/project/livecontainer) &nbsp;| &nbsp; Documentation:[livecontainer.github.io](https://livecontainer.github.io/docs/intro)

# LiveContainer

- LiveContainer is an app launcher (not emulator or hypervisor) that allows you to run iOS apps inside it.
- Allows you to install unlimited apps (3 app/10 app id free developer account limit does not apply here) with only one app & app id. You can also have multiple versions of an app installed with multiple data containers.
- (Below iOS 26) When JIT is available, codesign is entirely bypassed, no need to sign your apps before installing. Otherwise, your app will be signed with the same certificate used by LiveContainer.

> [!CAUTION]
> **Important Notice Regarding Third-Party Builds of LiveContainer**
>
> We have recently noticed the appearance of certain closed-source third-party builds of LiveContainer. Please be aware that all your apps are installed within LiveContainer, which means these third-party builds **have full access to your data, including sensitive information such as keychain items and login credentials**. 
> 
> Furthermore, please note that we do not provide any support for issues of these third-party builds.


# Installation
**LiveContainer comes with a standalone version and a version with built-in SideStore. [Please read the install guide here](https://livecontainer.github.io/docs/installation)**

If you encounter any issue please [read our FAQ here](https://livecontainer.github.io/docs/faq)

### Standalone 
<table>
<tr>
<td>
Stable
</td>
<td>
<a href="https://stikstore.app/altdirect/?url=https://github.com/LiveContainer/LiveContainer/releases/download/1.0/apps.json&exclude=livecontainer" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200"/>
</a>
</td>
<td>
<a href="https://github.com/LiveContainer/LiveContainer/releases/latest/download/LiveContainer.ipa" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/Download_Blue.png" alt="Download .ipa" width="200"/>
</a>
</td>
</tr>
<tr>
<td>
Nightly
</td>
<td>
<a href="https://stikstore.app/altdirect/?url=https://github.com/LiveContainer/LiveContainer/releases/download/nightly/apps_nightly.json&exclude=livecontainer" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200"/>
</a>
</td>
<td>
<a href="https://github.com/LiveContainer/LiveContainer/releases/download/nightly/LiveContainer.ipa" target="_blank">
   <img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/Download_Blue.png" alt="Download .ipa" width="200"/>
</a>
</td>
</tr>
</table>

### LiveContainer+SideStore
|Stable|Nightly|
|:-:|:-:|
|<a href="https://github.com/LiveContainer/LiveContainer/releases/latest/download/LiveContainer+SideStore.ipa" target="_blank"><img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/Download_Blue.png" alt="Download .ipa" width="200" /></a>|<a href="https://github.com/LiveContainer/LiveContainer/releases/download/nightly/LiveContainer+SideStore.ipa" target="_blank"><img src="https://raw.githubusercontent.com/StikStore/altdirect/refs/heads/main/assets/png/Download_Blue.png" alt="Download .ipa" width="200" /></a>|


## Requirements

- iOS/iPadOS 15+
   + Multitasking requires iOS/iPadOS 16.0+
- AltStore 2.0+ / SideStore 0.6.0+


# Features & Guides

### Installing Apps
- Open LiveContainer, tap the plus icon in the upper right hand corner and select IPA files to install.
- Choose the app you want to open in the next launch.
- You can long-press the app to manage it.

### [Add Apps to Home Screen](https://livecontainer.github.io/docs/guides/add-to-home-screen)

### [Multiple LiveContainers](https://livecontainer.github.io/docs/guides/multiple-livecontainers)
Using multiple LiveContainers allows you to run multiples different apps simultaneously, with *almost* seamless data transfer between the LiveContainers.

### [Multitasking](https://livecontainer.github.io/docs/guides/multitask)
You can now launch multiple apps simultaneously in in-app virtual windows. These windows can be resized, scaled, and even displayed using the native Picture-in-Picture (PiP) feature. On iPads, apps can run in native window mode, displaying each app in a separate system window. And if you wish, you can choose to run apps in multitasking mode by default in settings.

To use multitasking, hold its banner and tap **"Multitask"**. You can also make Multitask the default launch mode in settings.

>[!Note]
>1. To use multitasking, ensure you select **"Keep App Extensions"** when installing via SideStore/AltStore.  
>2. If you want to enable JIT for multitasked apps, you’ll need a JIT enabler that supports attaching by PID. (StikDebug)

### [JIT Support](https://livecontainer.github.io/docs/guides/jit-support)
### [Installing external tweaks](https://livecontainer.github.io/docs/guides/tweaks)
### [Multiple Containers/External Containers](https://livecontainer.github.io/docs/guides/containers-and-external-data)
### [Hiding Apps](https://livecontainer.github.io/docs/guides/lock-app)

### Fix File Picker & Local Notification
Some apps may experience issues with their file pickers or not be able to apply for notification permission in LiveContainer. To resolve this, enable "Fix File Picker" & "Fix Local Notifications" accordingly in the app-specific settings.

### "Open In App" Support
- You can simply share a URL or a file to app simply by using iOS's native share sheet. In share sheet, select LiveContainer, and LiveContainer will ask you which app you'd like to open that URL/file in.
- What's more, you also can tap the link icon in the top-right corner of the "Apps" tab and input the URL. LiveContainer will detect the appropriate app and ask if you want to launch it.

## Compatibility
Unfortunately, not all apps work in LiveContainer, so we have a [compatibility list](https://github.com/LiveContainer/LiveContainer/labels/compatibility) to tell if there is apps that have issues. If they aren't on this list, then it's likely going run. However, if it doesn't work, please make an [issue](https://github.com/LiveContainer/LiveContainer/issues/new/choose) about it.

## Building
Open Xcode, edit `DEVELOPMENT_TEAM[config=Debug]` in `xcconfigs/Global.xcconfig` to your team id and compile.

## UI folders (this fork)
This fork adds folders to the app list:

- create one from the sort menu (`New Folder`), rename / pin / delete from the folder's long press menu
- pin folder rows stay on top of the app list
- each folder keeps its own sort setting and its own custom order
- apps can be moved into a folder from the app's context menu (`Move to Folder`) or from the folder's `+` picker; a moved app disappears from the root list
- searching looks at every app, folders included

Folder assignments are **not** written into the guest app database. They live in

```
Documents/LCUIFolders.json
```

so installing the official LiveContainer over this build only makes the folder feature disappear: all apps are back in a single flat list and nothing else breaks. Reinstalling this build restores the folders.

## Project structure
### Main executable
- Core of LiveContainer
- Contains the logic of setting up guest environment and loading guest app.
- If no app is selected, it loads LiveContainerSwiftUI.

### LiveContainerSwiftUI
- SwiftUI rewrite of LiveContainerUI (by @hugeBlack)
- Language file `Localizable.xcstrings` is in here for multilingual support. To help us translate LiveContainer, please visit [our crowdin project](https://crowdin.com/project/livecontainer)

### MultitaskSupport
- Contains the implementation of multitasking feature.
- Based on [FrontBoardAppLauncher](https://github.com/khanhduytran0/FrontBoardAppLauncher)

### SideStore
- Supporting code for SideStore's app refreshing integration

### TweakLoader
- A simple tweak injector, which loads CydiaSubstrate and loads tweaks.
- Injected to every app you install in LiveContainer.

### ZSign
- The app signer shipped with LiveContainer.
- Originally made by [zhlynn](https://github.com/zhlynn/zsign).
- LiveContainer uses [Feather's](https://github.com/khcrysalis/Feather) version of ZSign modified by khcrysalis.
- Changes are made to meet LiveContainer's needs.

## How does it work?

### Patching guest executable
- Patch `__PAGEZERO` segment:
  + Change `vmaddr` to `0xFFFFC000` (`0x100000000 - 0x4000`)
  + Change `vmsize` to `0x4000`
- Change `MH_EXECUTE` to `MH_DYLIB`.
- Inject a load command to load `TweakLoader.dylib`

### Patching `@executable_path`
- Hook `dyld4::APIs::_NSGetExecutablePath`
- Call `_NSGetExecutablePath`
- Replace `config.process.mainExecutablePath`
  - Calculate address of `config.process.mainExecutablePath` using `dyld4::APIs` instance (passed as first parameter)
  - Use `builtin_vm_protect` or TPRO unlock to make it writable
  - Replace the address with one we have control of
- Put the original `dyld4::APIs::_NSGetExecutablePath` back

> Old Method
>- Call `_NSGetExecutablePath` with an invalid buffer pointer input -> SIGSEGV
>- Do some [magic stuff](https://github.com/khanhduytran0/LiveContainer/blob/5ef1e6a/main.m#L74-L115) to overwrite the contents of executable_path.

### Patching `NSBundle.mainBundle`
- This property is overwritten with the guest app's bundle.

### Bypassing Library Validation
- JIT is optional to bypass codesigning. In JIT-less mode, all executables are signed so this does not apply.
- Derived from [Restoring Dyld Memory Loading](https://blog.xpnsec.com/restoring-dyld-memory-loading)

### dlopening the executable
- Call `dlopen` with the guest app's executable
- TweakLoader loads all tweaks in the selected folder
- Find the entry point
- Jump to the entry point
- The guest app's entry point calls `UIApplicationMain` and start up like any other iOS apps.

### Multi-Account support & Keychain Semi-Separation
[128 keychain access groups](./entitlements.xml) are created and LiveContainer allocates them randomly to each container of the same app. So you can create 128 container with different keychain access groups.

## Limitations
- Entitlements from the guest app are not applied to the host app. This isn't a big deal since sideloaded apps requires only basic entitlements.
- App Permissions are globally applied.
- Guest app containers are not sandboxed. This means one guest app can access other guest apps' data.
- App extensions aren't supported. they cannot be registered because: LiveContainer is sandboxed, SpringBoard doesn't know what apps are installed in LiveContainer, and they take up App ID.
- Multitasking can be achieved by using multiple LiveContainer and the multitasking feature. However, while we were able to fix physical keyboard input issue on iPadOS (https://github.com/LiveContainer/LiveContainer/issues/524), iPhone Mirroring uses different checks which still broke it (https://github.com/LiveContainer/LiveContainer/issues/793).
- Remote push notification will not work
- Querying custom URL schemes might not work(?)

## TODO
- Use ChOma instead of custom MachO parser

## License
[GNU Affero General Public License v3.0](https://github.com/LiveContainer/LiveContainer/blob/main/LICENSE)

## Credits
- [xpn's blogpost: Restoring Dyld Memory Loading](https://blog.xpnsec.com/restoring-dyld-memory-loading)
- [LinusHenze's CFastFind](https://github.com/pinauten/PatchfinderUtils/blob/master/Sources/CFastFind/CFastFind.c): [MIT license](https://github.com/pinauten/PatchfinderUtils/blob/master/LICENSE)
- [litehook](https://github.com/opa334/litehook): [MIT license](https://github.com/opa334/litehook/blob/main/LICENSE)
- @haxi0 & @m1337v for icon
- @Vishram1123 for the initial shortcut implementation.
- @hugeBlack for SwiftUI contribution
- @Staubgeborener for automatic AltStore/SideStore source updater
- @fkunn1326 for improved app hiding
- @slds1 for dynamic color feature
- @Vishram1123 for iOS 26+ JIT Script Support
- @StephenDev0 for AltStore source support

---

## 相比官方版本的改动列表 (Changes compared to Upstream)

本项目基于官方最新主线（commit `b7cfda6`）进行 rebase 与功能增强，主要改动如下：

### 1. 后台无感保活全面升级 (iOS 26+ Native Background Keep-Alive & Robust Fallback)
- **全新 iOS 26+ API 适配**：引入 Apple iOS 26+ 规范的 `BGContinuedProcessingTask` 后台任务架构，替代旧版保活方案，解决高版本 iOS 系统中后台任务易被系统挂起（Freeze）或超时终止（Watchdog Kill）的问题。
- **前台预注册与心跳维护 (Foreground Pre-arming & Heartbeat)**：
  - 应用在前台活跃状态下自动预申请 Continued Processing Task，彻底解决切入后台时申请被 `dasd`（Duet Activity Scheduler）直接拒绝的系统限制。
  - 维持 2 秒单调递增的 `NSProgress` 进展心跳，持续满足 iOS 26 对后台任务 30 秒内必须有进度汇报的系统安全策略。
- **SideStore 侧载重签名深度兼容**：
  - 针对 SideStore 侧载时自动在 Bundle ID 后追加 Team ID / 随机后缀、而未同步更新 `BGTaskSchedulerPermittedIdentifiers` 导致系统静默拒绝注册后台任务的痛点，动态拦截并放行 `_BGTaskIdentifierRegistry -isPermissibleFullyComposedIdentifier:`。
  - 运行时允许匹配宿主真实 Bundle ID，免去手动修改 entitlements 或申请特权 entitlement 的繁琐要求。
- **无感降级容灾兜底机制 (Fail-safe Audio & Background Task)**：
  - 当系统策略拒绝分配 Continued Processing 配额、或在应用进入后台的瞬间，自动无缝启动超低功耗静音 `AVAudioEngine` 混音节点与自循环 `UIBackgroundTask` 续约机制，保障保活 100% 成功。
- **实时诊断与可视化状态卡片**：
  - 在「设置 (Settings)」界面新增「后台保活状态 (Keep-Alive Status)」诊断条目，实时显示保活工作模式（如 `Continued Processing`、`Silent Audio (Fallback)`、`Paused` 等）及上次更新时间。
- **主程序后台保活联动 (Host App Keep-Alive Toggle)**：
  - 在设置中提供开关，允许 LiveContainer 主程序在切入后台时持续保活，为外部 HTTP API 脚本交互提供全天候不间断响应。

### 2. 内置免越狱 HTTP API 服务与子应用全生命周期穿透
- **原生高性能轻量 HTTP/1.1 API**：
  - 基于 Apple 原生 `Network.framework` 实现，零第三方库依赖，极低系统开销。
  - 支持配置端口（默认 8080）、本地回环绑定（Loopback Only 保护）、64 位 Hex 随机 Token 鉴权。
  - 开放远程安装 IPA、卸载应用、列出已安装应用状态、沙箱文件白名单读写与设备诊断接口，便于脚本或 CI 自动化集成。详情见 [HTTP-API.md](docs/HTTP-API.md) 与 Python SDK [lcapi.py](docs/lcapi.py)。
- **子应用 (Guest App) 启动后 HTTP 端点无缝保持**：
  - 官方版本启动容器内 App 后，主程序界面挂起导致 HTTP 端口立即断开。
  - 本分支实现 `TweakLoader/HTTPServerHook.m` 动态注入机制与沙箱隔离穿透：通过 `NSUserDefaults.lcMainBundle` 与 `CFPrefsPlistSource2` 机制安全读取宿主 App Group 存储，在 Guest App 启动时无感拉起并在子进程内部维持 HTTP 服务，使得调用方可以无缝管理运行中的应用与沙箱。

### 3. 源刷新逻辑与性能优化 (AltStore / SideStore Sources)
- **惰性加载与防覆盖机制**：
  - 优化 `LCAltStoreSourcesView.swift`，使用惰性加载替代原本每次进入源页面时的全量强制自动刷新，大幅降低网络开销与卡顿。
  - 防止自动刷新意外覆盖或重置用户自定义添加的应用源配置。

### 4. 应用列表文件夹分类管理 (UI Folders)
- **界面文件夹支持**：
  - 支持在应用列表中新建文件夹、重命名、置顶、删除，支持长按将应用移入/移出文件夹。
  - 独立持久化存储于 `Documents/LCUIFolders.json`，与官方版数据库完全隔离，升级官方版本不会损坏数据，重新安装本分支自动恢复分类。
  - 适配全局搜索栏，支持同时检索根目录与所有文件夹内的应用。

### 5. 游戏手柄与游戏模式增强 (Game Controller & Game Mode)
- **游戏模式与交互优化**：
  - 新增 `GCSupportsGameMode` 支持，优化手柄焦点与搜索框交互逻辑，避免在手柄导航时误弹软键盘。
  - 修复 `NSMutableArray` 桥接与 UIAction 调用问题，优化大图 Banner 渲染与布局重绘性能。

