# YC Cast 全量代码健康审计

日期：2026-07-27

审计基线：`main` / `adfdd5f3d9104b300c675c77936360adc6d3f33a`

当前主产品：macOS Sender + iPadOS Receiver

审计性质：诊断与验证，不包含产品代码修复

## 结论

YC Cast 的核心并不是占位实现：

- Swift 包和当前 Mac targets 可以构建。
- 共享认证测试 9/9 通过。
- iPad App 已通过 Xcode 在 iPad 模拟器实际构建、安装和启动，并目视确认 onboarding / pairing UI。
- 项目真实 `KeychainPairingSecretStore` 已在 macOS 通过四个独立进程的保存、读取、替换、删除测试。
- Android Debug / Release 也能构建。

但当前版本还不能称为“全部稳定、可公开发布”。没有发现已经证实的运行时 P0，但存在一个条件性许可证发布阻断、多组主路径 P1 / 条件性发布缺口，以及大量尚未覆盖的故障场景。最危险的技术问题集中在：

1. iOS IPA 脚本产物确定缺 framework、资源、签名和 provision。
2. Sender / Receiver 的连接、编码、watchdog 状态没有单一并发所有者。
3. `VideoEncoder` 的异步回调生命周期不完整，断线或切分辨率时存在悬空 `self` 风险。
4. 已认证媒体帧无长度上限，且零长度 NAL 可以触发 iOS 越界崩溃。
5. clean EOF、握手超时、音视频双连接身份和分通道存活检测没有闭合。
6. 大部分用户设置没有持久化。
7. 主产品没有 CI，也没有物理 Mac → iPad 的自动化或本次实机 E2E 证据。

## 严重度

- **C0（条件性发布阻断）**：条件成立时必须暂停对外分发。
- **P1**：发布前应修；可能造成崩溃、不可安装、核心链路失效、安全暴露或长期卡死。
- **P2**：应进入近期稳定性迭代；会造成设置丢失、错误状态、恢复不完整或明显体验问题。
- **P3**：维护性、文档、未来兼容或当前非主路径问题。

## 已执行验证

| 验证 | 结果 | 能证明什么 | 不能证明什么 |
| --- | --- | --- | --- |
| `git status --short --branch` | 审计开始时 `main...origin/main`，业务工作树干净 | 审计基线明确 | 不代表远端发布资产可用 |
| `swift build` | 通过 | SwiftPM 当前 targets 可编译 | SwiftPM 的 iOS 条件编译不是完整 iOS App 验证 |
| 严格并发全新 scratch build | 构建通过，但出现大量 Swift 6 error 级 warning | 并发迁移缺口真实存在 | 每条 warning 都不等于独立运行时 bug |
| `swift test --filter BetterCastSharedTests` | 9/9，0 failure | HMAC、proof、session key、envelope 行为通过 | 唯一 store 测试使用 fake store，不覆盖系统 Keychain |
| Xcode iPad simulator build / install / launch | 通过 | 完整 Xcode target、assets、framework、启动路径存在 | 不证明真机签名、AWDL、ScreenCapture 或音视频 |
| 项目真实 Keychain class，四个独立 macOS 进程 | `SAVE_OK / LOAD_OK / REPLACE_OK / DELETE_OK` | macOS Keychain 数据可跨进程持久化 | 未在真实 iPad 上做 kill/relaunch 生命周期验证 |
| 临时运行 `package_ios_ipa.sh` | 脚本 exit 0，但 IPA 结构不完整 | IPA 脚本确实会产出不可依赖的 bundle | 未尝试把坏包安装到真机，静态证据已足以判定缺依赖 |
| 现有 `YC Cast.app` / DMG | app `codesign --verify` 通过；DMG checksum 有效；Gatekeeper `rejected` | 本地 artifact 未损坏、是 ad-hoc app | 不能作为免绕过的公开下载版本 |
| Android Debug / Release + lint | 两种构建通过；lint 0 error / 27 warning | Android 源码当前可编译 | tests 为 `NO-SOURCE`；Release APK 未签名 |
| shell / plist / asset JSON 静态检查 | 语法或格式通过 | 配置文件没有基础格式错误 | 不证明运行时权限和发布签名 |
| 凭据模式扫描 | 当前文件和 Git 历史未发现密码、私钥或证书 | 没有观察到已提交的常见明文凭据 | 不是完整 secret-management 审计 |

## C0：许可证状态必须先确认

### LIC-01 — GPLv3 上游代码被整体标成 MIT

已观察事实：

