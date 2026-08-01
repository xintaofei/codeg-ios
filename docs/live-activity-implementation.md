# 灵动岛 / 实时活动：生产级实施方案

> v1.0 · 2026-07-12 · 承接 `docs/live-activity-analysis.md`（可行性分析），把结论落成可执行工程方案
>
> 前置阅读：分析文档 §3–§8（三道约束 + 三阶段路线）。本文假设读者已认同"Live Activity 是 M4/M5 下游、分阶段增量"的结论，只讲**怎么做**。

---

## 0. 方案摘要

**目标架构一句话**：新增一个 **Widget Extension** + 一个 **共享模块**（放 `ActivityAttributes` 与极简设计令牌），app 端由一个 **`LiveActivityController`** 观察现有 `ActivityModel` 脉冲来起/更/停活动；锁屏推送在阶段 2 经**云中继**代发 APNs。

**三阶段与依赖**：

| 阶段 | 交付 | 服务端依赖 | 前置 | 规模 |
|---|---|---|---|---|
| **M-LA0 地基** | Widget Extension target + 共享模块 + App Group/entitlements | 无 | — | M |
| **P0 前台骨架** | running/done/review 三态本地驱动 + 灵动岛/锁屏 UI + 深链 + 设置开关 | 无 | LA0 | M |
| **P1 实时化** | 审批态 + 活动工具实时；驱动源 poll→hub | 无（客户端 M4） | P0 + **M4 SessionHub** | L |
| **P2 推送** | 锁屏审批推送 + Approve/Deny 交互按钮 | **中继 + server webhook + token 上报端点** | P1 + 推送基础设施 | L |

**五个关键工程决策**：

1. **不让扩展 import app**——扩展是独立二进制，且 `Theme.accent` 依赖 UIKit trait 桥接（`Theme.swift:72` 的 `UIColor { tc in … }`）无法在 widget 进程复现。→ 抽一个**瘦共享模块** `CodegActivityKit`，只放数据类型 + 静态色令牌。
2. **`ContentState` 保持极小且纯数据**（APNs 推送 payload < 4KB 硬限）——只放渲染必需字段，正文截断，敏感内容默认不上锁屏。
3. **驱动源可插拔**：P0 用 `ActivityModel`（poll），P1 换成 M4 `SessionHub`（事件）——`LiveActivityController.sync(snapshot:)` 接口不变，只换喂给它的数据。
4. **reconcile 纯函数化**：running 会话集合 ↔ 活动集合的差分逻辑抽成纯函数，便于单测（无需真机/真活动）。
5. **中继而非每台 server 配证书**（分析 §7 方案 C）：自托管 server 只 webhook 出事件，中继持 APNs 凭证代发。

---

## 1. 目标架构

```
┌─────────────────────────────────────────────────────────────┐
│  CodegiOS (app target)                                       │
│   AppModel ─ ActivityModel (P0 poll)  ┐                      │
│            └ (P1) SessionHub (M4)     ├─► LiveActivityController │
│   RootView .task 驱动                  ┘        │             │
│   LiveActivityIntent (P2, Approve/Deny)         │ Activity.request/update/end
│                                                 ▼             │
│                          ┌──────────────────────────────────┐│
│  CodegActivityKit ◄──────┤  ActivityAttributes / ContentState││
│  (shared framework)      │  映射函数 · 极简色令牌 · AgentKind ││
│   ▲                      └──────────────────────────────────┘│
│   │ import                                  ▲ import          │
│  ┌┴──────────────────────┐                  │                 │
│  │ CodegWidgets (appex)  │──────────────────┘                 │
│  │  ActivityConfiguration│  锁屏卡 + DynamicIsland UI         │
│  └───────────────────────┘  widgetURL: codeg://conversation/ │
└─────────────────────────────────────────────────────────────┘
        ▲ (P2) APNs liveactivity push
        │
   ┌────┴─────┐   webhook (事件)   ┌──────────────┐
   │  中继云   │ ◄───────────────── │ 自托管 server │
   │ (持 p8)  │                    │  (:3080/3090) │
   └──────────┘                    └──────────────┘
```

**新增构件**：

