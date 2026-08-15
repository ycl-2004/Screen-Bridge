# YC Cast 复检：遗留问题、配置风险与 Apple 设计规范符合度

日期：2026-08-14

复检基线：`main` / `adfdd5f3d9104b300c675c77936360adc6d3f33a`（业务代码工作树干净）

本机环境：macOS 26.6.1 (25G76) / Xcode 26.6 (17F113) / Swift 6.3.3

性质：只读诊断。本轮未修改任何业务代码。

前置报告：`docs/audits/2026-07-27-full-code-health-audit.md`

---

## 0. 结论先行

三句话：

1. **上一轮审计（7/27）发现的问题，一个都还没修。** 最后一次代码提交是 6/12，晚于它的审计没有产生任何修复提交，工作树干净。所以那份报告里的 C0/P1/P2 全部原样有效。
2. **本轮新增的主要发现在"配置层"和"Apple 设计规范"两块**——这两块上一轮基本没覆盖。其中 3 条是会直接影响真机可用性的硬问题（iOS bundle 声明 `armv7`、Mac 缺本地网络权限声明、iPad 内容宽度约束被击穿）。
3. **"双端都好用"目前只能验证到"能编译、能装、能启动"这一层。** 真机 Mac → iPad 端到端串流、权限流、三种网络路径本轮仍未验证，原因是本机没有连接 iPad（只有一台 iPhone 15）。

---

## 1. 关于 upstream

你问的 upstream 名字，有两层，别混淆：

| 层级 | 地址 | 说明 |
| --- | --- | --- |
| 你的 Git 远端 | `https://github.com/ycl-2004/Mac_to_Ipad.git` | 是的，仓库名就叫 **Mac_to_Ipad**。分支 `main` 跟踪 `origin/main` |
| 代码来源上游 | `StephenLovino/BetterCast`（GPL-3.0） | 前一轮 LIC-01 认定的第三方来源，仍有文件与其逐字节相同 |

第二层是发布阻断项，状态未变，见 §5。

---

## 2. 本轮实际执行的验证

| 验证 | 结果 | 能证明什么 | 不能证明什么 |
| --- | --- | --- | --- |
| `git status --short` | 仅 `.fable/`、`docs/audits/` 未跟踪 | 6/12 之后无业务代码改动，旧问题未修 | — |
| `swift build` | 通过 | 当前 SwiftPM targets 可编译 | 不等于 App bundle 可发布 |
| `swift test --filter BetterCastSharedTests` | **9/9 通过，0 失败** | HMAC / proof / session key / envelope 行为正确 | store 测试仍用 fake，不覆盖系统 Keychain |
| 全新 scratch 严格并发构建 | 构建通过，**1166 条诊断，其中 16 条 error 级** | 并发所有权缺口真实且量大 | 每条诊断不等于一个独立运行时 bug |
| Xcode iPad Pro 13" (M4) 模拟器 build → install → launch | 通过 | 完整 target、资源、framework、启动路径可用 | 不证明真机签名、AWDL、ScreenCapture、音视频 |
| 已构建 bundle 的 `Info.plist` 实读 | 见 §3 | 声明缺陷会真实进入产物 | — |
| 模拟器截图（竖屏 / 横屏） | 见 §4-I1 | 首屏排版实际渲染结果 | 未覆盖已连接后的串流画面 |
| 对照实验：系统"设置"App 同状态截图 | 表现一致 | **推翻了"旋转导致布局错乱"的初判** | — |

### 严格并发诊断分布

```
总计 1166（16 error / 1150 warning）
  323  BetterCastSender/BetterCastSenderApp.swift
   68  BetterCastSender/ReceiverNetworkListener.swift
   62  BetterCastReceiver/BetterCastReceiverApp.swift
   49  BetterCastSender/ReceiverMode.swift
   ...
```

16 条 error 级全部集中在两处 `NWConnection` receive 回调：`BetterCastSenderApp.swift:4140` 和 `:4223`。这与上一轮 APP-02 / APP-06 指认的位置完全重合——是独立方法得到的同一结论。

