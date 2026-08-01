# 会话状态 × 灵动岛 / 实时活动：可行性分析

> v1.0 · 2026-07-12 · 基于代码库全量勘察（`ConversationStatus` / `ActivityModel` / `EventStream` / `SessionDetailViewModel` / `Keychain` 等一手核对，行号均已验证）
>
> 目的：评估「把会话运行状态搬到 iOS 灵动岛（Dynamic Island）与实时活动（Live Activity）」的技术可行性、架构缺口与落地路线。**本文是分析与路线，不含实现。**

---

## 0. 一页纸结论（TL;DR）

**一句话：数据"长得"已经就绪，卡点全在交付层（app 不在前台时怎么把状态推上锁屏）——而这恰好撞上 codeg「自托管本地服务器」的架构。**

三条硬约束，按优先级：

1. **交付鸿沟**：活动状态是 **25s 前台轮询**（后台暂停），实时 socket 是**随会话详情页开合的短连接**，**无后台执行、无 APNs、无推送**。Live Activity 若要在锁屏/挂起时更新，唯一可靠途径是 APNs 推送 —— 而自托管服务器普遍没有这套。
2. **最高价值的「等待审批」态，在 app 级数据层根本看不见**。它不是 `ConversationStatus` 的一个 case；只活在**已打开会话**的 `SessionDetailViewModel` 里。app 级的轮询/列表层区分不了"在跑"和"卡着等你批"。要暴露它，得先有 M4 `SessionHub`（app 级持久连接）或服务端新增字段。
3. **「可操作」审批同样受 server 可达性约束**：即便推送把"等审批"送到锁屏，**按下 Approve 真正生效仍需手机能连回 server**。局域网 server + 人在外面 = 看得到、点不动。

**好消息**：地基比想象的近 —— 传输层 `EventStream` 已经会说 attach/snapshot/replay 协议，`LiveSessionSnapshot` 天然就是一份 ContentState，token 在 Keychain 且后台可读，部署目标 iOS 18 已覆盖所规划的 ActivityKit 能力，`codeg://` 深链已就位。

**建议**：Live Activity 不该现在单独上，它是 M4（持久连接）/ M5（推送）的**下游**。分三阶段（§8）：阶段 0 零服务端改动、只做前台可见的骨架用来验证 UI；真正的锁屏审批价值必须等推送基础设施。

---

## 1. 背景：灵动岛 / 实时活动是什么，为什么想结合

**实时活动（Live Activity，ActivityKit，iOS 16.1+）** 是一块由 app 声明、系统代管的锁屏 / 灵动岛卡片，用来展示"正在进行、会变化"的一件事——外卖到哪了、球赛比分、**agent 任务跑到哪了**。**灵动岛（Dynamic Island）** 是 Live Activity 在 iPhone 14 Pro 及以后机型上的紧凑 / 展开呈现形态。

对 codeg 的吸引力非常直接：codeg-ios 定位是 **coding agent 的远程驾驶舱**（见 `ios-redesign-plan.md` §0），用户核心诉求是「看进度、收审批」。一个 agent 任务可能跑几分钟到几十分钟，**Live Activity 的杀手场景 = app 关着、锁屏时也能瞥见"还在跑 / 跑完了 / 卡住等你批"**，尤其"等你批"——这正是 Codex mobile 的头条功能，也是 `ios-redesign-plan.md`（§1 对标 / §2.2 关键差距）点名为最大产品缺口的能力。

### 平台约束速查（决定后面所有判断）

| 约束 | 内容 | 对 codeg 的影响 |
|---|---|---|
| 需要 Widget Extension | Live Activity 的 UI 必须在一个独立的 Widget Extension target 里（当前工程只有单一 app target） | 新增 target + entitlements，见 §6 |
| ContentState 更新只有三条路径 | ① 本地 `Activity.update()` ② APNs `liveactivity` 推送 ③（辅助）后台刷新 | 见 §3 / §7 —— 这是全文核心矛盾 |
| 本地 update 仅进程存活时有效 | app 一被系统挂起，`Activity.update()` 就调不到 | 前台/短后台窗口以外，本地更新冻结 |
| APNs 才能在锁屏/挂起时更新 | 需 push token 上报 + p8 签名，`apns-push-type: liveactivity` | 自托管无此基础设施（§4） |
| 时长上限 | 活跃 ≤ 8h，系统 12h 后强制结束 | 长任务需处理"活动过期"降级 |
| 仅 14 Pro+ 有灵动岛 | 老机型 Live Activity 只在锁屏 / 横幅呈现 | UI 要两形态都成立 |
| 用户需授权 | 系统设置里可关闭 App 的实时活动 | 首启需引导 + 关闭态降级 |
| iOS 17+ 可 push-to-start | 连"启动"活动都能用推送触发（另需 start token） | 进一步依赖推送基础设施 |