| 构件 | 类型 | 目的 |
|---|---|---|
| `CodegActivityKit` | 共享 framework（app + appex 都依赖） | `ActivityAttributes` / `ContentState` / 映射 / 静态令牌 |
| `CodegWidgets` | app-extension（`.appex`） | Live Activity / 灵动岛 UI |
| `LiveActivityController` | app target 类 | 起/更/停活动，reconcile |
| `LiveActivityIntent`（P2） | app target `AppIntent` | Approve/Deny 交互按钮 |
| 中继（P2） | 独立服务，非本仓 | 持 APNs 凭证代发 |

---

## 2. 工程地基（M-LA0，阶段前置）

> ⚠️ 工程由 xcodegen 生成（`CodegiOS.xcodeproj` git-ignored）。所有工程改动进入 `project.yml`；签名团队由 `Config/Signing.xcconfig` 统一提供，并通过被忽略的 `Config/Signing.local.xcconfig` 或 `CODEG_DEVELOPMENT_TEAM` 覆盖。每次改完执行 `xcodegen generate` 后验签。

### 2.1 共享 framework：`CodegActivityKit`

```yaml
# project.yml — targets 追加
targets:
  CodegActivityKit:
    type: framework
    platform: iOS
    deploymentTarget: "18.0"
    sources: [CodegActivityKit]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.codeg.ios.activitykit
        # 关键：framework 需可被 appex 链接
        APPLICATION_EXTENSION_API_ONLY: "YES"
```

**放什么**（只放"两端都要、且不拖 UIKit trait/网络"的东西）：
- `CodegSessionActivityAttributes`（含 `ContentState`）
- `Phase` 枚举 + 从 `ConversationSummary` / `LiveSessionSnapshot` 的映射函数
- **极简静态色令牌** `ActivityPalette`（`running`/`waiting`/`done`/`cancelled` 四个静态 `Color`，**不走** `Theme` 的 trait 桥接——widget 进程没有 app 的 `AccentPaletteTrait`）
- `AgentKind` → SF Symbol 名 / 品牌图标名（图标资源另放 appex 的 asset catalog）

> 注意 `APPLICATION_EXTENSION_API_ONLY`：该 framework 被 appex 链接，不能用扩展禁用的 API。保持它纯数据即可。

### 2.2 Widget Extension：`CodegWidgets`

```yaml
  CodegWidgets:
    type: app-extension
    platform: iOS
    deploymentTarget: "18.0"
    sources: [CodegWidgets]
    dependencies:
      - target: CodegActivityKit
        embed: false          # 由宿主 app 统一 embed
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: app.codeg.ios.widgets   # 必须是 app id 的子级
    info:
      path: CodegWidgets/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
```

app target 追加依赖（embed 扩展 + 链接共享库）：

```yaml
  CodegiOS:
    dependencies:
      - package: SwiftTerm
      - target: CodegActivityKit
        embed: true
      - target: CodegWidgets
        embed: true            # .appex 打进 app bundle 的 PlugIns/
```

### 2.3 App Group + Keychain Sharing

**为什么需要**：扩展（及 P2 的 App Intent）要读 **server token** 才能回拉状态 / 发审批。token 在 Keychain（`Keychain.swift:13` service `com.codeg.ios.server-token`，`:39` `AccessibleAfterFirstUnlock` 后台可读）——但当前**无 keychain access group**，扩展读不到。

- **App Group** `group.app.codeg.ios`：共享"当前 server 配置 + 活动↔会话映射"给扩展/Intent（`ServerProfile` 从 UserDefaults 迁到 App Group `UserDefaults(suiteName:)`，或镜像一份）。
- **Keychain Sharing** access group `$(AppIdentifierPrefix)app.codeg.ios.shared`：`Keychain.swift` 的 query 加 `kSecAttrAccessGroup`，app 与扩展共享 token。

entitlements 文件（两个 target 各一，xcodegen 引用）：

```yaml
# CodegiOS.entitlements / CodegWidgets.entitlements
com.apple.security.application-groups: [group.app.codeg.ios]
keychain-access-groups: ["$(AppIdentifierPrefix)app.codeg.ios.shared"]
```

```yaml
# project.yml 两 target 的 settings.base 各加：
CODE_SIGN_ENTITLEMENTS: CodegiOS/CodegiOS.entitlements   # 及 CodegWidgets 对应
```