当前 `Package.swift` 是 `swift-tools-version: 5.9`（Swift 5 语言模式），所以 1150 条仍是 warning。一旦升到 tools 6.0，它们会**全部变成编译错误**。

---

## 3. 新发现：配置层（上一轮未覆盖）

### CFG-01 — iOS bundle 声明 `UIRequiredDeviceCapabilities = armv7` 〔P1〕

证据（读取实际构建产物，非源码推断）：

```
$ /usr/libexec/PlistBuddy -c "Print :UIRequiredDeviceCapabilities" \
    Build/Debug-iphonesimulator/BetterCastReceiverIOS.app/Info.plist
Array {
    armv7
}
```

源头：`Sources/BetterCastReceiverIOS/Info.plist`。

`armv7` 是 32 位 ARM。现在所有 iPad 都是 arm64，且 App Store 对最低部署 iOS 11+ 的 App 会拒绝 `armv7` 声明。这是典型的模板残留，会造成设备兼容性判定异常和提交阻断。

建议：改为 `arm64`，或直接删除这个键（不声明即不限制）。

### CFG-02 — Mac 端仍缺本地网络权限声明，且现在必然生效 〔P1，从上轮升级〕

`BetterCastSender-Info.plist` 至今没有 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`。iOS 端两个键都齐全，Mac 端没有。

上一轮把这条标为"高风险配置缺口，不是对当前机器的必现断言"，理由是当时无法确认 macOS 版本影响。**现在本机是 macOS 26.6**，Local Network Privacy 自 macOS 15 引入，这条已经从假设变成确定生效的路径。

实际后果：Mac sender 用 `NWBrowser` 浏览 `_yc-cast._tcp` 时会触发系统本地网络授权。没有用途文案，系统弹窗只能显示通用说明；一旦用户误拒，App 内没有任何检测和引导恢复的 UI，表现就是"永远搜不到 iPad"。这很可能是日常使用中最容易撞上、又最难自查的故障。

建议：补上两个键，并在 fresh user 上验证 拒绝 → 允许 → 再次浏览 的完整恢复路径。

### CFG-03 — 缺 `UIApplicationSceneManifest`，与 README 的多任务声明冲突 〔P2〕

构建产物实读：`Print: Entry, ":UIApplicationSceneManifest", Does Not Exist`。

App 走的是 `UIApplicationDelegate` + `UIWindow(frame: UIScreen.main.bounds)` 的旧生命周期（`AppDelegate.swift:23`）。而 `README.md:90` 写着"The iPad receiver supports iPadOS multitasking and windowed presentation"。

需要说明的是：我在模拟器里横屏截图后一度判定"旋转导致整个 UI 错乱"，随后用系统"设置"App 做同状态对照，发现表现完全一致——那是 `simctl io screenshot` 返回原始竖屏 framebuffer 的成像方式，**不是 App 的 bug**。这条我已推翻，布局在旋转后是正常重排的。

但 scene manifest 的缺失本身仍然成立，它影响的是多窗口/Stage Manager 场景下的窗口语义，以及 `UIScreen.main` 系列 API 在窗口化时返回整块屏幕而非当前窗口的问题（`ViewController.swift:127,149`，`UIScreen.main` 自 iOS 16 起已废弃，共 3 处使用）。README 的措辞应当收敛到可验证范围。

### CFG-04 — 部署目标停在 iOS 13 〔P2〕

`Package.swift:10` 为 `.iOS(.v13)`，`project.pbxproj` 中 `IPHONEOS_DEPLOYMENT_TARGET = 13.0`，产物 `MinimumOSVersion = 13.0`。

代价是代码里散落着永远为真的 `if #available(iOS 11.0, *)` / `iOS 13.0` 分支（`ViewController.swift:137,378,633`，`AppDelegate` 等），维护噪音，且挡住了现代 API。iPad 作为 Mac 扩展屏的目标用户几乎不可能停留在 iOS 13。

建议：抬到 iOS 17 或 18，清掉死分支。

### CFG-05 — 强制锁定深色外观 〔P2 / HIG〕

`Info.plist` 中 `UIUserInterfaceStyle = Dark`，无视系统外观设置。

