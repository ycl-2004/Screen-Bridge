# ScreenBridge 大改动复审：已知问题与本次风险接受

日期：2026-08-15

审查基线：`main` / `adfdd5f3d9104b300c675c77936360adc6d3f33a`

状态：本文件保留当时的风险接受记录；下面 K1–K5 的“未修复”描述是该次提交时的历史快照。其后修复状态见紧接着的更新，不应再把全部五项视为开放。

## 后续修复更新（2026-08-15）

- **K1 已修复**：Reset Pairing 现在停止 listener、取消 active/pending 主连接与音频连接、清空 session/framing/decoder/audio/watchdog 状态，并回到 `pairingRequired` UI。
- **K2 已修复**：连接一经接受即在 `networkQueue` 上原子占位；timeout、失败、取消和握手完成都通过同一个字典恰好释放一次。
- **K3 按产品边界接受**：项目所有者明确选择自用 6 位配对体验；PAKE、离线枚举防护和 hostile-LAN hardening 不在本轮范围。仅在可信局域网使用。
- **K4 已修复**：链路分类改为连接时的明确 route intent 加 `NWPath.usesInterfaceType`；不再读取 `availableInterfaces.first`。无法证明 P2P 时落入保守 infrastructure 档；所有 TCP 路径均有界背压并动态调码率。
- **K5 仍开放**：公开分发前仍需项目所有者或合资格律师确认上游权利与当前 MIT 声明的兼容证据。

本轮新增验证包括 protocol v2 role/session/capabilities、媒体分层存活、session admission、设置更新决策、自适应码率策略测试，以及无 warning 的 Mac Swift build 和 iPad-only scene-based iOS Simulator build。真机音视频/AWDL/有线、Developer ID 公证和导出 IPA 安装仍需物理设备与签名账号验证。

## 本次改动摘要

- 新增共享流协议边界校验、AVCC 解析器和协议测试。
- 加固配对码输入、Keychain 更新、握手 timeout、EOF 与截断帧处理。
- 改善 encoder / decoder / ScreenCaptureKit 生命周期、画质和断线恢复。
- 持久化 Mac 设置，补充破坏性操作确认和配对反馈。
- 改善 iPad onboarding、键盘避让、Reduce Motion、触控尺寸和状态 UI。
- 补齐 Mac 本地网络权限声明与 iOS arm64 capability。

## 已知问题（未修复）

### K1 — iPad Reset Pairing 不撤销当前会话

`Sources/BetterCastReceiverIOS/ViewController.swift:652-684` 的操作只删除 Keychain secret，没有取消 `NetworkListenerIOS` 中的已认证连接或清除 session key。确认文案称 iPad 会停止接受连接，但当前串流可继续到连接自然结束。

后续应让 reset pairing 同时取消全部 active/pending connections、清理 decoder/audio/session state，并用集成测试验证现有会话立即失效。

### K2 — pending handshake 上限可被并发绕过

`Sources/BetterCastReceiverIOS/NetworkListenerIOS.swift:291-305` 在连接进入 `.ready` 之前检查 `pendingHandshakes`，但进入 `.ready` 后才增加计数。多个并发连接可以在计数尚未增加时一起通过检查。

后续应在接受连接时原子占用名额，或使用 `NWListener` 的入站连接限制，并覆盖并发 arrival、timeout、failure、cancel 的计数回收测试。

### K3 — 手动 6 位数字配对码可被离线枚举

`Sources/BetterCastShared/PairingAuthenticator.swift:78-110` 最低接受 6 个字符；`PairingSecretStrengthTests.swift:37-40` 明确接受六位数字。接收端在验证 sender proof 前返回由 secret 和双方 nonce 计算的 receiver proof，因此该 transcript 可以校验候选 secret，六位数字只有 1,000,000 种组合。

默认生成的 12 字符随机码远强于六位数字。后续应提高人工输入门槛、优先强制生成码，或改用抗离线猜测的 PAKE 设计。

### K4 — 网络接口分类仍是启发式判断

`Sources/BetterCastSender/BetterCastSenderApp.swift:3545-3565` 和 `:3974-3994` 把 `availableInterfaces.first` 当作实际选中接口。该列表是可用接口的偏好顺序，不保证第一项就是实际承载流量的接口；错误分类会影响 P2P、router、wired 档位和 backpressure。

后续应使用可证明的 path/interface 信号，无法确认时采用保守档位并记录可观测 telemetry。

### K5 — 公开仓库许可证状态仍需项目所有者确认

`docs/audits/2026-07-27-full-code-health-audit.md` 的 LIC-01 记录了代码来源上游 GPLv3 与本仓 MIT 声明之间的条件性冲突。若没有覆盖相关权利人的书面重许可，应由项目所有者或合资格律师确认公开分发方式。

## 本次验证

- `swift test --filter BetterCastSharedTests`：44/44 通过，0 failure。
- 独立 scratch `swift build`：成功；仍有 7 个唯一弃用 warning。
- iOS simulator Debug `xcodebuild`：`BUILD SUCCEEDED`。
- `plutil -lint`：两个修改过的 plist 均通过。
- `git diff --check`：通过。
- 真机 Mac → iPad E2E、网络故障注入、并发握手攻击、Developer ID / notarization 和真机 IPA 安装未在本次复审中验证。

## 本次决定

项目所有者在阅读复审结论后明确要求：保留并记住上述问题，提交并推送当前改动。后续任务应把 K1–K5 视为开放问题，除非有新的代码、测试或授权证据将其关闭。