> 🔒 **签名影响**：App Group + Keychain Sharing 是 provisioning capability，真机构建需两个 target 的描述文件都带上（Automatic signing 会自动处理，但首次要在开发者账号里注册 App Group id）。模拟器 ad-hoc 不校验，但 Keychain 在 sim 走 UserDefaults 回退（`Keychain.swift:15-18`）——**扩展侧的 sim 回退要同样迁到 App Group UserDefaults**，否则扩展读不到 sim 的 token。

### 2.4 Info.plist / 能力

- app target Info.plist 加 `NSSupportsLiveActivities: true`（`project.yml` 的 `info.properties`）。
- 可选 `NSSupportsLiveActivitiesFrequentUpdates: true`（P2 高频推送时评估，注意系统会限流）。

**LA0 验收**：`xcodegen generate` → 真机与 sim 均能构建、签名通过、扩展被 embed（`PlugIns/CodegWidgets.appex` 存在）、app 能 `import CodegActivityKit`。

---

## 3. 数据模型（`CodegActivityKit`）

```swift
import ActivityKit
import SwiftUI

public struct CodegSessionActivityAttributes: ActivityAttributes {
    // —— 静态（活动生命周期内不变）——
    public let conversationId: Int
    public let serverId: String       // 深链定位 + 扩展/Intent 选 client
    public let folderName: String
    public let agentKind: String      // AgentKind rawValue → 图标
    public let title: String          // 会话标题（起活动时的快照）

    public struct ContentState: Codable, Hashable {
        public enum Phase: String, Codable {
            case running, waitingApproval, review, done, cancelled
        }
        public var phase: Phase
        public var activeToolTitle: String?   // "Editing RootView.swift"（P1，来自 activeToolCalls）
        public var summaryLine: String?       // 最新进展一行（截断 ≤120 字，隐私可关）
        public var pendingKind: String?       // permission | question | plan（P1）
        public var tokensUsed: Int?
        public var updatedAt: Date
    }
}
```

**映射函数**（纯函数，可单测）：

```swift
public extension CodegSessionActivityAttributes.ContentState {
    // P0：从列表层（poll）—— 拿不到审批态（分析 §4），故无 waitingApproval
    static func from(summary: ConversationSummaryLite, now: Date) -> Self { … }
    // P1：从 hub 快照 —— 有 activeToolCalls / pendingPermission / pendingQuestion
    static func from(snapshot: LiveSessionSnapshotLite, now: Date) -> Self { … }
}
```

> `…Lite` 是共享模块里的**投影类型**（只含映射需要的字段），避免把整个 `Conversation.swift` / `AcpEvent.swift` 搬进共享库。app 端把 `ConversationSummary` / `LiveSessionSnapshot` 投影成 `…Lite` 再喂进来。

**约束落实**：
- `ContentState` 全 `Codable & Hashable`、小体积（P2 推送 payload 硬限 4KB）。
- **隐私**：`summaryLine` 默认**开**但可在设置关闭；`pendingKind` 只放类型不放参数；不放 diff / 文件正文 / 密钥。锁屏可见性是产品决策点（§11）。
- `updatedAt` 驱动"多久没更新"的陈旧提示 + 推送 `stale-date`。

---

## 4. 阶段 0 — 前台驱动骨架（零服务端）

**范围声明**：仅 **running / done / review** 三态（列表层可见）；**不含审批态**（数据源不存在，见分析 §4）；仅**前台 + 短后台窗口**更新（本地 `update()`，见分析 §3）。价值定位=**验证 UI 与交互骨架**，不是完整体验。

### 4.1 `LiveActivityController`（app target，新）

职责：把"当前 running 会话集合"与"当前活动集合"对账。

```swift
@MainActor
final class LiveActivityController {
    // 活动键 = conversationId；内存映射 conversationId -> Activity<…>
    func sync(running: [ConversationSummaryLite], enabled: Bool, foreground: Bool)
    func endAll(reason: EndReason)     // 服务端切换 / 用户关开关 / 登出
}
```

