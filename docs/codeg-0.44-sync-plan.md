# 会话逻辑同步 codeg 0.44.0 方案

> v1.0 · 2026-11-14 · 基线：iOS 上次对齐到 codeg `f3e7ae97`（≈ v0.25.0~16，2026-08 中）；目标：codeg `v0.44.0`（2026-11-13）。两者之间 1918 个提交，会话相关约 743 个。
>
> 本文件是阶段性蓝本；每阶段落地后在 §6 勾选并补「实际做法与偏差」。

---

## 0. 一页纸结论

- **线格式没有大的破坏**：WS attach 协议（`ws.rs` / `ws_attach.rs`）两版逐字节相同，`acp_connect` / `acp_prompt` / `acp_find_connection_for_conversation` 形状不变，新增字段都是可选的——iOS 不会解码崩溃。
- **真正的风险是服务端行为变了**：回合中途会发**非致命 `error`**、失败的回合以新的 **`turn_error` 块**落库、断线重连期间的内容 iOS 补不回来。这几处会让 iOS 丢回复或卡在「回复中」。→ **阶段一**。
- **web 时间线换了范式**：每个工具一张卡 → **每轮回复一条可折叠的 activity 时间线**（`src/lib/activity/**` 约 5k 行纯逻辑 + 测试）。这是同步的主体工作。→ **阶段二**。
- **交互功能**：权限/提问卡新字段、失败与重试提示条、回合中发消息（队列 + steering）。→ **阶段三**。
- 其余（fork、消息导航器、live runs、@ 面板、富内容）按需。→ **阶段四**。

---

## 1. 阶段一：正确性修复

| # | codeg 变化 | iOS 现状 | 改法 | 规模 |
|---|---|---|---|---|
| 1.1 | `error` 事件带一组「回合继续」code：`image_dropped`、`compaction_failed`、`set_mode_failed`、`set_config_option_failed`、`goal_control_failed`、`session_load_fallback`、`grok_model_switch_incompatible_agent`（`connection.rs:4668-4685`，`3b47d1f5d`）。web 只把 `turn_failed_*` 与**不带 code** 的错误当回合结束（`acp-error-presentation.ts:46-92`） | `SessionDetailViewModel` 收到任何 `.error` 都 `failLive`：关流、标红，后续回复丢失 | 按 code 分流：非致命 → 提示，不动 live turn/stream；其余照旧 | S |
| 1.2 | `QuestionSpec.allow_other`（`question.rs:104`，缺省 true，`de8ac404b`）；Antigravity / Pi 原生桥只收选项 id | `QuestionSpec` 无此字段，总显示 Other；`is_secret`（基线前就有）也未遮挡 | 解码 `allowOther`，false 时隐藏 Other；`is_secret` 用 `SecureField` | S |
| 1.3 | 新 ContentBlock `turn_error{message}`（`models/message.rs:215`，`8b95fc1c9`）：失败回合以一个只含它的 `system` turn 结尾；web `parseHoldsTheLatestRound` 规定转录以 turn_error 结尾时仅当本地这一轮也失败才算「已持有最新一轮」 | 解成 `.unknown`，时间线整轮跳过；`transcriptHasReply` 要求以 assistant 结尾 → 白白重试 5 次再 promote | `ContentBlock.turnError`；时间线画一行失败说明；reconcile 判据按 web 规则接受 | M |
| 1.4 | web 修了断线重连两种情况（`23831d93b`、`1e3e5a108`）：断线期间回合结束 → 重拉转录；`since_seq` replay 补帧 | `sinceSeq` 有定义从未传；重连 snapshot 只恢复权限卡，不看 `status` / `live_message` → 断线期间 delta 丢失，回合在断线期间结束则 Stop 永远亮着 | 记 `lastSeq`，重连带 `since_seq`；snapshot 非 prompting 且本地仍活跃 → 按 finalize 处理 | M |
| 1.5 | `acp_fetch_kimi_models` 路由已删除 | Agents 设置仍在调用 → 404 | 查上游替代后移除/改调 | S |

**验证**：1.1 / 1.4 用 live WS mock（见 memory `codeg-0.23-adaptation`：客户端要先收到 `__ready__`），每个场景都跑「撤掉 fix」的反事实。

---

## 2. 阶段二：时间线迁移到 web activity 模型

web 在 `f33285012`（2026-10-22）→ `70b3b389f` → `ce374de4c` 把工具卡换成 activity 时间线。

### 2.1 web 的做法（摘要）