串流画面本身用深色底是合理的，但**整个 App**（含首次配对、设置面板）被一起锁死就是 HIG 偏离。配合 §4-I5 的全硬编码颜色，结果是浅色模式、增强对比度、各类辅助功能显示设置全部失效。

### CFG-06 — 其余配置项

| 项 | 现状 | 影响 |
| --- | --- | --- |
| `TARGETED_DEVICE_FAMILY = "1,2"` | 含 iPhone | 产品定位是 iPad-only，UI 未按 iPhone 设计（上轮 STAB-08 已提，未修） |
| `DEVELOPMENT_TEAM = BQYHJCCRMP` | 硬编码在 pbxproj 6 处 | 个人 Team ID 进入公开仓库；他人需改项目才能签名（上轮 STAB-10，未修） |
| `SWIFT_VERSION = 5.0` | 工具链是 6.3.3 | 语言模式滞后，掩盖并发问题 |
| `NSMicrophoneUsageDescription` | 文案写"system sound capture" | 实际走 `ProcessAudioTapCapture` 抓 Chrome 进程音频，不是麦克风；文案与能力不符 |
| `PrivacyInfo.xcprivacy` | 不存在 | 用了 `UserDefaults`（required-reason API），走 TestFlight/App Store 则为提交阻断（上轮 APP-11，未修） |
| 构建输出目录 | 自定义 `SYMROOT` 落在仓库内 `Build/` | `-derivedDataPath` 被忽略，产物写进工作树（当前被 `.gitignore` 覆盖，未污染） |

---

## 4. 新发现：Apple 设计规范符合度

先给三条全局性的、影响面最大的：

> **零个 `confirmationDialog` / `.alert` / `UIAlertController`。** 两端全仓库搜索结果为空。所有破坏性操作没有任何确认，所有失败没有任何弹窗提示。
>
> **零个 `accessibilityLabel` / `accessibilityHint`。** 两端全仓库搜索结果为空。纯图标按钮（垃圾桶、电源、齿轮、ⓘ）对 VoiceOver 完全不可读。
>
> **零个动态字体。** Mac 端 44 处硬编码 `.font(.system(size:))`，iPad 端全部 `UIFont.systemFont(ofSize:)`，无 `adjustsFontForContentSizeCategory`。辅助功能里的文字大小设置对本 App 无效。

### 4.1 macOS Sender

#### M-01 — 没有 Settings scene，⌘, 无效 〔P1 / HIG〕

`BetterCastSenderApp.swift:15-27` 只有一个 `WindowGroup`。全文件搜索 `Settings {`、`.commands`、`CommandGroup`、`CommandMenu` 均为 0 命中。

后果：macOS 用户按 ⌘, 没反应；App 菜单里没有"设置…"项；没有自定义 About 面板；没有 Help 菜单内容。设置被做成主窗口侧边栏的一个 item，这是 iOS/Web 的心智模型，不是 macOS 的。

建议：加 `Settings { }` scene 承载偏好设置，主窗口侧边栏保留设备与状态。

#### M-02 — 侧边栏手搓选中态，放弃了原生 List 语义 〔P1 / HIG〕

`BetterCastSenderApp.swift:828-856`：每个侧边栏行是 `Button { selection = tag } label: {...}` + `.buttonStyle(.plain)`，选中态用 `.listRowBackground(RoundedRectangle().fill(tint.opacity(0.1)))` 自绘。

放弃了 `List(selection:)` 就同时放弃了：上下方向键在侧边栏导航、VoiceOver 的"已选中/共 N 项"语义、系统选中色（含窗口失焦时的降饱和态）、以及 macOS 26 的原生侧边栏材质表现。`tint.opacity(0.1)` 在深色模式和用户自定义强调色下都不会与系统一致。

建议：改用 `List(selection: $selection)` + `NavigationLink` / `.tag()`，把自绘背景删掉。

#### M-03 — 破坏性操作全部零确认 〔P1 / HIG〕

`DetailPanelView` 的 "Controls" 区（`:1262-1296`）把六个动作平铺成两行按钮：