- 首个提交 `234465e138ad610e892700414683faa1400188cf` 的 `LICENSE` 是完整 GPLv3。
- `fea17f0224904e7d5fb60db050d07bdc0ee2dbc2` 将 GPL 文件替换为当前 MIT。
- 当前仓库仍有文件与 `StephenLovino/BetterCast` 上游逐字节相同，例如：
  - `Sources/BetterCastReceiverDesktop/installer.nsi`
  - `Sources/BetterCastReceiverDesktop/MainWindow.cpp`
  - `Sources/BetterCastSender/VirtualDisplay/VirtualDisplay.m`
- `installer.nsi:11` 与 `MainWindow.cpp:1471` 仍直接引用上游仓库。
- [上游仓库](https://github.com/StephenLovino/BetterCast) 和其 [LICENSE](https://raw.githubusercontent.com/StephenLovino/BetterCast/main/LICENSE) 明示 GPL-3.0。

条件性判断（不是法律意见）：

如果团队没有覆盖相关上游权利人和贡献者的书面重许可，那么把包含这些代码的仓库和二进制整体按 MIT 对外分发存在明确许可证冲突，应暂停公开发版。版权方可以另行授权，所以仓库外确有完整授权时，此阻断可以解除。

建议：

1. 先确认并保存完整的书面重许可或所有权链。
2. 如果没有，恢复适用的 GPL-3.0、署名与 notices，并按 GPL 要求提供对应源码。
3. 建立第三方代码 / 许可证清单；具体派生范围和既往分发补救交由合资格律师确认。

## 主路径 P1 / 条件性发布缺口

### APP-01 — IPA 脚本生成的包不可作为安装产物

证据：

- `package_ios_ipa.sh:31-46` 从裸 executable、源 `Info.plist` 和 loose icon 重建 app。
- `package_ios_ipa.sh:48-60` 手工复制部分 Swift dylib，`:63-67` 直接 zip。
- 临时实跑后的 IPA 只有 executable、源 plist、icon 和空 / 部分 Frameworks 内容。
- 缺少 `BetterCastShared.framework`、`embedded.mobileprovision`、`_CodeSignature/CodeResources`、`Assets.car`、编译后的 `LaunchScreen.storyboardc` 和 `PkgInfo`。
- 可执行文件的第一项动态依赖仍是 `@rpath/BetterCastShared.framework/BetterCastShared`。
- Xcode 真实 `.app` 包含上述全部 framework、资源和签名结构。
- `CLAUDE.md:126-141` 示例先构建 Debug，再直接运行脚本；脚本默认却读取 `Release-iphoneos`，文档与实现也不一致。

影响：脚本会成功打印“可安装”，但生成的 IPA 无法可靠安装或启动。

建议：删除手工拼 bundle 的路径，使用 `xcodebuild archive` + `xcodebuild -exportArchive` 或 Xcode Organizer 导出完整签名 IPA，并对产物执行 `codesign --verify --deep --strict`、依赖检查和真机安装 smoke test。

### APP-02 — Sender 连接 / pipeline 状态存在真实数据竞争

证据：

- `NetworkClient` 未做 actor 或队列隔离：`BetterCastSenderApp.swift:2435`。
- `ScreenRecorder.swift:84-88,117-132` 在 global queues 投递 SCStream callbacks。
- `VideoEncoder.swift:40-45,217` 从 VideoToolbox callback 直接进入 delegate。
- `BetterCastSenderApp.swift:4580-4703` 在 callback 路径读写 `pipelines`、`sendInProgress`、`bytesSentWindow`、frame counters；主线程会在 `3869-3890,3992-4028,4298-4309` 同时替换或销毁 pipeline。
- 严格并发构建在 `BetterCastSenderApp.swift:4156,4521-4522,4693`、`ScreenRecorder.swift:107` 等位置给出 Swift 6 error 级 data-race / sending warning。

触发：断开、Apply Settings、屏幕尺寸变化与编码 callback 重叠。

影响：dictionary race、释放后继续发送、背压状态漂移和偶发崩溃。

建议：给全部连接和 pipeline 状态一个单一所有者。可选方案是 `@MainActor NetworkClient`，把媒体 callback 转成不可变事件后 hop 回 actor；或使用专用串行 actor / queue。不要混合“多数 main、少数 callback 直接写”。

### APP-03 — iOS Receiver 也缺少单一并发所有者

证据：

- `connectedClients`、session keys、`lastDataReceived` 位于 `NetworkListenerIOS.swift:30-31,57`。
- network queue 在 `276-327` 修改，main Timer 在 `626-697` 读取 / 修改，`sendInputEvent` 又在 `712-735` 访问。
- `InputEvent.swift:25-35` 使用无同步的全局可变 `nextId`。
- strict concurrency 在 listener、delegate 和 ViewController 隔离边界给出多组诊断。

触发：连接取消、watchdog、heartbeat 和前后台切换同时发生。

影响：数组 / 字典 race、错误断线状态、sequence 或 session key 错配。

建议：让一个 receiver-session actor 持有 clients、keys、sequence、liveness 和 connection format；Timer 和 decoder callback 只发送事件。

### APP-04 — VideoEncoder teardown 可留下悬空 callback

证据：

- `VideoEncoder.swift:32-47` 用 `Unmanaged.passUnretained(self)` 注册异步 VT callback。
- `VideoEncoder.swift:110-118` 异步提交帧；文件到 `:249` 结束，没有 `completeFrames`、`VTCompressionSessionInvalidate` 或 `deinit`。
- pipeline 会在 `BetterCastSenderApp.swift:3869-3890,3992-4028,4298-4309` 直接替换 / 释放 encoder。
- `ScreenRecorder.stopCapture()` 在 `ScreenRecorder.swift:105-111` 启动一个不等待的 Task；而 `self.stream` 直到 `:91-92` start 成功后才赋值。

触发：编码在途时断开、切分辨率、快速 stop/start，或 start 尚未完成时 stop。

影响：VT callback 对已释放对象执行 `takeUnretainedValue()`，可能 `EXC_BAD_ACCESS`；也可能留下 orphaned capture/session。

建议：实现可等待、幂等的 teardown 顺序：停止接收新 sample → await capture stop → complete pending frames → [invalidate compression session](https://developer.apple.com/documentation/videotoolbox/vtcompressionsessioninvalidate%28_%3A%29?language=objc) → 清 delegate / 引用。

### APP-05 — 已认证流无 frame 上限；零 NAL 可崩溃

证据：

- Sender control receive：`BetterCastSenderApp.swift:4150-4153`。
- Sender auxiliary receive：`BetterCastSenderApp.swift:4247-4249`。
- iOS media receive：`NetworkListenerIOS.swift:499-502`。
- 上述路径把任意 `UInt32` 直接作为 body receive 长度；握手路径反而已有 64 KiB 上限：Sender `2786-2791`、iOS `381-386`。
- `VideoDecoder.swift:55-62` 在 `naluLen == 0` 时仍访问 `videoData[offset + 4]`。

影响：异常或恶意认证对端可请求约 4 GiB receive，导致挂起 / 内存压力；四字节零 NAL 可触发 bounds trap。

建议：

- 对 control、audio、video 分别设置协议硬上限。
- 拒绝 `bodyLength <= 0`、超过上限、partial body 和 arithmetic overflow。
- NAL 至少要求 `naluLen >= 1`，并对整个 AVCC 结构做完整消费检查。
- 为边界值、截断、零 NAL、超大 frame 加 fuzz / property tests。

### APP-06 — clean EOF 和握手超时没有闭合

证据：

- Sender header callback 收到 `isComplete`：`BetterCastSenderApp.swift:4132`，nil body 分支却在 `4212-4213` 继续递归 receive。
- body callback 的 error / `isComplete` 在 `4153` 被忽略，之后 `4210` 继续 receive。
- 连接 5 秒 timer 在 TCP `.ready` 立即取消：`3242-3286`；随后 `2831-2880,3310-3318` 的 HMAC handshake 没有 deadline。
- iOS 新连接和 handshake：`NetworkListenerIOS.swift:276-318,426-485`，也没有超时和 pending connection 上限。

影响：clean close 可造成完成流上的重复 receive、UI / 虚拟显示残留至 heartbeat timeout；只 accept 不发 hello 的对端可让 Sender 永久 Authenticating，或让 iPad 累积半开连接。

建议：

- 把 `isComplete` 视为读方向关闭并立即走统一 teardown。
- body 必须精确收满，否则关闭连接。
- 给整个握手和每阶段 receive 设置 deadline、单次 completion guard、最大 pending 数和失败退避。

Apple 的 [`NWConnection.receive`](https://developer.apple.com/documentation/network/nwconnection/receive%28minimumincompletelength%3Amaximumlength%3Acompletion%3A%29?changes=_5) 明确通过 `isComplete` 表示 receive stream 已完成。

### APP-07 — 音视频连接没有 session role，聚合 watchdog 可漏报冻结

证据：

- Sender 为 audio 建第二条独立认证 TCP：`BetterCastSenderApp.swift:3024-3082`。
- iOS 每条认证连接都加入同一 `connectedClients`：`NetworkListenerIOS.swift:288-293`，共享同一个 decoder / renderer / audio player。
- iOS 只维护一个 `lastDataReceived`：`:57`，任何 body 在识别媒体类型前就更新：`:526-529`；watchdog 只检查这个聚合时间：`:681-697`。
- control message 会广播到全部 clients：`:709-735`。
- `NetworkClient.disconnect()` 在 `BetterCastSenderApp.swift:4050-4064` 不取消 `audioConnection`，而单连接 remove 路径会取消：`:3992-4028`。

触发：audio 仍活但 video 卡死、主连接断开但辅助连接留存、第二个 Sender 接入。

影响：画面可能冻结但 watchdog 永不触发；receiver 仍显示 connected；不同连接的媒体和 control 可混流。

建议：握手后增加 session ID、connection role（video/control 或 audio）、唯一 active sender 规则；按 role 记录 liveness；主连接结束时原子取消整个 session。

### APP-08 — macOS 15+ 本地网络声明缺失

证据：

- Sender 使用 Bonjour `NWBrowser`：`BetterCastSenderApp.swift:2439,2585-2635`。
- 服务类型是 `_yc-cast._tcp`：`PrivateBetterCastConstants.swift:5`。
- `BetterCastSender-Info.plist:5-35` 缺少 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`；实建 app 的最终 plist 同样缺失。
- iOS plist 正确包含这两个 key：`Sources/BetterCastReceiverIOS/Info.plist:29-34`。

边界：macOS 14 不受 macOS Local Network Privacy 影响；Apple 在 macOS 15 引入该机制。本轮没有 fresh macOS user / 未授权状态的运行验证，所以这是高风险配置缺口，不是对当前机器的必现断言。

建议：添加用途文案和 `_yc-cast._tcp` 列表，并在 fresh user 上验证 deny、allow、再次授权和浏览重试。Apple [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) 也建议 macOS 程序使用 Apple-issued identity，以便本地网络授权稳定跟踪其身份。

### APP-09 — 主产品没有当前 CI / 回归门

证据：

- `.github/workflows/` 只有 Linux 和 Windows receiver。
- 两个 workflow 只监听 desktop 路径的 `push` 和 manual，没有 `pull_request`。
- Mac、iOS、shared auth、IPA structure 均不在 CI。
- 当前自动测试只有 `Tests/BetterCastSharedTests` 的 9 个用例；没有 Xcode test target。

影响：`main` 可以在没有 Apple 构建、测试或协议边界验证的情况下回归。

建议：至少建立：

1. macOS：Swift build、9 个共享测试、strict-concurrency warning budget。
2. iOS simulator：Xcode build + launch smoke。
3. protocol：framing bounds、EOF、timeout、replay、session role、decoder malformed input。
4. artifact：archive/export、bundle contents、codesign、Mach-O dependency。
5. PR 必跑，并为主分支配置 required checks。

### APP-10 — 当前 Mac 分发产物仅适合本机测试

证据：

- 根目录 `YC Cast.app` 的 deep / strict codesign 验证通过。
- 签名是 `adhoc,runtime`，无 TeamIdentifier。
- DMG checksum 有效。
- `spctl -a -vv -t exec 'YC Cast.app'` 在沙箱外实测结果为 `rejected`。
- README 已说明 ad-hoc 是本地 / trusted friends 模式，这一点不是文档欺骗。

影响：现有 app / DMG 不是免绕过的公开下载版本；ad-hoc 重建也会让 macOS 15+ 本地网络权限身份更不稳定。

建议：公开分发时使用 Developer ID Application、notarization、stapling、Gatekeeper 验证和 clean-machine 安装测试。私用构建则明确保留“非公开发布”标签。

### APP-11 — App Store / TestFlight 路线缺 privacy manifest

仓库中没有 `PrivacyInfo.xcprivacy`，但 iOS App 和 shared framework 使用 `UserDefaults`。Apple 把 `UserDefaults` 列为 required-reason API，并要求 App Store Connect 提交声明实际使用理由；当前仅在 Xcode / 私人签名设备安装时，这不是运行阻断。

影响边界：如果 iPad Receiver 要上 TestFlight 或 App Store，这是提交前阻断；如果始终只通过 Xcode 私装，则是无关渠道的条件性要求。

建议：在 App 和实际使用该 API 的动态 framework bundle 中加入合法 privacy manifest，按“只读写本 App 数据”的实际用途选择批准理由，并在 App Store Connect 做真实上传验证。参考 Apple 的 [required-reason API 说明](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) 与 [`UserDefaults` category](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)。

### APP-12 — 第三方来源与许可证交付没有清单

当前只有根 `LICENSE`，但 `VirtualDisplay.m:3-13` 自带 Apache-2.0 声明；desktop 发行还会捆绑 Qt、FFmpeg / x264、ADB 和 VDD。仓库没有 `THIRD_PARTY_NOTICES`、SBOM、依赖许可证副本或对应源码交付说明。

这不会单独证明每一项都违规，但在 LIC-01 已存在的前提下，说明当前没有可审计的许可证交付链。尤其 FFmpeg + x264 的构建 / 分发选项需要按实际链接配置单独核查。

建议：生成平台级 SBOM 和 notices，记录来源 commit、license、修改、链接方式、binary redistribution 条件和对应源码位置；release CI 校验清单与产物一致。

## 保存与恢复的真实状态

| 数据 | 当前状态 | 证据 / 结论 |
| --- | --- | --- |
| Mac pairing secret | **已实测可保存** | 项目真实 Keychain class 跨四个独立进程完成 save/load/replace/delete |
| iPad pairing secret | **有真实实现，未做真机生命周期实测** | 与 Mac 共用 `KeychainPairingSecretStore`；Xcode App 已编译启动 |
| onboarding / tour | **保存** | `@AppStorage`：`BetterCastSenderApp.swift:12-13,1051` |
| display placement | **保存** | UserDefaults：`:2503-2506,2674-2675` |
| hidden devices | **保存** | UserDefaults：`:2538-2540,2676` |
| iPad custom device name | **保存** | `ViewController.swift:219-220,598-602` |
| Extended / Mirror | **不保存** | plain `@Published`：`BetterCastSenderApp.swift:2461` |
| audio enabled | **不保存** | `:2462-2467` |
| resolution / Retina | **不保存** | `:2501-2502` |
| stream quality | **不保存** | `:2520` |
| network mode | **不保存** | `:2523` |
| auto-connect | **不保存** | `:2526` |
| manual host / port | **不保存** | `:2528-2530`；如果是临时连接输入，可保留 session-only，但应明确 |
| iPad Fit / Fill | **不保存** | `ViewController.swift:785-792` |
| brightness | **写入真实显示亮度** | 不是偏好存储；setter 调用 hardware control |

### 保存相关 P2

#### SAVE-01 — 大部分用户偏好重启后静默回默认

建议：建立版本化、可校验的 settings model，使用 `UserDefaults` / `@AppStorage` 持久化上述用户选择；启动时对枚举和分辨率做 fallback。连接中应用设置时先完成原子 pipeline reconfiguration，再提交新偏好。

#### SAVE-02 — Keychain 替换不是原子更新

`PairingSecretStore.swift:40-50` 先 delete 再 add。如果 add 失败，旧 secret 已丢失。应先 `SecItemUpdate`，仅 `errSecItemNotFound` 时 add。系统 [SecItemUpdate](https://developer.apple.com/documentation/security/secitemupdate%28_%3A_%3A%29?changes=_5) 是更合适的更新路径。

#### SAVE-03 — Clear Pairing 不撤销当前 session

Mac `BetterCastSenderApp.swift:2735-2742` 和 iPad `ViewController.swift:586-595` 只删除 Keychain；已建立的 session key 和连接继续工作。UI 上“Clear”容易被理解为立即撤销。

建议：明确产品语义。更安全的默认是删除 secret 后断开全部现有 session、清 session keys，并停止 / 重启 receiver listener。

#### SAVE-04 — pairing 输入可以退化成可预测空 secret

UI 只检查 trim 后非空；`PairingAuthenticator.swift:78-85` 又删除全部空白和 `-`。例如 `"-"` / `"---"` 会通过 UI，但最终成为 `SHA256(empty)`。短数字 pairing code 也容易被捕获握手后离线猜测。

建议：在 normalization 后验证最小长度 / 熵，拒绝空结果；默认生成较长随机码。若威胁模型扩展到不可信 LAN，考虑 PAKE 或经 KDF 强化的设计，而不是单纯 SHA-256 用户输入。

## 其他主路径 P2 / P3

### STAB-01 — Force Router 与路径分类不可靠

- `BetterCastSenderApp.swift:3098-3099` 先固定 `includePeerToPeer = true`；router 分支 `3141-3145` 没有改回 false。
- `3291-3307,3710-3726` 用 `currentPath.availableInterfaces` 中出现 `awdl` 来判断已走 P2P；“可用接口”不等于实际选中接口。
- 错判后会使用高 bitrate / 关闭 infrastructure backpressure：`4418-4465,4593-4604`。

建议：Router mode 明确 `includePeerToPeer = false`；路径判定只使用实际 path usage / endpoint metadata，不从 available list 猜测。

### STAB-02 — discovery 与 listener 恢复存在边界

- App `onAppear` 和多个路径会调用 `startBrowsing()`：`BetterCastSenderApp.swift:62-65,2516,2580,2681-2695`；方法本身未先 cancel 已有 browser，且 path monitor 从 global queue 触发。
- iOS `startPrivateP2P()` 构造 listener 直接抛错时只显示 waiting：`NetworkListenerIOS.swift:97-129`；state `.failed` 有 retry，但 constructor catch 没有。

建议：让 browsing start / stop 幂等并统一在状态 actor；所有 listener 创建失败走同一个带退避的 restart state machine。

### STAB-03 — ScreenRecorder 状态机不完整

- start 只在 capture 成功后赋 `self.stream`：`ScreenRecorder.swift:84-93`。
- stop 在 start 期间可能看到 nil，随后 capture 成功成为 orphan。
- fallback 仍找不到 display 时 `:68-71` 只 log / return，不通知 delegate。

建议：持有 cancellable start task，建立 `idle → starting → running → stopping` 状态机；所有出口都回报成功 / 失败并可等待结束。

### STAB-04 — Chrome audio 失败状态和资源不一致

`BetterCastSenderApp.swift:4470-4498` 先建立 encoder / auxiliary connection，再快照 Chrome 进程并启动 tap；失败只写 log，不关闭 toggle、清资源或重试。

建议：以实际 capture state 驱动 UI；Chrome 未运行、进程变化、tap 失败时回滚连接和 encoder，并提供明确重试。

### STAB-05 — iPad 空闲时也持续占用 audio session / 防休眠

- `AppDelegate.swift:12-18` 启动即激活 playback session，无对应 deactivate。
- `ViewController.swift:54-55` onboarding / waiting 状态也禁用 idle timer。
- `AudioPlayerIOS.stop()` 只停止 engine：`:204-213`。

建议：仅在前台已连接、实际播放时激活 audio session 和 idle timer；断线 / background 时撤销。

### STAB-06 — Decoder 重连和格式切换没有 reset 边界

- `VideoDecoder.swift:73-100` 每帧都走 format creation。
- `:102-118` 只在尺寸变化时重建；同尺寸 SPS/PPS 改变未检查 session 是否接受新 format。
- `NetworkListenerIOS.swift:321-338` remove connection 时不 reset decoder。

建议：按 session reset decoder；SPS/PPS 变化时使用 `VTDecompressionSessionCanAcceptFormatDescription` 决定复用或重建；避免每帧重复创建 format。

### STAB-07 — 私有 CGVirtualDisplay 是明确的产品约束

`VirtualDisplayManager.swift:5-7` 和 `Sources/BetterCastSender/VirtualDisplay/` 使用私有 CoreGraphics virtual display API。它可以支持当前私用路径，但：

- macOS 更新可能无兼容承诺地破坏核心功能。
- Apple App Review Guideline [2.5.1](https://developer.apple.com/app-store/review/guidelines/) 要求使用 public APIs，因此 Mac App Store 路线不可依赖当前实现。

这不是本次构建失败，但必须写进发布策略和 OS compatibility matrix。

### STAB-08 — 文档存在过度承诺或陈旧描述

- README `:23` 声称“never freezes”，但聚合 watchdog 可被 audio 活跃掩盖。
- Settings InfoTip `BetterCastSenderApp.swift:1237-1242` 声称单一 authenticated TCP stream；启用 audio 时实际有第二条 TCP。
- Router 文档承诺与 `includePeerToPeer` 实现不一致。
- `LogManager.swift:67-71` 的旧 changelog 说 receiver 要求全屏；README `:90-93` 则支持 multitasking。
- Xcode target family 是 iPhone + iPad：`project.pbxproj:385,409`，产品文档却只把 iPad 当当前范围。

建议：修复行为后把 README 改成可测、有限定词的承诺，并把 manual checklist 变成真实 release checklist。

### STAB-09 — 当前结构增加修复风险

`BetterCastSenderApp.swift` 约 4,700 行，同时承载 UI、discovery、authentication、connection lifecycle、media pipeline、settings 和 stats。它不是直接运行时 bug，但让状态所有权难以看清，也是并发问题反复出现的结构原因。

建议：按职责拆成 session actor、discovery service、settings store、media pipeline、views；先加 characterization tests，再拆，不做无测试的大爆炸重写。

### STAB-10 — 签名配置与构建追溯不够可移植

- Xcode project 在 `project.pbxproj:240,245,371,395,418,444` 硬编码个人 Team ID；其他贡献者需要手工改项目才能签名。
- `make_app.sh:71-77` 把 app-specific password 作为进程参数传给 notarytool；应使用 Keychain profile 或 API key，减少进程参数暴露。
- `make_app.sh` 不写入 source commit、工具链、artifact SHA256，也不归档 dSYM。
- `.gitignore` 确实忽略 IPA / DMG，但没有像 README `:135` 所称那样普遍忽略 zip / app。

建议：把 Team 作为本地 `.xcconfig` / CI secret；notarytool 使用 `store-credentials` profile；产物附 commit、Xcode / Swift 版本、checksums、dSYM 和签名 / notarization 日志。

## 历史 / 次级平台

README 和项目规则把 Android、Windows、Linux / desktop 视为 dormant / secondary。以下问题不阻断“只发布 Mac + iPad”的范围，但若 UI、文档或发行资产重新承诺这些平台，则全部转为 P1。

### LEG-01 — 与当前 `_yc-cast` + HMAC 协议不兼容

- Android 仍使用 `_bettercast._tcp/.udp`：`ServiceAdvertiser.kt:13-18`，连接后无 SenderHello / HMAC。
- Desktop 同样使用 `_bettercast._tcp`：`ServiceDiscovery.cpp`、`NetworkListener.cpp`，首个当前 SenderHello 会被当作媒体。
- Windows sender 也没有 pairing。
- Desktop type-byte path 去掉 type byte 后没有去掉 8-byte PTS：`NetworkListener.cpp:174-200` + `VideoDecoder.cpp:20-39`，即使补认证也会黑屏。

### LEG-02 — Android Sender 对任意 LAN client 暴露屏幕

`TcpSender.kt:58-129` 在 `0.0.0.0:51820` 接受任意 client，无认证即发送 MediaProjection 画面；新 client 还能踢掉原 client。

### LEG-03 — Android UDP 可损坏、劫持并无界增长

- `UdpClient.kt:67-89` 复用 `DatagramPacket` 后不恢复 buffer length，短尾包会让后续包截断。
- 任意 UDP 包在 header 校验前更新 sender address / connected state。
- `frameBuffers` 对持续不完整、唯一 frame IDs 没有可靠 TTL / 数量上限，可增长到 OOM。
- 没有 sender timeout，断网后可能永久 Connected / 保留末帧。

### LEG-04 — Android MediaProjection 和 decoder 生命周期不闭合

- `ScreenCaptureService.kt:55-60` 的 `MediaProjection.onStop` 没有停止 encoder / TcpSender，也没同步 ViewModel。
- `VideoDecoder.kt:46` 使用无容量 queue；surface、codec、stop / release 在不同线程且没有 join / 隔离。
- configure / start 失败会留下局部 decoder 未 release。

### LEG-05 — Windows 对 Public 网络开放且输入无认证

- `main.cpp:25-53` 添加 Public profile 防火墙规则。
- `NetworkListener.cpp:41-69,111-127` 监听 Any、无认证。
- `InputHandler.cpp:64-125` 捕获输入，`NetworkListener.cpp:353-378` 向全部 clients 广播。
- installer 卸载删除的 rule 名与 runtime 添加的名字不一致，规则会残留。

### LEG-06 — Desktop detached threads 和共享对象有 UAF / data race

`MainWindow.cpp:1099-1316` 多处 detached `[this]` thread；窗口 / helper 被销毁后线程仍可能访问。ADB reconnect 可重叠，LogManager / VDD logging 共享容器也无同步。

### LEG-07 — Windows VDD / capture 可能破坏配置或抓错屏

- GDI fallback 违反 `GetDIBits` 对 selected bitmap 的生命周期要求，并忽略返回值。
- `VirtualDisplayVDD` 析构会 remove all virtual displays，不只当前进程创建的。
- fallback settings 用 truncate 重写整个 XML，丢失未知 / 第三方字段，无 rollback。
- adapter index 映射错误时会静默回退主物理屏，形成隐私风险。

### LEG-08 — Desktop 没有媒体 backpressure / 主线程隔离

Windows sender 对每帧直接 `QTcpSocket::write`，不限制 queued bytes；receiver commands 也不读取。capture、颜色转换、encode、socket write 和接收 decode 大量发生在 GUI 线程，可能造成内存增长和 UI / heartbeat 卡死。

### LEG-09 — 次级平台没有可发布的测试与签名链

- Android Debug / Release build 成功，lint 0 error / 27 warning。
- Android unit test 与 instrumentation test 都是 `NO-SOURCE`。
- Release 只有 unsigned APK。
- Windows / Linux 本轮因缺 Qt / CMake toolchain 未本机构建。
- 现有 Actions 只覆盖 desktop，依赖下载缺少充分 pin / checksum；Windows 还安装 driver，供应链风险较高。
- 2026 发布 Android 时还需要复核当前 Google Play target SDK 要求，现有 `targetSdk = 34` 已不是长期可发布配置。

### LEG-10 — Desktop release workflow 存在供应链与卸载残留风险

- Windows workflow 下载 `platform-tools-latest`、VDD 和第三方 NSIS 后直接打包 / 执行，没有完整 checksum / 签名验证；installer 以管理员权限安装 driver。
- Linux workflow 从 `continuous` 下载并执行 linuxdeploy。
- Actions 只 pin 到 floating major tag，而不是 commit SHA。
- Windows 安装可使用 `MttVDD.inf` 或任意 `*.inf`：`installer.nsi:111-145`；卸载却只查 `VirtualDisplayDriver.inf`：`:192-196`，driver 很可能残留。

建议：固定每个下载的版本、commit 和 SHA256，验证发行签名；Actions pin commit SHA；driver 安装时记录 published OEM INF 名，卸载按记录执行并验收。

建议只选一个方向：

1. **归档路线（推荐用于当前产品）**：从 products、release docs、CI 和主 README 移除这些平台，把源码放入明确的 `legacy/` 或历史分支。
2. **恢复路线**：先写 versioned wire protocol 和跨语言 conformance tests，再统一 discovery、pairing、framing、timeouts、bounds、session roles；随后逐个平台修生命周期与发布链。

## 未验证与不能声称的内容

本轮没有以下证据，因此不得仅凭“代码存在”宣称稳定：

- 真实 Mac → 真实 iPad 的持续视频串流。
- Screen Recording / Audio Recording 权限首次申请、拒绝后恢复。
- AWDL、Router、USB / Thunderbolt 各实际路径。
- Chrome audio 到 iPad 的真实播放。
- iPad kill / relaunch 后 Keychain 读取。
- background 5 分钟 grace、force quit、Wi-Fi 切换、Mac crash / power loss。
- 断线 / 重连期间反复切 resolution / audio 的 race 注入。
- Developer ID notarized Mac 安装。
- archive/export 后的真机 IPA 安装。
- Windows / Linux build 和 runtime。
- Android 真机 projection、旋转、断网和内存压力。

## 整改顺序

### 阶段 0：先解除发布阻断

1. 确认 GPL → MIT 重许可；未确认前暂停公开仓库 / 二进制发版。
2. 用 archive / export 重做 IPA；删除会产生假成功的手工脚本路径。
3. 补 Mac local-network plist，并建立 Developer ID / notarization 路径。

### 阶段 1：封住崩溃和挂死入口

1. media / control frame bounds、零 NAL、partial frame、overflow。
2. clean EOF、handshake deadline、pending connection cap。
3. `VideoEncoder` / `ScreenRecorder` 可等待的幂等 teardown。
4. 主连接断开时原子取消 auxiliary audio connection。

### 阶段 2：重建状态所有权

1. Sender session / pipeline actor。
2. Receiver session actor。
3. session ID + connection role + per-media liveness。
4. 幂等 discovery / listener state machine。
5. decoder reset 和 Chrome audio rollback。

### 阶段 3：让“可保存”完整成立

1. 持久化全部用户偏好并做版本 / 值校验。
2. Keychain 改成 update-or-add。
3. Clear Pairing 立即 revoke session。
4. normalization 后做 pairing code 强度验证。

### 阶段 4：把稳定性变成可持续证据

1. Apple PR CI 和 required checks。
2. framing / decoder fuzz tests。
3. scripted simulator smoke + physical-device release checklist。
4. 30–60 分钟 soak，反复 disconnect / reconnect / settings changes。
5. network fault injection：clean EOF、half-open、packet truncation、video-only / audio-only death。
6. 决定归档或正式恢复 Android / Desktop，避免“源码还在”被误认为“仍受支持”。

## 发布门

建议在以下全部满足前，不使用“稳定发布”：

- 许可证状态有可审计证据。
- IPA / Mac artifact 在 clean device 验证通过。
- 全部主路径 P1 有回归测试。
- strict-concurrency 的当前主路径 warning 被消除或有逐项有依据的隔离说明。
- 物理 Mac + iPad 完成连接、音视频、三种网络、前后台、异常断线和重连验收。
- CI 对每个 PR 执行 Apple build、tests 和 artifact checks。