- **管线**：`adaptMessageTurn`（`ai-elements-adapter.ts`）配对 tool_use/result → `normalizeToolName`（`tool-call-normalization.ts`：精确别名表 → codex 标题形状 → canonical 精确匹配 → 后缀规则 → 最后才启发式；live 另有 `inferLiveToolName`）→ `toolStepKind` 精确 switch（30 种）→ `describeToolCall` 产出 `ToolDescriptor` → `buildActivity` 产出 `ActivityModel{steps, items, answer, summary}`。
- **分组**（`group.ts`）：只有同家族（explore / command）连续 ≥2 个才成组；失败不打断分组；组 key = 首成员 key。
- **整轮折叠**（`completed-turn-content.tsx`）：最后一个过程 part 之后的 text / plan / image / turn-error 是「答案」常驻显示，之前的折进摘要头；`foldable = progress 非空 && (未完成 || 有可见答案)`；可能仍在跑的 delegation/agent/background 在折叠后仍显示。当前轮折叠状态**按位置**持有（id 在 live→promoted→refetch 中变两次），每次发送 epoch+1 收起上面所有轮。
- **摘要头**：`Working|Activity|Reply · N steps · N failed（可跳转）/ N failed, recovered · N interrupted · 耗时`；「已恢复」= 同签名后来成功。
- **思考**：单独成行，`thoughtTitle` 取标题（流式取最新、完成取第一个、否则首句，60 字），默认折叠。
- **命令退出码**（`exit-meaning.ts`）：grep 无匹配、`test` false、`diff` differs、`which`/ENOENT notFound 等判为「答案」而非失败；127/126/124/128+n 映射。
- **改动摘要**（`edit.ts`）：4 种 payload → `Edited <path> L44–46 +3 −1`。
- **状态 7 种**：pending/running/awaiting/succeeded/failed/rejected/cancelled。
- **单轮窗口化**：items > 100 才启用（iOS `List` 已回收，暂不需要）。

### 2.2 与 iOS 的冲突点

| 项 | iOS | web |
|---|---|---|
| 分类优先级 | ACP `kind` 优先（`ToolDerive.bucket`） | 名字优先 |
| 分组 | 任意相邻非 task 工具混组 | 只 explore / command 家族 |
| 整轮折叠 / 摘要头 | 无 | 有 |
| 状态 | 4 种 | 7 种 |
| `exit_code` | 不解码 | 驱动 exitMeaning |
| TaskCreate/Update | iOS 独有演进清单 | 普通 todo 行 |

### 2.3 分步

1. **单元测试 target**（S）：`project.yml` 加 `CodegiOSTests`，把 web `src/lib/activity/*.test.ts` 与 `__fixtures__` 翻成 XCTest。
2. **纯逻辑移植**（L，约 3–4k 行）到 `Features/SessionDetail/Activity/`：`ActivityTypes`、`ToolNameNormalizer`、`DescribeToolCall`、`CommandParse`、`ExitMeaning`、`EditDescribe`、`ExploreSummary`、`ThoughtTitle`、`ActivityStatus`、`ActivityGroup`、`ActivitySummarize`、`BuildActivity`。
3. **接入时间线**（M）：`TimelineNode.Content` 增 `replyHeader` / `activityGroup` / `step` / `foot`；折叠作为 persisted memo **之后**的廉价过滤（不破坏双层 memo）；live 层仍不 memo 视图节点；展开状态移到按 step key 的 `DisclosureStore`（顺带修 cell 回收丢展开态）。
4. **行视图**（M），之后删除 `ToolGroupCard`、`groupConsecutiveTools`、`ToolKindBucket` 等。
5. **特殊行收口**（S–M）：delegation / ask / Grok 子 agent 套 hosted-row 外壳；background-tasks 通道。

### 2.4 风险

- 分类翻转会重新碰到修过的特例（codex `List files` 的 kind=read、Antigravity live 标题即命令）：逐条回放 memory `tool-mcp-rendering` / `companion-tool-cards` 的反例，坚持精确名匹配。
- live 层每帧重算描述很贵：按「tool id + 内容签名」做 step 级复用，否则长会话流式卡顿回归。复用缓存**不能按 turn id 键**（codeg turn id 非全局唯一）。
- 保留 iOS 独有：TaskCreate 演进清单（作 todo 特例）、`ToolLiveness` 三态、`suppressInFlight`。

---

## 3. 阶段三：交互功能