| 按钮 | 实际行为 | 确认 | 可撤销 |
| --- | --- | --- | --- |
| **Reset Permissions** | `tccutil reset ScreenCapture` **然后 1 秒后自动重启 App**（`:3798-3830`） | 无 | 否 |
| **Restart** | 拉起新实例并 `terminate`（`:3836-3850`） | 无 | 否 |
| **Setup Wizard** | `hasCompletedOnboarding = false`，直接踢回引导 | 无 | 是 |
| **Clear Pairing** | 删 Keychain 配对密钥（`:2735`） | 无 | 否 |
| 设备行 🗑 | `forgetDevice(named:)` | 无 | 部分 |
| 侧边栏 ⏻ | `NSApplication.terminate` | 无 | 否 |

最严重的是 Reset Permissions：一个放在设置表单里、名字听起来像"刷新一下"的按钮，会吊销屏幕录制授权**并强制重启 App**，正在进行的串流直接中断，且没有任何预告。

另外 Clear Pairing 只删 Keychain，不撤销已建立的 session（上轮 SAVE-03，未修）——UI 上的"Clear"和实际语义不一致。

建议：破坏性动作加 `confirmationDialog`；按 HIG 给会打开其他界面的按钮加省略号（"Screen Recording" → "打开屏幕录制设置…"）；把重启类动作移出设置表单。

#### M-04 — 配对码保存失败完全静默 〔P2〕

`:1208-1212`：

```swift
Button("Save Pairing Code") {
    if client.savePairingCode(pairingCodeInput) {
        pairingCodeInput = ""
    }
}
```

`savePairingCode` 失败时只 `return false` 并写日志（`:2720-2733`）。UI 分支没有 `else`。用户看到的是：点了保存，输入框内容还在，没有任何提示。无法区分"保存成功了但没清空"和"保存失败了"。

#### M-05 — 设置生效语义三种混在一起 〔P2 / HIG〕

macOS HIG 的惯例是设置即时生效。当前实际是三套并存：

- 即时：Brightness（直接写硬件亮度）
- 需按 Apply Settings：分辨率（且该按钮仅在已连接时可用，`:1265-1270`）
- 需重新连接：Position（InfoTip 自述"Applies to the next extended display connection"）

而 Apply Settings 被放在另一个 Section（Controls），和它控制的那些 Picker 隔开。用户没有任何线索判断哪个设置属于哪一类。

叠加上一轮 SAVE-01：分辨率、Retina、质量、网络模式、Auto-Connect、扩展/镜像、音频开关**全都不持久化**，重启即回默认。

#### M-06 — InfoTip 破坏 Form 对齐，且文案有事实错误 〔P2〕

结构上：`HStack { Picker("Use as", ...); InfoTip(...) }`（`:1142-1148` 等 8 处）。把 `Picker` 塞进 `HStack` 后，它不再参与 grouped Form 的标签列对齐，各行标签与控件的对齐关系会不一致。

内容上，`:1241` 的 InfoTip 写着：

> "This private build uses one authenticated TCP stream for video, input, heartbeat, and optional audio."

两处与实现不符：(a) 启用音频时 sender 会建**第二条**独立认证 TCP（`:3024-3082`）；(b) 当前是 display-only 路径，"input" 已不存在。

建议：InfoTip 改用 Form 的 Section footer 或控件自身的 `.help()`，并修正文案。

#### M-07 — 引导流程有一个死步骤 〔P2 / HIG〕

`OnboardingView` 声明三步 `["Screen Recording", "Local Control", "Ready"]`，但第二步：

- `accessibilityStep` 传入 `isGranted: true`（硬编码）、`actionTitle: ""`、`action: {}`（`:487-497`）
- `stepCompleted(1)` 恒返回 `true`（`:548`）
- `checkPermissions()` 里 `accessibilityGranted = true` 恒真（`:557`）
- 轮询定时器在 `currentStep == 1` 时立刻推进到 2（`:568-571`）

结果：一个纯文字说明被包装成"权限步骤"的外观，且 1.5 秒后自己跳掉。这是从需要辅助功能权限的旧版本留下的空壳。