---

## 2. 会话状态数据模型盘点（好消息的一半）

### 2.1 持久状态：`ConversationStatus`

`CodegiOS/Models/Conversation.swift:83-120`，承载于 `ConversationSummary.status`（`:144`，`var`，乐观更新）：

| case | wire | `label` | `tint` | `isLive` |
|---|---|---|---|---|
| `.inProgress` | `in_progress` | Running | 蓝 | ✅（`:115` 唯一 live 谓词） |
| `.pendingReview` | `pending_review` | Review | 琥珀 `Theme.warning` | — |
| `.completed` | `completed` | Done | 绿 | — |
| `.cancelled` | `cancelled` | Cancelled | 次级灰 | — |
| `.other` | `""` | — | 次级灰 | — |

`ActivityModel.running`（`Features/Activity/ActivityModel.swift:47`）= `conversations.filter { $0.status.isLive }`，已经是一份现成的"运行中会话"列表。

### 2.2 天然的 ContentState 源：`LiveSessionSnapshot`

`CodegiOS/Models/AcpEvent.swift:201-231` —— WS attach 时下发的整段快照，字段几乎就是为一块 Live Activity 卡片准备的：

```
connectionId, conversationId, folderId,
status: ConnectionStatus,          // connecting/connected/prompting/disconnected/error
liveMessage,                       // 当前流式回复
activeToolCalls: [ToolCallStateSnapshot],   // 正在跑哪个工具
pendingPermission, pendingQuestion,          // 是否卡在审批/提问
eventSeq
```

`reattachIfLive()` / `buildLiveTurn(from:)`（`SessionDetailViewModel.swift:1012`、`:1153-1194`）已经把事件流归约成这份快照——ContentState 的映射工作量很小。

### 2.3 「等待审批」——不是一个状态，是一层叠加态

**关键**：agent 卡在审批时，行状态仍然是 `.inProgress`（`SessionDetailViewModel.swift:318-321` 注释：status "set unconditionally when the turn starts and cleared only on TurnComplete, so it stays true for the whole turn, including while blocked on an ExitPlanMode confirmation"）。真正的 pending 态只活在：

- VM 上的 `pendingPermission` / `pendingQuestion`（`SessionDetailViewModel.swift:84` / `:86`），类型见 `Models/InteractiveRequests.swift`。
- 三种交互：**权限确认**（工具调用）、**AskUserQuestion**、**ExitPlanMode**（后两者也走 `permission_request` / `question_request` 事件，`AcpEvent.swift:46-172`）。

映射到 Live Activity 的价值排序：

| 呈现态 | 数据来源 | 价值 | app 级可见？ |
|---|---|---|---|
| Running（在跑） | `status.isLive` | 中 | ✅ 轮询可见 |
| **Waiting for approval（等你批）** | `pendingPermission`/`pendingQuestion` | **最高** | ❌ 仅打开的会话可见（见 §4） |
| Ready for review | `.pendingReview` | 高 | ✅ 轮询可见 |
| Done（完成） | `.turnComplete` / 轮询 | 高（完成提醒） | ✅ 轮询可见 |

---

## 3. 约束一：交付层的三道鸿沟

Live Activity 要在后台/锁屏发光，需要一个"app 不在前台也能拿到状态变化"的源。当前架构在后台是全黑的：

1. **活动轮询只在前台** —— `App/RootView.swift:62-65`，`.task(id: activityPulseID)` 里 `guard scenePhase == .active else { return }`；`activityPulseID`（`:73-77`）把 `scenePhase` 编进身份，25s 脉冲进后台即停、回前台重启。这是全 app **唯一**的前后台感知。
2. **实时 socket 随详情页开合** —— `EventStream` 是 `/ws/events` 连接（`Networking/EventStream.swift:73`），但由 `SessionDetailView` 的视图生命周期驱动：`.task { await model.load() }` 起、`.onDisappear { model.teardown() }` 灭；无前台重连、无后台任务。turn 结束即关。
3. **完全没有后台/推送能力** —— 全仓扫描零命中：无 `UIBackgroundModes`、无 `BGTaskScheduler` / `beginBackgroundTask`、无 `.entitlements`（无 `aps-environment`）、无 `ActivityKit` / `UNUserNotificationCenter` / `registerForRemoteNotifications`。