| 项 | 内容 | 规模 |
|---|---|---|
| 权限卡 | `_meta.permission.description` → reason、`_meta.permission.title` 标题后备、`defaultToNo`（强调拒绝）、`networkHost` | S |
| 提问卡 | 可折叠成标题行；新问题或提交失败时自动展开 | S |
| 选项按钮 | 按钮显示当前模型/强度/模式；模型列表 `searchable` | S |
| Codex `<proposed_plan>` | 行首且不在代码块内才抽成计划卡 | M |
| 失败/重试提示条 | `session_failure`（按 id 合并、只收更高 revision、warning 在干净 end_turn 后解决）、`turn_retrying{attempt,max_retries,retry_delay_ms}`、`session_load_failed` 新 code；被拒 prompt 去 "ACP protocol error:" 前缀；`conversation moved` → 重拉 summary/folder 后重试 | M |
| 回合中发消息 | 先本地队列（finalize+reconcile 后自动发下一条，409 退回队头）；再 steering：`submit_session_feedback{connectionId,text,blocks?}`，按 snapshot `feedback_tool_available \|\| native_steering_available` 决定；`feedback_submitted{delivered}` 时在 live 中切开回复 | L |

---

## 4. 阶段四：按需

从指定 turn fork（`acp_fork{forkFromTurnId}`，fork 点用 `agent_message_id`）、消息导航器（`get_folder_conversation_outline`）、live runs 芯片 + `acp_stop_async_task`、`prompt_suggestion`、斜杠菜单 skills、@ 面板、Markdown 图片 / 任务复选框、Mermaid / HTML / json-render。

---

## 5. 未验证 / 待定

- codex/claude 走 AIR 时终态失败是否只通过 `session_failure` 上报（决定 1.3 是否一并解码它）。
- `allow_other=false` 时提交自由文本的服务端表现。
- Claude `/clear` 后 `external_id` 改指向（`TranscriptRolledOver`），iOS re-anchor 能否自然吸收。
- 待用户确认：TaskCreate 清单保留（建议保留）；新增单元测试 target。

---

## 6. 进度

- [x] 阶段一 1.1 非致命 error
- [x] 阶段一 1.2 allow_other / is_secret
- [x] 阶段一 1.3 turn_error
- [x] 阶段一 1.4 重连补帧 / 断线期间结束
- [x] 阶段一 1.5 kimi models 路由

### 阶段一实际做法与偏差（2026-11-14）

- **1.1**：分流逻辑在 `Models/AcpErrorRoute.swift`（照搬 web `acp-error-presentation.ts`）。与原方案的偏差：回合失败类错误**不再立即关流**，只记在 live turn 上（agent 原话优先于 codeg 判定），等 `turn_complete` 正常收尾并对账——和 web 的 `TURN_FAILED` 一致。核对过后端所有发 `error` 的位置：失败判定之后必有 `turn_complete`，进程死亡则必有 `status_changed: error`（此时用记下的错误文案而不是笼统的 "connection errored"）。被拒 prompt 去掉 `ACP protocol error:` 前缀（原属 P1-3，顺手做了）。
- **1.2**：无选项的问题直接显示输入框，不再需要先点 Other。
- **1.3**：持久化的 `turn_error` 复用直播的 `.error` 节点；回合被折叠进 `turns` 时失败原因作为 `.turnError` 块保留（本地 "Cancelled." 占位不算）。
- **1.4**：snapshot 的 `event_seq` 在**帧上**而不在 snapshot 体内（之前 iOS 解码的位置一直是 nil）。「服务端已开始本轮」的证据只认 `status_changed: prompting` / `user_message` 以及重连时 `prompting` 的 snapshot——回合之间也会有迟到的 update，不能作数。重连 snapshot 的 `last_error` 记录的是**任意**最近错误，恢复时也走同一套分流，不要求带 details。viewer 路径同样修了「断线期间结束 → 一直显示流式中」。
- **1.5**：改走 `list_provider_models`（`{params:{protocol, baseUrl, keySource:{kind:"inline", apiKey}}}`）；空 baseUrl 用 SDK 默认地址；vertexai 无 key 不可拉取。**未对真实服务端验证**（本机 desktop 未运行）。
- **验证**：模拟器上真实 VM 对 live WS mock 跑 9 个场景，每个都跑了「只关掉对应修复」的反事实，均复现原 bug；Codex 审查两轮（第一轮 3 个 Important 全部属实已修，第二轮 APPROVED）。
- [x] 阶段二（主体）
- [ ] 阶段三
- [ ] 阶段四

### 阶段二实际做法与偏差（2026-11-14）