同一个视图还有两个问题：

- `:474-483` 无条件连续打开**两个** System Settings URL，注释写着"Fallback for older macOS"却没有任何版本判断——在 macOS 13+ 上会连开两次设置。
- `:436` 主按钮在权限未授予时标题是 "Skip"，却仍用 `.borderedProminent`。HIG 里 prominent 代表推荐操作，不该是"跳过"。

#### M-08 — 其余 Mac 端 HIG 偏离

| 位置 | 问题 |
| --- | --- |
| `:791-798` | 侧边栏底部放 Quit 电源按钮。macOS 退出走 ⌘Q / App 菜单 |
| `:1351-1352` | About 区用绿色文字显示中性信息（"Manual self-built updates only"），绿色在系统语义里是成功态 |
| `:1254-1258` | Transfer Speed 用绿色显示中性指标 |
| `:1319` | Disconnect 按钮 `.tint(.red)`。断开不是数据破坏性操作，红色被滥用 |
| `:1355-1378` | "What's New" 更新日志塞进 Settings；手动 `Text("\u{2022}")` 拼项目符号 |
| `:449` | "Get Started" 用 `.tint(.green)` 覆盖用户的系统强调色 |
| `:724-757` | 侧边栏 `ForEach` 的过滤闭包每帧执行 O(n²) 去重比较 |

### 4.2 iPadOS Receiver

#### I-01 — 内容最大宽度约束被击穿，文字通栏 〔P1〕

`ViewController.swift:378-396`：

```swift
contentView.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 40)   // 必需 (1000)
contentView.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -40) // 必需 (1000)

// Max width for readability on iPad
let maxWidth = contentView.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
maxWidth.priority = .defaultHigh   // 750
maxWidth.isActive = true
```

leading + trailing 两条必需约束已经把宽度完全定死为 `屏宽 - 80`，优先级 750 的 `<= 400` 必然被打破。代码注释的意图（"Max width for readability on iPad"）从未生效。

模拟器实测（iPad Pro 13"）：竖屏下正文行宽约 950pt，横屏下更宽，每行远超适宜阅读的 65 字符左右。截图见 `2026-08-14-ipad-onboarding.png` / `-landscape.png`。

修法很简单：把 leading/trailing 改成 `>=` 并降优先级，或直接让 `maxWidth` 为必需 + 居中。

#### I-02 — "Hide Settings Button" 是个陷阱门 〔P1 / HIG〕

`:686-693, 744-758`：设置面板里有个橙色按钮 "Hide Settings Button"，点了之后齿轮按钮淡出消失。

三个问题叠加：

1. **恢复方式是三指轻点屏幕**（`:738-741`），这个手势在 UI 里没有任何地方提示过。用户点完就失去了唯一入口。
2. **不持久化**：`hideSettingsButton()` 只改 `isHidden`，没写 `UserDefaults`。重启 App 又回来了——所以它既不可靠地隐藏，又会让用户困惑。
3. 三指轻点在 iPadOS 上与系统的三指撤销/重做手势同处一个手势家族，也会和 AssistiveTouch 交互。README `:50` 特意说明"唯一注册的手势是三指轻点"，说明这是有意为之，但选型本身有冲突风险。

#### I-03 — Reset Pairing 无确认 〔P1 / HIG〕

`:695-702` 红色 "Reset Pairing" 按钮直接调 `clearPairingCode()` → `deleteSecret()`。一次误触就清空配对，需要回到 Mac 端重新走配对流程。全 App 没有 `UIAlertController`。

#### I-04 — 触控目标小于 44pt 〔P2 / HIG〕

| 控件 | 尺寸 | HIG 最小 |
| --- | --- | --- |
| 齿轮按钮（`:637-638`） | 40 × 40 | 44 × 44 |
| Save 按钮（`:440-441`） | 72 × 40 | 44 × 44 |
| Close 按钮（`:705-710`） | 无高度约束，仅内在尺寸（约 20pt） | 44 × 44 |
| 面板内三个主按钮（`:728-730`） | 44 ✅ | — |