对账逻辑（**抽纯函数 `reconcile(current:desired:) -> [Action]`** 便于测）：
- desired 里有、current 没有 → `Activity.request(...)`（**仅 `foreground` 且系统允许时**——iOS 16.1 起活动必须前台；P2 push-to-start 才可后台起）。
- 两边都有 → 若 `ContentState` 变了 `activity.update(...)`。
- current 里有、desired 没有（跑完/取消）→ 先 `update` 成终态（done/cancelled）再 `end(dismissalPolicy: .after(.now + 4h))`。
- **并发上限**：cap N（如 5），超出只保留最近活跃的 N 个（其余不起活动，`log` 声明——分析式"no silent caps"）。
- **授权门控**：`ActivityAuthorizationInfo().areActivitiesEnabled`；关闭时 `sync` 空转。

**挂载点**：`AppModel` 持有 `let liveActivity = LiveActivityController()`；在 `RootView.swift:62` 的活动脉冲 `.task` 里，每次 `activity.refresh` 后调用 `liveActivity.sync(running: activity.running.map(\.lite), enabled: …, foreground: scenePhase == .active)`。server 切换时 `resetServerScopedState()`（`AppModel.swift:170`）里加 `liveActivity.endAll(.serverChanged)`。

**app 重启残留清理**：启动时 `Activity<CodegSessionActivityAttributes>.activities` 复原已有活动，对账（服务端已结束的立即 `end`）。

### 4.2 Widget UI（`CodegWidgets`）

```swift
struct CodegSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CodegSessionActivityAttributes.self) { ctx in
            LockScreenView(ctx)               // 锁屏 + 老机型主形态
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading)  { AgentBadge(ctx) }
                DynamicIslandExpandedRegion(.trailing) { PhaseGlyph(ctx) }
                DynamicIslandExpandedRegion(.center)   { Text(ctx.attributes.title) }
                DynamicIslandExpandedRegion(.bottom)   { ProgressLine(ctx) /* P2: Approve/Deny */ }
            } compactLeading: { AgentDot(ctx) }
              compactTrailing: { PhaseGlyph(ctx) }
              minimal: { PhaseGlyph(ctx) }
            .widgetURL(URL(string: "codeg://conversation/\(ctx.attributes.conversationId)"))
        }
    }
}
```

- 复用 `CodegActivityKit.ActivityPalette` 上色（**静态色**，不依赖 app 的 trait 桥接）。
- 品牌图标：把 6 个 agent SVG 的简化版（或 SF Symbol 兜底）放 appex 的 asset catalog（memory `ios-svg-brand-icons` 的 CoreSVG 坑同样适用）。
- 点击走 `widgetURL` → `RootView.onOpenURL` → `AppModel.handle(url:)`（`AppModel.swift:117`，已就位）。

### 4.3 设置开关

- 新增"实时活动"开关（放 Settings 的通知/通用类，风格用 `SettingsRow`）。默认 **关**——首次开启走系统授权引导 + 一句说明"仅在 app 打开时更新，锁屏实时需后续版本"。
- 开关状态存 App Group UserDefaults（扩展/Intent 也要读）。关闭时 `liveActivity.endAll(.userDisabled)`。

### 4.4 验证（P0）

- **sim 可测本地更新**：Live Activity 的本地 `request/update/end` 在模拟器可跑；灵动岛需选 iPhone 15/16 Pro 类 sim。
- 复用 memory 的 env-gate + mock server 套路（`/tmp/codeg_mock_*.py`）：mock 让某会话在 `in_progress`↔`completed` 间翻转，观察活动起/更/停 + 截图（紧凑/展开/锁屏三形态、授权关闭态、并发 cap）。
- 深链回归：`simctl openurl codeg://conversation/<id>` 落到详情（注意 memory 的双 app 注册坑，先 uninstall 旧包）。
- **不回归**：P0 完全旁路 `SessionDetailViewModel`，不碰 live 流；确认 `.id` teardown（`RootView.swift:336`）行为不变。

---

## 5. 阶段 1 — 实时化（依赖 M4 `SessionHub`）

**前置**：客户端 M4（`ios-redesign-plan.md` §10.2）——app 级持久多路复用 socket + `scenePhase` 生命周期。P1 不引入服务端改动，但**强依赖 M4 落地**。