- **逻辑层**：`Features/SessionDetail/Activity/` 移植了 `src/lib/activity/**` 全部模块 + `tool-call-normalization.ts`（归一化做过约 18 万组输入的 Swift/JS 差分对比，0 差异）。web 的测试逐条移植进新加的 `CodegiOSTests`（Swift Testing），共 350 个测试。JS 语义（UTF-16、正则 `^$`/`\s`/`\b`、对象插入顺序、布尔不是数字）在各模块里显式复刻；对象键顺序从源 JSON 文本恢复。
- **接入**：`TranscriptTimeline.replyNodes` 把每轮回复画成「头部胶囊 → activity 行 → 收起 → 答案 → footer」；折叠状态 `ReplyFoldStore`（VM 持有，照搬 web `ReplyFoldState`：当前轮按位置、发送时 epoch+1、新打开的会话全部折叠）在**缓存之后**由 `ReplyFolding.apply` 过滤，不让持久化层的 memo 失效。直播回复展开时答案留在 rail 上，折叠时答案常驻。
- **行视图**：普通工具一行（动词 + 目标 + 细节 + 右侧数字/状态），展开复用 `ToolCallBody`；explore/command 分组行；思考行（自动标题）。委派/提问/子 agent/plan-mode 保留原有专用卡片。中英文案含复数变体。
- **直播工具名**：直播调用现在用 `inferLiveToolName` 推断工具名（之前直接用 ACP 原始 title）。`ToolCallVM.toolName` 只供 activity 层用，旧卡片仍读 `rawName`。
- **刻意偏差**：结束后既无步骤又无耗时的回复不画「Reply」头部（手机上省一行）；轮询行只在自身运行时折叠常驻（委派行用 broker 终态代表子任务）。
- **未移植**：opencode code-mode 委派判定、恢复委派被拒绝的判定、后台任务（`TaskOutput`）分组、goal 运行、proposed-plan、单轮超长时的行窗口化（`List` 已回收）。
- **验证**：模拟器对 mock 截图（折叠/展开的历史回复、中文、直播中的回复）；Codex 审查三轮（2 个 Important + 1 个遗留全部修复，第三轮 APPROVED），对应集成测试在 `TimelineFoldingTests`。

### 阶段三实际做法与偏差（2026-11-14，进行中）

已提交到 `main`：失败/重试提示条（a698d99）、提问卡折叠（7d0abbd）。其余四项在 `phase3-integration` 分支上各一个提交，**尚未一起编译和跑测试**（磁盘/内存紧张，构建暂停），验证通过后再快进 `main`。

- **失败/重试提示条**：`Models/SessionFailures.swift` 照搬 web `session-failures.ts`（按 id 单调合并、同 revision 只能 resolved false→true、三种 settle 范围、dismissed≠recovered）。composer 上方只画「进行中」的事：重试行（Claude `system/api_retry` 与 `turn_retrying` 共用，任何输出/离开 prompting/关流即清）、一条 AIR 事件条 +N、自愈后 10 秒自动消失的「已恢复」。终态记录走 TURN_FAILED，提示类走 notice。
- **权限卡**：reason 取 `_meta.permission.description`；标题先 `_meta.claudeCode.title` 后 `_meta.permission.title`，标题等于命令时换回模型自己的 `rawInput.description`；`defaultToNo: true`（严格的布尔 true）把实心按钮让给拒绝；Claude 沙箱网络请求按 host 呈现——请求本身不带工具名，靠 live 调用合并（web `mergePermissionToolCallWithLiveInfo`，含调用晚于请求到达的情况、被剥掉的 Edit 文本回填）。
- **选项按钮**：按钮显示模型/强度/模式摘要；只读 live snapshot 或已有目录，**从不为摘要起 probe agent**。超过阈值的列表推到可搜索子页，模型按 `provider/` 分组，标出 `recommended_value`。
- **`<proposed_plan>`**：`Activity/ProposedPlan.swift` 逐条照搬 web 规则（行首、≤3 列缩进、不在围栏/行内代码中；未闭合时流式中为「规划中…」卡）。直播文本在自身叶子视图里拆，不让整条时间线订阅每个 token。
- **回合中发消息**：
  - 队列在 VM（`MessageQueue`）：回合中或队列非空时发送进队尾；空闲时逐条发；409 退回（队头回队头、composer 的进队尾）+1 秒退避；其它失败把队列**暂停**（web 是丢弃不重试，iOS 改为保留并要用户「立即发送」，免得排队的消息丢失）。Stop 后先等一个退避再发。turn 死掉（failLive）也暂停。
  - steering：长按回合中的发送按钮 →「插入当前回合」（native）/「发送留言」（pull），文字为准，有图片时只能排队（iOS 不发 `blocks`）。native 的 `feedback_submitted{delivered}` 在 live 中插入 `.steering` 段，时间线和折叠副本都在此切成「回复 → 用户消息 → 回复」。握手 snapshot 的留言属于上一轮，不采用；`user_message` 清空。
  - 已知局限：离开会话页面后队列随 VM 丢失（web 关 tab 同样）；对方客户端长时间占用回合时每秒重试一次（web 同样）。