三条更新路径对现状：

| 路径 | 能否锁屏/挂起时更新 | 现状 |
|---|---|---|
| 本地 `Activity.update()` | ❌ 仅进程存活时 | 可立即做，但 app 开着时用户直接看 Activity tab 就行 —— **增量小** |
| APNs `liveactivity` push | ✅ 唯一可靠 | 需服务端存 token + p8 签名 —— **完全不存在** |
| `BGAppRefreshTask` 兜底 | ⚠️ 最短 ~15min、不保证 | 对 agent 秒级状态基本无用 |

---

## 4. 约束二：最高价值的「等待审批」态，在 app 级看不见

这是比"推送难交付"更深的一层，容易被忽略：

- 待审批**不是** `ConversationStatus` 的 case（§2.3）；行状态仍是 `.inProgress`。
- app 级的 `ActivityModel` 轮询只拿到 `ConversationSummary.status`（列表层），**区分不了"在跑"和"卡着等你批"**。
- 更关键：承载行状态翻转的 socket 事件 `conversation_status_changed`，在详情 VM 里是**显式 no-op** —— `SessionDetailViewModel.swift:1284`：`case .sessionStarted, .conversationStatusChanged, .userPromptSent, .unknown: break`。连"跑完了"这种翻转都只靠 25s 轮询反映，不走 socket。

**推论**：一块显示"等待审批"的 Live Activity，难点不止是"后台怎么推"，而是**连 app 级数据源都还不存在**。要让它成立，二选一：

- **(a) 服务端新增字段/事件**，把"某会话在等审批"提升到 list / 轮询层；或
- **(b) 一个 app 级 hub 订阅所有会话的 socket** —— 这正是 `ios-redesign-plan.md` §10.2 规划的 M4 `SessionHub`。

因此审批态的价值**必须**排在 M4（或服务端加字段）之后。阶段 0 里你只有**正打开着**某会话时才知道它在等审批——可那时审批卡已经糊在你脸上，Live Activity 零增量。

---

## 5. 约束三：「可操作」审批受 server 可达性约束

灵动岛最诱人的是展开态放 **Approve / Deny** 按钮（App Intent，锁屏直接批）。但两个价值受不同约束：

| 能力 | 靠什么 | 约束 |
|---|---|---|
| **看到** 状态变化 | APNs 推送 | server 只要能**出网**访问 `api.push.apple.com`，Apple 网关负责送达手机，不要求 server 直连手机 → ✅ 可解 |
| **发回** 审批（点按钮生效） | 手机直连 server 的 REST | 需手机能**连回** server：局域网本地 server + 人在外面 = 点了发不出去 → ❌ 仅公网可达 / 内网穿透 / 中继的 server 完整成立 |

即：Live Activity 的"可操作"这一半，天花板是 server 对手机的可达性，与推送是两个正交问题。对纯局域网部署，Live Activity 现实上退化为**只读监控**（看得到进度/完成，批不了）。

---

## 6. 好消息：地基比想象的近

抵消上面三条约束的，是几处已经就位的基础：

1. **传输层已会说持久协议** —— `EventStream` 就是 `/ws/events` firehose，已实现 attach/snapshot/replay：`WSClientMessage.attach(subscriptionId, connectionId, sinceSeq)`（`EventStream.swift:8-35`）、`WSServerMessage.snapshot/replay/event/detached`（`:40-69`）、`Frame` 枚举（`:78-86`）。M4 `SessionHub` 是"把它包成一条 app 级持久连接 + 加 `scenePhase` 生命周期"，**不是从零造协议**。
2. **ContentState 源现成** —— `LiveSessionSnapshot`（§2.2）+ `AcpEvent` 流已归约出 status / 活动工具 / 待审批标志 / token 用量。
3. **token 后台可读** —— `Keychain.swift:13,39`：service `com.codeg.ios.server-token`，`kSecAttrAccessibleAfterFirstUnlock`（首次解锁后后台可读，正是扩展所需）。**但**：keychain sharing（access group）当前**未配置**（无 entitlements）——扩展要读 token，需加 App Group + keychain 共享组。
4. **平台就绪** —— 部署目标 iOS 18（`project.yml:5,40`），所规划的 ActivityKit 能力均可用。
5. **深链已就位** —— `codeg://`（`CFBundleURLTypes`）+ `Route` 枚举，Live Activity 点击回 app 落到 `Route.conversation(id)` 是现成的。