#### I-05 — 全硬编码颜色，占位符对比度不足 〔P2 / HIG〕

全部使用 `UIColor.white.withAlphaComponent(...)`、`.black`、自定义 `UIColor(red: 0.4, green: 0.6, blue: 1.0)`，没有一处语义色（`.label` / `.secondaryLabel` / `.systemBackground` / `tintColor`）。

其中 `:232` 输入框占位符用 `UIColor.white.withAlphaComponent(0.25)` 压在近黑底上——模拟器截图里肉眼可见极淡，达不到正文对比度要求。这是首次使用时最需要看清的那个提示。

配合 CFG-05 的强制深色，整套颜色体系对系统外观、增强对比度、降低透明度等设置完全不响应。

#### I-06 — 无 Reduce Motion 判断 〔P2 / HIG〕

`:469-473` 的 `startPulseAnimation()` 是 `.repeat + .autoreverse` 的无限动画，没有检查 `UIAccessibility.isReduceMotionEnabled`。全 App 无任何 `UIAccessibility` 引用。

#### I-07 — 无键盘避让 〔P2，分析未实测〕

全文件无 `keyboardWillShow` / `keyboardLayoutGuide` / 任何键盘通知处理。

`contentView` 是垂直居中（`:380`，偏移 -20），配对码输入框位于内容下部。按 iPad Pro 13" 横屏（772pt 高）估算：内容块约 590pt 高，居中后底部约在 y=662；iPad 横屏软键盘约 353pt 高，从 y≈419 起遮挡。配对码输入框落在 560–622 区间，**大概率被键盘完全遮住**。

这是分析结论，未在模拟器实测（需要注入触摸事件）。建议在真机上按一次即可确认。

#### I-08 — 设备名在 iOS 16+ 会退化成通用名 〔P2〕

`UIDevice.current.name` 共 4 处使用，包括 Bonjour 广播名（`NetworkListenerIOS.swift:99,134,202`）和输入框默认值（`ViewController.swift:220`）。

自 iOS 16 起，未持有相应 entitlement 的 App 拿到的是通用型号名（"iPad"），不是用户设置的设备名。后果：Mac 端发现列表里所有 iPad 都叫 "iPad"，而 Mac 端恰好有一套按名字去重的逻辑（`canonicalDeviceName` + `$0.name < service.name`），多台设备会被折叠。

叠加：改自定义名后只写 `UserDefaults` 并打一行日志"restart app to apply"（`:598-603`），UI 上没有任何"需重启生效"的提示。用户改完名字看不到任何变化。

#### I-09 — 错误反馈只有一行小字 〔P2 / HIG〕

配对保存失败、清除失败、Keychain 不可用，全部只把 `statusLabel` 改成一行 13pt / 50% 白的文字并把小圆点变橙（`:568-596`）。没有弹窗、没有触觉反馈（全 App 无 `UIFeedbackGenerator`）、没有色彩之外的状态区分。

#### I-10 — 首屏信息层级倒置 〔P2〕

从截图看，首屏顺序是：图标 → 标题 → 设备名输入框 → 分隔线 → 三段编号说明（占据大半屏）→ 配对码输入框 → 状态行。

唯一必须完成、且不完成就无法使用的操作（输入配对码）被放在三段说明之后，视觉权重低于那些说明文字，而且没有编号、不属于"1/2/3"序列。首次使用的用户最可能的动作是从上往下读完三步，然后才发现底下还有个必填项。

另外说明文字第 1 步写的是"Build and run the private Mac sender from **this source tree**"——这是开发者文案出现在产品界面里。

---

## 5. 上一轮问题的当前状态

全部未修。以下按原编号列出，供你决定优先级：

**C0 发布阻断**：LIC-01（GPLv3 上游代码被整体标为 MIT）——需要你确认是否存在仓库外的书面重许可。这是唯一一条我无法通过技术手段推进的，只能由你或律师判断。