改动：
1. **驱动源切换**：`LiveActivityController.sync` 的输入从 `activity.running`（poll）换成 hub 的实时快照/事件。`sync` 接口不变，喂 `LiveSessionSnapshotLite`。
2. **审批态上桌**：hub 订阅所有会话，`pendingPermission`/`pendingQuestion`（`SessionDetailViewModel.swift:84/86` 的等价物提升到 hub 级）→ `ContentState.phase = .waitingApproval` + `pendingKind`。这是**分析 §4 的解法 (b)**。
3. **修 `conversation_status_changed` no-op**：`SessionDetailViewModel.swift:1284` 目前 `break`；M4 后让 hub 消费它驱动状态翻转，不再只靠 25s poll。
4. `activeToolTitle` / `summaryLine` 实时化（来自 `activeToolCalls` / `liveMessage`）。

**替代方案 (a)（若 M4 延后）**：服务端在 list/poll 层加一个 `awaiting_approval` 字段，P0 的 poll 路径即可点亮审批态——**更快但需服务端改动**，且拿不到"具体卡在哪个工具"。二者权衡见分析 §4；建议随 M4 走 (b)，(a) 仅作 M4 未就绪时的过渡。

---

## 6. 阶段 2 — 推送（锁屏完整体验）

**前置**：推送基础设施（中继 + server webhook + token 上报）。这是唯一能在锁屏/挂起时更新的路径（分析 §3/§7）。

### 6.1 Push token 管道

```swift
// 起活动时申请 per-activity token（iOS 16.1+）
for await tokenData in activity.pushTokenUpdates { upload(.activity, tokenData) }
// push-to-start：app 后台/关闭时也能被推起（iOS 17.2+）
for await tokenData in Activity<…>.pushToStartTokenUpdates { upload(.pushToStart, tokenData) }
```

- 新 REST 端点（对齐 memory `codeg-api-contract` 的 camelCase-req/snake_case-resp）：`register_live_activity_token`，body `{conversationId, activityToken, pushToStartToken, platform}`，Bearer 鉴权。
- token 上报**给谁**：给中继（§6.2），不是自托管 server 直连 APNs。

### 6.2 中继架构（分析 §7 方案 C）

- **中继**（独立云服务，持 APNs `.p8` key + team/key id）：接自托管 server 的 webhook（会话状态变化/审批产生），按 `conversationId` 找到对应 push token，代发 APNs `liveactivity` push。
- **server webhook 契约**：server 在 `permission_request` / `turn_complete` / `conversation_status_changed` 时 POST 中继 `{event, conversationId, contentState, serverKey}`。
- **APNs payload**（`apns-push-type: liveactivity`，`apns-topic: app.codeg.ios.push-type.liveactivity`）：

```json
{ "aps": {
    "timestamp": 1720800000,
    "event": "update",            // 或 "end" / "start"(push-to-start)
    "content-state": { "phase": "waitingApproval", "pendingKind": "permission", "updatedAt": … },
    "stale-date": 1720803600,
    "alert": { "title": "Waiting for approval", "body": "…" }   // 审批态才带 alert
}}
```

- **为什么中继**：自托管每台配 p8 不现实（分析 §7 方案 B 分发地狱）；中继一处持凭证，server 只需能出网 webhook。信任边界见 §6.4。

### 6.3 交互按钮（App Intent，Approve/Deny）

```swift
struct RespondPermissionIntent: LiveActivityIntent {
    @Parameter var conversationId: Int
    @Parameter var requestId: String
    @Parameter var optionId: String
    func perform() async throws -> some IntentResult {
        // 用共享 keychain 的 token 组 client → POST acp_respond_permission
        // 失败（server 不可达）→ 更新 ContentState 提示"回 app 处理"
    }
}
```

- ⚠️ **可达性约束**（分析 §5）：按钮 `perform()` 需手机能**连回 server**。局域网 server + 人在外面 = 发不出去。→ 失败要优雅降级：ContentState 标记 `needsAppReachability`，提示回 app（回到可达网络）再处理，**不静默丢**。
- token 经 §2.3 的共享 keychain access group 读取。

### 6.4 安全

- token 上报端点 Bearer 鉴权；中继按 `serverKey` 隔离多租户。
- APNs `content-state` **不含敏感正文**（§3 隐私约束），审批 payload 只放"有一个 permission 待处理"，参数留 app 内。
- 中继是新信任边界：明确它能看到"哪些会话在何时变状态"这类元数据；文档化，作为决策点（§11）。