### 需要新增的工程要件（落地清单）

- [ ] Widget Extension target（含 `ActivityAttributes` + `ActivityConfiguration` UI）
- [ ] `NSSupportsLiveActivities = YES`（Info.plist）
- [ ] App Group + Keychain Sharing entitlement（让扩展读 token / 共享 server 配置）
- [ ] `ActivityAttributes` / `ContentState` 类型（放共享 framework 或 App Group 可见处）
- [ ] 阶段 2：push token 上报 REST + 服务端（或中继）APNs 签名发送

---

## 7. 更新路径可行性矩阵

| 方案 | 锁屏更新 | 服务端改动 | 自托管友好 | 解锁的价值 | 结论 |
|---|---|---|---|---|---|
| **A. 本地 update（前台）** | ❌ | 无 | ✅ | 仅前台可见的骨架验证 | 阶段 0 做 |
| **B. APNs 直连（server 自签）** | ✅ | 大（存 token + p8 签名） | ❌ 每台 server 配证书 | 锁屏完整体验 | 分发地狱 |
| **C. 轻量云中继** | ✅ | 中（server webhook 出事件） | ✅ 中继持凭证 | 锁屏完整体验，绕开每台配证书 | **推荐折中** |
| **D. BGAppRefresh** | ⚠️ ~15min | 无 | ✅ | 很久没更新时补一刀 | 仅兜底，非主路径 |

方案 C 与 `ios-redesign-plan.md` §11-B⑥ 的判断一致：「自托管场景 APNs 不易……备选 ntfy/webhook → 本地中继」。一个持有 APNs 凭证的小云服务，自托管 server 只需 webhook 出事件即可，既绕开"每台 server 配 p8"的分发地狱，又不牺牲锁屏推送。

---

## 8. 建议路线（对齐 M4 / M5）

Live Activity 是 M4（持久连接）/ M5（推送）的**下游**，不应提前单独上——否则是空壳。分三阶段：

### 阶段 0 · 骨架验证（零服务端依赖）
- 新增 Widget Extension + `ActivityAttributes` / `ContentState`，用**本地 `Activity.update()`** 在前台（+ 短后台窗口）驱动。
- 覆盖 **running / done / review** 三态（它们在轮询层可见）；**不做审批态**（§4：数据源还不存在）。
- 目的：验证紧凑/展开态布局、灵动岛两形态、点击深链回 app、ContentState 映射手感、关闭态降级。
- 起活动的时机：`ActivityModel.running` 新增一个会话时 `Activity.request(...)`；轮询刷新时 `update(...)`；跑完 `end(...)`。
- 成本：低、可回归、无服务端确认项。

### 阶段 1 · 依赖 M4 `SessionHub`
- 先有 app 级持久 socket（§6 已述：传输层已就位），才谈得上"所有会话的实时状态"喂给 Live Activity，而非只有前台打开的那个。
- 此时审批态（`pendingPermission` / `pendingQuestion`）才有 app 级来源。
- `scenePhase` 生命周期（background 关 socket 留内存、foreground `attach(sinceSeq:)` 续传）按 §10.2 规划。

### 阶段 2 · 依赖推送基础设施（M5）
- push token 上报 + 服务端 / **中继**（方案 C）APNs `liveactivity` 推送 → 解锁锁屏审批提醒。
- 交互按钮（Approve/Deny）落地时，注意 §5 的可达性约束：对纯局域网 server 明确降级为只读，或提示"需回到可达网络"。
- 与 `ios-redesign-plan.md` §12 一致：M5 明确把「推送 … Live Activity（可选）」列在推送之后。

---

## 9. ContentState / UI 设计草案

### 数据结构（草案）

```swift
struct CodegSessionActivityAttributes: ActivityAttributes {
    // 静态（活动生命周期内不变）
    let conversationId: Int
    let serverId: String        // 深链 + 扩展读 token 定位
    let folderName: String
    let agentKind: String       // 头像/品牌图标

    struct ContentState: Codable, Hashable {
        enum Phase: Codable { case running, waitingApproval, review, done, cancelled }
        var phase: Phase
        var activeToolTitle: String?   // "Editing RootView.swift" 等，来自 activeToolCalls
        var summaryLine: String?       // liveMessage 尾巴/最新工具
        var pendingApprovalKind: String?  // permission / question / plan（阶段 1+）
        var tokensUsed: Int?
        var updatedAt: Date
    }
}
```

映射来源：`Phase` ← `ConversationStatus` + `pendingPermission/Question`；`activeToolTitle` ← `LiveSessionSnapshot.activeToolCalls`；`summaryLine` ← `liveMessage`。