**P1**：APP-01（IPA 脚本产物缺 framework/签名/provision）、APP-02（Sender 状态数据竞争）、APP-03（iOS Receiver 同类问题）、APP-04（VideoEncoder teardown 悬空回调）、APP-05（媒体帧无长度上限 + 零 NAL 越界）、APP-06（clean EOF / 握手超时未闭合）、APP-07（音视频连接无 session role，聚合 watchdog 可漏报冻结）、APP-08（→ 本轮升级为 CFG-02）、APP-09（主路径无 CI）、APP-10（Mac 产物仅 ad-hoc，Gatekeeper rejected）、APP-11（缺 privacy manifest）、APP-12（无第三方许可证清单）

**P2**：SAVE-01～04、STAB-01～10

其中 APP-05 和 APP-06 值得单独强调：它们是"认证后的对端可以让 App 挂起或崩溃"这一类问题，虽然攻击面限于已配对设备，但也覆盖"对端异常"这种正常故障场景。修复成本不高（加长度上限 + `isComplete` 处理 + 握手 deadline），收益是消掉一整类偶发挂死。

---

## 6. 明确没有验证的内容

本轮不能声称以下任何一项可用：

- 真机 Mac → 真机 iPad 的持续串流（本机未连接 iPad，仅有 iPhone 15）
- Screen Recording / 本地网络权限的首次申请与拒绝后恢复
- AWDL / Router / USB-Thunderbolt 三条路径的实际行为
- Chrome 音频到 iPad 的真实播放
- iPad 强杀重启后的 Keychain 读取
- 5 分钟后台 grace、Wi-Fi 切换、Mac 崩溃/断电
- Developer ID 签名 + 公证后的 Mac 安装
- `xcodebuild archive/exportArchive` 产出的真机 IPA 安装
- I-07 的键盘遮挡（仅分析）

---

## 7. 建议的修复顺序

按"改动成本 / 收益"排，不是按严重度排：

**第一批：一行到十行的配置修复，收益极高**

1. `Info.plist` 删掉或改正 `UIRequiredDeviceCapabilities`（CFG-01）
2. Mac `Info.plist` 补 `NSLocalNetworkUsageDescription` + `NSBonjourServices`（CFG-02）
3. iPad `contentView` 宽度约束优先级修正（I-01）
4. Close / Save / 齿轮按钮补到 44pt（I-04）
5. 占位符颜色从 0.25 提到 0.5 以上（I-05）
6. 修正 InfoTip 里关于"单条 TCP / input"的错误文案（M-06）

**第二批：交互安全性**

7. 给 Reset Permissions / Restart / Clear Pairing / Reset Pairing / Forget Device 加确认对话框（M-03、I-03）
8. 配对码保存失败给出可见反馈（M-04、I-09）
9. 删掉或重做 "Hide Settings Button"（I-02）
10. 删掉引导流程的死步骤，修掉双开 System Settings（M-07）

**第三批：平台规范**

11. 加 `Settings { }` scene 和菜单栏 commands（M-01）
12. 侧边栏改回原生 `List(selection:)`（M-02）
13. 补 accessibilityLabel、换语义字体与语义颜色、加 Reduce Motion 判断
14. 抬部署目标到 iOS 17+，清理死的 `#available` 分支（CFG-04）

**第四批：上一轮的稳定性主线**

15. APP-05 / APP-06（帧边界、EOF、握手超时）
16. APP-04（encoder teardown）
17. APP-02 / APP-03（状态所有权重建）
18. APP-01（用 archive/export 重做 IPA）
19. APP-09（Apple 端 CI）

LIC-01 独立于以上，需要你先确认许可证状态再决定是否对外发布。

---

## Fable 自检

- 需求清单逐项核对：upstream 名称 ✅｜遗留与新增问题 ✅｜潜在风险 ✅｜Apple 设计规范符合度 ✅｜双端可用性（编译/安装/启动已验证，真机 E2E 未验证并已标注）⚠️
- 证据分级：已实测（构建、测试、并发诊断、bundle plist 实读、模拟器截图、对照实验）／仅代码审阅（M-05、I-08 等）／仅分析未实测（I-07）三类已在文中分别标注。
- 过程修正：横屏截图初判为"旋转布局 bug"，经系统 App 对照实验推翻并已在 CFG-03 中如实记录，未写入问题清单。