---

## 7. 边界与失败处理

| 场景 | 处理 |
|---|---|
| 活动超 8h 活跃 / 12h 系统结束 | `ContentState` 带 `stale-date`；过期后活动转"已过期，回 app 查看"；`LiveActivityController` 启动对账时清理僵尸 |
| 用户系统里关了实时活动 | `areActivitiesEnabled == false` → `sync` 空转，不报错 |
| token 轮换 / server 在位编辑 | `AppModel.selectedServerEndpointChanged`（`:181`）→ `endAll(.serverChanged)` + 重新对账 |
| 多 server | 活动键含 `serverId`；切 server 结束旧 server 的活动 |
| 多并发 running 会话 | cap N + "保留最近活跃"，超出 `log` 声明；产品决定 N 与策略（§11） |
| app 重启后残留活动 | 启动读 `Activity.activities` 复原并对账（服务端已结束的立即 `end`） |
| 老机型（无灵动岛） | Live Activity 只走锁屏卡；UI 两形态都要成立 |
| P0 起活动时 app 在后台 | 起不了（iOS 16.1 限制）；等回前台或 P2 push-to-start——文档化，非 bug |
| sim 无 Keychain | 扩展/Intent 侧同样走 App Group UserDefaults 回退（§2.3） |

---

## 8. 特性开关与灰度

- **纯客户端开关**（Settings，App Group 存储），无需服务端 flag。P0 默认关、P1/P2 视稳定度调默认。
- 每阶段独立可合、可回滚（关开关即 `endAll`）。
- P2 中继可先对少量内测 server 开 webhook。

---

## 9. 测试与验证策略

- **单元测试**（纯函数，无需真机）：
  - `ContentState.from(summary:)` / `from(snapshot:)` 映射正确性（各状态、截断、隐私开关）。
  - `reconcile(current:desired:)` 差分：起/更/停/cap/去重/终态。
- **模拟器**：本地 `request/update/end` + 灵动岛三形态截图（env-gate，复用 memory 的 mock server 让状态翻转）；深链回归。
- **真机**（P2 必须）：push token 上报、APNs liveactivity push、push-to-start、App Intent 审批（含不可达降级）。
- **回归护栏**：P0/P1 不得破坏 `SessionDetailViewModel` live 流与 `.id` teardown；P1 改 `:1284` 后回归"状态翻转不再只靠 poll"。
- **mock/中继本地化**：P2 起一个本地假中继 + 假 APNs 网关验证 payload 形状，再上真 APNs。

---

## 10. 任务分解

依赖图：`LA0 → P0 →（客户端 M4）→ P1 →（中继就绪）→ P2`

| # | 任务 | 阶段 | 依赖 | 规模 |
|---|---|---|---|---|
| LA0.1 | `CodegActivityKit` framework + project.yml + 数据类型/映射/令牌 | LA0 | — | M |
| LA0.2 | `CodegWidgets` appex target + 空 `ActivityConfiguration` 骨架 | LA0 | LA0.1 | S |
| LA0.3 | App Group + Keychain Sharing entitlements + token/config 共享改造 + 验签 | LA0 | LA0.2 | M |
| P0.1 | `LiveActivityController` + `reconcile` 纯函数 + 单测 | P0 | LA0.1 | M |
| P0.2 | 挂载到 `AppModel`/`RootView` 脉冲 + server 切换/重启对账 | P0 | P0.1 | S |
| P0.3 | Widget UI（锁屏 + 灵动岛三形态）+ 品牌图标 + widgetURL | P0 | LA0.2 | M |
| P0.4 | Settings 开关 + 授权引导 + 降级 | P0 | P0.2 | S |
| P0.5 | 验证（mock/截图/深链/回归） | P0 | P0.3,P0.4 | S |
| P1.1 | 驱动源 poll→M4 hub（`sync` 换输入） | P1 | **M4**, P0 | M |
| P1.2 | 审批态上桌（hub 订阅 pending）+ `ContentState.waitingApproval` | P1 | P1.1 | M |
| P1.3 | 修 `conversation_status_changed` no-op（`:1284`） | P1 | P1.1 | S |
| P2.1 | push token 管道 + `register_live_activity_token` 端点 | P2 | P1 | M |
| P2.2 | 中继服务 + server webhook 契约 + APNs 代发 | P2 | P2.1 | L |
| P2.3 | `LiveActivityIntent` Approve/Deny + 可达性降级 | P2 | P2.1 | M |
| P2.4 | 真机端到端 + 安全评审 | P2 | P2.2,P2.3 | M |