### 呈现（草案）

- **灵动岛紧凑态**：leading = agent 头像 + 状态点（复用 `ConversationStatus.tint`）；trailing = 相位图标（跑动画 / ⏸ 等批 / ✓ 完成）。
- **灵动岛展开态**：会话标题 + 文件夹；状态行 `activeToolTitle`；等批时 Approve / Deny（App Intent，阶段 2，附 §5 可达性降级）。
- **锁屏卡片**：同展开态，老机型主形态。
- **点击**：深链 `codeg://conversation/<id>` → `Route.conversation`（见 §6，已就位）。

---

## 10. 关键文件索引（供实现者）

| 关注点 | 文件:行 |
|---|---|
| 持久状态枚举 | `Models/Conversation.swift:83-120`（`isLive` `:115`，`ConversationSummary.status` `:144`） |
| in-flight 液体信号 | `Models/Conversation.swift:186-191`（`inFlightUserTurnId` `:190`） |
| ContentState 源 | `Models/AcpEvent.swift:201-231`（`LiveSessionSnapshot`） |
| 事件枚举 | `Models/AcpEvent.swift:46-172`（`AcpEvent`），`EventEnvelope` `:177-190` |
| attach 协议 / 传输 | `Networking/EventStream.swift:8-35`（client msg）`:40-69`（server msg）`:73-86`（`EventStream`/`Frame`） |
| app 级轮询源 | `Features/Activity/ActivityModel.swift:47`（`running`）`:169-178`（`autoRefresh` 25s） |
| 前后台门控 | `App/RootView.swift:62-65`、`:73-77`（`activityPulseID`） |
| 审批 / 提问态 | `SessionDetailViewModel.swift:84`/`:86`；`Models/InteractiveRequests.swift` |
| status_changed no-op | `SessionDetailViewModel.swift:1284` |
| reattach / 重建 | `SessionDetailViewModel.swift:1012`（`reattachIfLive`）`:1153-1194`（重建 + 恢复 pending） |
| token 存储 | `Persistence/Keychain.swift:13`（service）`:39`（`AccessibleAfterFirstUnlock`） |
| server 配置 | `Persistence/ServerStore.swift`、`Models/ServerProfile.swift` |
| 深链 / 路由 | `App/Route.swift`、`project.yml`（`CFBundleURLTypes`） |
| M4 Hub / 推送规划 | `docs/ios-redesign-plan.md` §10.2、§11-B⑥、§12（M4/M5）、§14 |

---

## 11. 风险与开放问题

1. **审批推送真正生效需 server 可达（§5）**：纯局域网部署下"可操作"这半天花板受限——产品上要么明确降级只读，要么引导用户配公网可达 / 中继。
2. **自托管 APNs 分发**：方案 B（每台 server 配 p8）不现实；方案 C（中继）需要一处 Anthropic/官方运营的云组件，涉及成本与信任边界。
3. **活动过期降级**：长任务超 8h / 12h，系统结束活动——需要"活动已过期，回 app 查看"的落地体验。
4. **扩展读 token**：需加 App Group + Keychain Sharing entitlement；且模拟器走 UserDefaults 回退、真机走 Keychain，扩展侧要走 Keychain。
5. **多会话并发**：同时多个 running 会话——是一活动多会话滚动，还是每会话一活动（系统有并发活动数量上限）？需产品定义。
6. **`conversation_status_changed` 当前 no-op**：即便有了 hub，也要把这个事件真正接上，否则状态翻转仍只靠轮询。
7. **电量 / 网络**：持久连接（M4）+ 推送对自托管 server 的常驻要求，需评估用户预期。

---

## 12. 本期 Non-goals

- 不在 M4 之前单独上 Live Activity（会是无实时源的空壳）。
- 不做每台自托管 server 各配 APNs 证书的方案 B。
- 阶段 0 不做审批态（数据源不存在）、不做交互按钮（依赖推送 + 可达性）。
- 不覆盖 watchOS / 桌面 Widget（与 `ios-redesign-plan.md` §14 一致）。

---

## 附：与现有重构方案的关系

本文是 `ios-redesign-plan.md` 中 **M5「Live Activity（可选）」** 的展开评估，结论与其 §11-B⑥、§12、§14 一致并细化：Live Activity 的**数据形态已就绪、审批态需 M4 数据源、锁屏价值需 M5 推送**，因此定位为 M4/M5 下游、可分阶段增量落地的可选增强。