---

## 11. 需你 / 产品拍板的决策点

1. **锁屏隐私**：`summaryLine`（会话最新进展一行）默认上锁屏，还是默认只显状态不显正文？（涉及敏感代码/路径外泄）
2. **并发活动策略**：cap N 取值；超出是"保留最近活跃"还是"合并成一个汇总活动"？
3. **中继运营方**：谁跑中继（官方托管 vs 用户自建）？信任边界（中继可见状态元数据）能否接受？
4. **纯局域网 server 的可操作性**：Approve/Deny 在不可达时"提示回 app" 是否够，还是要引导用户配公网/穿透？
5. **P1 路径**：等客户端 M4 走方案 (b)，还是先让服务端加 `awaiting_approval` 字段走过渡方案 (a)？
6. **默认开关**：P0 是否默认关（我倾向关，因价值有限 + 避免惊扰）？

---

## 12. 文件改动清单

**新增**：
- `project.yml`（+2 target、app target +依赖/entitlements/Info 键）
- `CodegActivityKit/`（`ActivityAttributes.swift`、`ContentStateMapping.swift`、`ActivityPalette.swift`、`Lite` 投影类型）
- `CodegWidgets/`（`CodegSessionLiveActivity.swift`、UI 子视图、`Info.plist`、asset catalog）
- `CodegiOS/CodegiOS.entitlements`、`CodegWidgets/CodegWidgets.entitlements`
- `CodegiOS/App/LiveActivityController.swift`
- （P2）`CodegiOS/App/RespondPermissionIntent.swift`
- （P2）中继服务（独立仓）

**修改**：
- `App/AppModel.swift`（持有 controller、server 切换/编辑 endAll）
- `App/RootView.swift`（脉冲 `.task` 里驱动 sync）
- `Persistence/Keychain.swift` + `ServerStore.swift`（access group / App Group）
- Settings（开关行）+ `Localizable.xcstrings`（en + zh-Hans，memory 的 textual-insert 技巧）
- （P1）`Features/SessionDetail/SessionDetailViewModel.swift:1284`（接上 `conversation_status_changed`）+ M4 hub
- （P2）`Networking/CodegClient.swift` + `WireRequests.swift`（token 上报端点）

---

## 13. 风险

| 风险 | 缓解 |
|---|---|
| xcodegen 多 target + App Group 破坏签名 | 每次 generate 后验签；所有 target 继承 `Config/Signing.xcconfig`；App Group id 先在账号注册 |
| 扩展代码共享成本（Theme 依赖 trait 桥接不可复用） | 瘦共享模块 + 静态令牌，不追求与 app 像素级一致 |
| P0 价值有限被误当完整体验 | 设置引导明确"仅前台"，默认关；文档化范围 |
| 审批态在 M4 前无 app 级源 | 明确 P1 依赖 M4；过渡方案 (a) 备选 |
| 自托管中继运营 / 信任 | 决策点 §11.3；元数据最小化 + 文档化 |
| 可操作审批受可达性限制 | 不可达优雅降级"回 app"，不静默丢 |
| ActivityKit 前台起活动限制 | push-to-start（P2）覆盖后台起；P0 文档化限制 |

---

## 附：与分析文档的对应

| 分析（`live-activity-analysis.md`） | 本方案落点 |
|---|---|
| §3 交付三鸿沟 | §4（本地驱动）→ §6（推送补齐） |
| §4 审批态 app 级不可见 | §5（M4 hub 上桌）/ 过渡方案 (a) |
| §5 可操作受可达性约束 | §6.3 降级 + §11.4 决策 |
| §6 地基就绪 | §2（共享模块 / entitlements）复用 |
| §7 更新路径矩阵（方案 C） | §6.2 中继 |
| §8 三阶段路线 | §4/§5/§6 + §10 任务分解 |
