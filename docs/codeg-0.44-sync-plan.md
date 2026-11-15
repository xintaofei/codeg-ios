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

### 4.1 调研结论（2026-11-14）

| 项 | 线格式 / 后端 | web 做法 | iOS 现状 → 做法 | 规模 |
|---|---|---|---|---|
| fork | `POST acp_fork {connectionId, conversationId, folderId, forkFromTurnId}` → **camelCase** `{forkedSessionId, originalSessionId, siblingConversationId}`；409 `turn_in_progress`，其余 500。`forkFromTurnId` 是该回复**最后一个** assistant turn 的 codeg id（服务端自己查 `agent_message_id`，iOS 不需解码）；解析不了 fork 点时**静默 fork 到末尾**（只有 claude/codex/deepseek 支持定点） | 每条完成回复的 footer 有「从这里 fork」；**当前会话被截到 fork 点并改名 `[Fork] …`**，原完整历史成了新的兄弟会话；留在当前会话 | 无。footer 的 merged turn 取的是**第一个** turn id，要改成最后一个；`summary.externalId` 必须随 fork 刷新（否则重连恢复的是兄弟会话的 session）。闲置会话要先起连接。加确认框（结果反直觉）+「打开原会话」 | M |
| 消息导航 | `POST get_folder_conversation_outline {conversationId, beforeIndex}` → `{turns, turns_total, prefix_hash}`（窗口以上**全部**、精简过的 turns，不分页）；detail/page 新字段 `user_turns_before_offset`（缺省 = 服务端无此路由，0.36 起） | 侧栏每条用户消息一行（序号、首行、时间、+/− 行数、文件/子 agent 数）；点击跳转，窗口外的先 `loadOlderTurnsThrough` 再跳 | 无。「…」菜单 →「消息」sheet；outline 用「锚点 = window 的 offset+prefixHash」校验（不移植 JS 指纹）；跳转要把 VM 窗口和 `TranscriptView` 本地窗口都放到目标处再 `scrollTo` | M（全量 parity L） |
| live runs + 停止 | 事件 `async_task{delta}`、`background_activity{outstanding_tasks}`、`delegation_started/completed/child_running`；snapshot `async_tasks`/`background_outstanding_tasks`/`delegated_children`/`active_delegations`；`POST acp_stop_async_task {connectionId, taskId}` → 裸 bool | composer 上方「N 运行中」芯片 → 分组弹层（后台任务可 Stop / 后台子 agent / 委派）；回合结束后仍在 | **iOS 回合结束就关 WS**，看不到回合外的任何东西 → 需要**空闲连接观察者**（屏幕可见、有连接、无回合流时 attach，回合流开时让位，`since_seq` 重连）。移植 `async-tasks.ts` / `live-runs.ts` + 测试 | L |
| `prompt_suggestion` | 事件 `{type:"prompt_suggestion", text|null}`、snapshot `prompt_suggestion`；只 Claude/Codex；**在 `turn_complete` 之后**才到；`prompting` 清除 | 空输入框的 placeholder「{建议}（Tab 使用）」，Tab 填入不发送 | 依赖上面的观察者。placeholder + 框内「使用」按钮 + 硬件 Tab | S（有观察者时） |
| `/` 菜单 + skills | 命令来自连接（snapshot / `available_commands` 事件 / 草稿 probe），`skill`/`skill_path` 字段；codex/opencode/antigravity/custom 另扫磁盘 `acp_list_agent_runtime_skills {agentType, workspacePath}`（codex 用 `$`）；prompt 里就是纯文本 `/name ` / `$name ` | caret 前 `(^|\s)([/$])(\S*)$` 触发内联弹层，`rankByTextMatch` 排序 | 只有「+」→ sheet；`$` 命令被插成 `/$x`（bug）；仍按已删的 `expertIdSet` 过滤。用 iOS 26 `TextField(selection:)` 拿 caret，输入框上方建议卡 | M |
| @ 面板 | 文件 `POST search_workspace_files {path, query, limit, request:{consumerId, generation}}`（0.43 起，generation 单调，冷索引很慢）；prompt 里是**纯文本 Markdown 链接** `[README.md](file:///abs/…)`、`[@Codex](codeg://agent/codex)`（后端据此路由委派） | 五个 tab（agent/assistant/file/session/commit），顺序可配置（本机） | 无。输入框里显示 `@relpath`，VM 记 token 表，发送/插入/排队时编码成 web 同款链接，放回时解码 | M（files+agents）/ L（全部） |
| Markdown 图片 | `POST read_workspace_file_base64 {rootPath, path, maxBytes}` / `read_file_base64 {path, maxBytes}` → 裸 base64 字符串；上限 8 MiB；本地路径规则 `localImagePath`/`resolveLocalImage` | 本地图读文件夹内（越界走绝对路径），远程只放 http(s)，**不缓存字节** | 只显示 alt 文本。parser 加 image 块 + 加载器（并发 4、合并在途）+ 全屏查看；SVG 先回退文字 | M |
| 任务复选框 | — | `- [ ]`/`- [x]` 替换项目符号，只读 | 显示成 `• [ ] foo` | S |
| Mermaid | 纯前端（mermaid 11.17.2） | 流式重画、失败保留上次结果、缩放/导出 | 代码块。方案：**共享离屏 WebKit + 打包 mermaid.min.js（~3.6 MB，压缩 ~1 MB，离线）**，渲染成静态图，全屏可缩放；围栏闭合后才渲染（parser 需 `closed` 标志） | M |
| HTML 预览 | 纯前端；**默认关**（外观设置） | ```html 围栏 + 原始 HTML 块，iframe `allow-scripts` + 严格 CSP + 清洗 | 代码块。方案：可选设置默认关，只做闭合的 html 围栏，WebKit 禁 JS + 屏蔽网络，内联快照 + 全屏 | M |
| json-render | 纯前端；```spec 围栏的 JSONL（RFC 6902 patch 建 `{root, elements, state}`），43 个组件（shadcn + 7 种图表）；**无开关**——用户给 agent 开了 `ui-render` skill 就会输出 | — | 原样显示 JSONL。方案：**原生 SwiftUI 解释器**（Swift Charts），分期：0 = 折叠卡片；1 = 展示组件 + 图表 + 只读 state；2 = 表单/动作 | L |

### 4.2 做法与顺序

- **第一波（并行写代码）**：① fork + 消息导航；② `/` 菜单 + @ 面板（文件 + agent）；③ 空闲连接观察者 + live runs + `prompt_suggestion`；④ Markdown 图片 + 任务复选框 + 围栏 `closed` 标志 + json-render 第 0 期（折叠卡）。
- **第二波**：Mermaid、HTML 预览、json-render 第 1 期（依赖 ④ 的 `closed` 标志与图片加载器）。
- **刻意不做 / 推后**：PlantUML；@ 面板的 assistant/session/commit tab 与 tab 偏好设置页；导航器里的内联 diff、子 agent 行、视口当前消息高亮；live runs 的委派行跳转子会话与「等待中」琥珀点；json-render 第 2 期（表单、动作、浮层）；`ui-render` skill 的设置开关。

## 5. 未验证 / 待定

- codex/claude 走 AIR 时终态失败是否只通过 `session_failure` 上报（决定 1.3 是否一并解码它）。
- `allow_other=false` 时提交自由文本的服务端表现。
- Claude `/clear` 后 `external_id` 改指向（`TranscriptRolledOver`），iOS re-anchor 能否自然吸收。
- ~~待用户确认：TaskCreate 清单保留（建议保留）；新增单元测试 target。~~ 均已按建议落地（清单保留，`CodegiOSTests` 已加）。

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
- [x] 阶段三
- [x] 阶段四（json-render 第 1 期按用户决定暂不做，保留折叠卡；PlantUML 不做）

### 阶段二实际做法与偏差（2026-11-14）

- **逻辑层**：`Features/SessionDetail/Activity/` 移植了 `src/lib/activity/**` 全部模块 + `tool-call-normalization.ts`（归一化做过约 18 万组输入的 Swift/JS 差分对比，0 差异）。web 的测试逐条移植进新加的 `CodegiOSTests`（Swift Testing），共 350 个测试。JS 语义（UTF-16、正则 `^$`/`\s`/`\b`、对象插入顺序、布尔不是数字）在各模块里显式复刻；对象键顺序从源 JSON 文本恢复。
- **接入**：`TranscriptTimeline.replyNodes` 把每轮回复画成「头部胶囊 → activity 行 → 收起 → 答案 → footer」；折叠状态 `ReplyFoldStore`（VM 持有，照搬 web `ReplyFoldState`：当前轮按位置、发送时 epoch+1、新打开的会话全部折叠）在**缓存之后**由 `ReplyFolding.apply` 过滤，不让持久化层的 memo 失效。直播回复展开时答案留在 rail 上，折叠时答案常驻。
- **行视图**：普通工具一行（动词 + 目标 + 细节 + 右侧数字/状态），展开复用 `ToolCallBody`；explore/command 分组行；思考行（自动标题）。委派/提问/子 agent/plan-mode 保留原有专用卡片。中英文案含复数变体。
- **直播工具名**：直播调用现在用 `inferLiveToolName` 推断工具名（之前直接用 ACP 原始 title）。`ToolCallVM.toolName` 只供 activity 层用，旧卡片仍读 `rawName`。
- **刻意偏差**：结束后既无步骤又无耗时的回复不画「Reply」头部（手机上省一行）；轮询行只在自身运行时折叠常驻（委派行用 broker 终态代表子任务）。
- **未移植**：opencode code-mode 委派判定、恢复委派被拒绝的判定、后台任务（`TaskOutput`）分组、goal 运行、proposed-plan、单轮超长时的行窗口化（`List` 已回收）。前四项已在「遗留补齐」中补上，proposed-plan 在阶段三；行窗口化仍不做。
- **验证**：模拟器对 mock 截图（折叠/展开的历史回复、中文、直播中的回复）；Codex 审查三轮（2 个 Important + 1 个遗留全部修复，第三轮 APPROVED），对应集成测试在 `TimelineFoldingTests`。

### 阶段三实际做法与偏差（2026-11-14）

六项各一个提交：失败/重试提示条（a698d99）、提问卡折叠（7d0abbd）、回合中发消息（dad1c9f）、权限卡（7fa016a）、选项按钮（e5463d0）、`<proposed_plan>`（fbe1771）。

- **失败/重试提示条**：`Models/SessionFailures.swift` 照搬 web `session-failures.ts`（按 id 单调合并、同 revision 只能 resolved false→true、三种 settle 范围、dismissed≠recovered）。composer 上方只画「进行中」的事：重试行（Claude `system/api_retry` 与 `turn_retrying` 共用，任何输出/离开 prompting/关流即清）、一条 AIR 事件条 +N、自愈后 10 秒自动消失的「已恢复」。终态记录走 TURN_FAILED，提示类走 notice。
- **权限卡**：reason 取 `_meta.permission.description`；标题先 `_meta.claudeCode.title` 后 `_meta.permission.title`，标题等于命令时换回模型自己的 `rawInput.description`；`defaultToNo: true`（严格的布尔 true）把实心按钮让给拒绝；Claude 沙箱网络请求按 host 呈现——请求本身不带工具名，靠 live 调用合并（web `mergePermissionToolCallWithLiveInfo`，含调用晚于请求到达的情况、被剥掉的 Edit 文本回填）。
- **选项按钮**：按钮显示模型/强度/模式摘要；只读 live snapshot 或已有目录，**从不为摘要起 probe agent**。超过阈值的列表推到可搜索子页，模型按 `provider/` 分组，标出 `recommended_value`。
- **`<proposed_plan>`**：`Activity/ProposedPlan.swift` 逐条照搬 web 规则（行首、≤3 列缩进、不在围栏/行内代码中；未闭合时流式中为「规划中…」卡）。直播文本在自身叶子视图里拆，不让整条时间线订阅每个 token。
- **回合中发消息**：
  - 队列在 VM（`MessageQueue`）：回合中或队列非空时发送进队尾；空闲时逐条发；409 退回（队头回队头、composer 的进队尾）+1 秒退避；其它失败把队列**暂停**（web 是丢弃不重试，iOS 改为保留并要用户「立即发送」，免得排队的消息丢失）。Stop 后先等一个退避再发。turn 死掉（failLive）也暂停。
  - steering：长按回合中的发送按钮 →「插入当前回合」（native）/「发送留言」（pull），文字为准，有图片时只能排队（iOS 不发 `blocks`）。native 的 `feedback_submitted{delivered}` 在 live 中插入 `.steering` 段，时间线和折叠副本都在此切成「回复 → 用户消息 → 回复」。握手 snapshot 的留言属于上一轮，不采用；`user_message` 清空。
  - 已知局限：离开会话页面后队列随 VM 丢失（web 关 tab 同样）；对方客户端长时间占用回合时每秒重试一次（web 同样）。
- **验证**：四项（发消息/权限卡/选项按钮/plan 卡）是并行写的，最后在一个分支上合起来一次编译通过，全量 514 个测试（84 个 suite）全绿。Codex 只读审查 4 轮：首轮 5 个 Important（测试调用了改名的方法、teardown 吞掉已出队的消息、hydrate 把已读改回等待、恢复路径不 flush、连接丢失被当成回合结束）全部属实已修，后两轮又各抓到一个修复引入的时序问题，第四轮 APPROVED。**尚未在模拟器上对 mock 做 UI 验证**。

### 遗留补齐（2026-11-14）

阶段三的漏项和阶段二的未移植项，各一个提交：

- **旧卡片清理**（75db3e4）：所有调用方都传 `groupTools: false`，旧的通用工具分组（`groupConsecutiveTools`、`RenderPart.toolGroup`、`ToolGroupCard`）已不可达，删除。`MarkerKind.toolGroup` 保留（activity 分组在用）。
- **`conversation moved`**（af1a17b，阶段三「失败/重试提示条」漏做的一项）：后端对「会话已移到别的文件夹、但连接还在旧文件夹」的 prompt 返回 `invalid_input` + 固定文案，iOS 按文案识别（`Models/ConversationMoved.swift`，照搬 web `conversation-moved.ts`）。被拒后提示「已移到 X，请重新发送」，消息回到输入框（队列来源回队头并暂停），丢掉旧连接、重拉会话与文件夹；下次发送时 find 只会找到新文件夹的连接。和 web 一样不自动重发。
- **Codex `/goal` 运行**（3d08518）：`Rendering/GoalRuns.swift` 照搬 `groupGoalRuns`（未闭合的 run 只在流式中闪烁、已结束的未闭合 run 把末尾答案提出来、已完成目标的陈旧 run 不再显示），`goal` 步骤持有自己的 `ReplyActivity`，行视图 `GoalRunRow` 展开为嵌套时间线。偏差：不移植 `mergeRunParts`（iOS 先合并回合再 adapt）；不移植散文里的 "Goal updated" 标记（直播层不能在组装时读流式文本）；没有暂停/清除按钮。
- **后台任务通道**（51b2f64）：`Activity/BackgroundTask.swift` 照搬 `background-task.ts`（Claude Code `TaskOutput`/`TaskStop`、Grok、CodeBuddy 的轮询格式），一个任务一行，折叠时只留仍在轮询的任务。iOS 的 `CompanionDetect` 按形状会把 Grok 的 `{task_ids, timeout_ms}` 当成委派状态检查，所以委派通道让出后台通道认领的调用——但**名字是 `get_delegation_status` 的调用永远留在委派通道**（web 先按名字分委派通道；Codex 抓到子任务报告里引用后台标签时会被抢走）。
- **委派两项判定**（bfce9e0）：被拒的 `resume_delegation`（`error_code: not_resumable` 或 "Not resumed" 前缀）不认领任务、不常驻、画成说明卡；opencode code-mode `execute` 里的 `delegate_to_agent`（`Activity/CodeModeDelegation.swift` 移植 JS 源码扫描器，UTF-16 语义）画成委派卡并读出 agent/task。卡片的「按推断名选委派卡」**必须有证据**（code-mode 输入或 `_meta` 里 broker/host 的标记），否则标题里引用了 `delegate_to_agent` 的 Bash 会丢掉命令和输出（Codex 抓的）。
- **验证**：三项移植由并行 agent 只写代码，合到一个分支后一次编译通过；全量 669 个测试（94 个 suite）全绿。Codex 只读审查：清理 + moved 一轮 APPROVED；三项移植首轮 goal APPROVED、后台通道与委派各 1 个 Important（如上，均属实已修），复审 APPROVED。**尚未在模拟器上做 UI 验证**（goal 行、后台任务行、被拒恢复卡）。

### 阶段四第一波实际做法与偏差（2026-11-14）

四个并行 agent 只写代码，合到一个分支后编译一次通过，全量 932 个测试（137 个 suite）全绿。

- **空闲连接观察者 + live runs + `prompt_suggestion`**：
  - `ConnectionWatcher` 自带 EventStream 和订阅 id。屏幕可见、有连接、没有回合流时 attach；`closeStream()` 时停止，所有开流路径都经过它。重连带 `since_seq`，有退避上限。每个 socket 带代际号，晚到的帧丢弃。
  - 不写 VM 的 `connectionID`。
  - 选项面板、fork 解析出的连接也会立刻开始 watch（`adoptResolvedConnection`）。
  - `ConnectionRunsModel` 移植 `async-tasks.ts` / `live-runs.ts`，两条流都喂给它。
  - 偏差：
    - **新鲜 snapshot 若是另一个 session，整表替换**：iOS 离开页面时观察者会断开，可能错过 fork 的 `session_started`；web 不断开，所以没有这条（Codex 抓的）。
    - 芯片不列前台子 agent（时间线里已有）；委派行不可点、没有琥珀点；没有 Output 按钮。
    - Claude 自主 `turn` 任务结束后自己重拉转录。
  - 建议是空输入框的 placeholder + 「填入」+ 硬件 Tab，只填不发。
  - **未做**：观察者看到 `prompting` 时转成直播 reattach。
- **fork + 消息导航**：
  - fork 点取合并回复的**最后一个** turn id。能定点 fork 的只有 Claude / Codex / DeepSeek，其余 agent 只在最后一条回复上提供。有确认框。
  - 成功后立即改 `summary.externalId`，再按新 fetch 代际整段重拉转录：重试 6 次，只采用已体现 fork 的结果。之后显示「打开原会话」条。fork 进行中，发送进队列。
  - 导航从「…」进入，是 sheet。outline 用 window 的 (offset, prefixHash) 锚点校验，向上翻页时锚点跟着移动。跳转用 `loadOlderTurnsThrough`，再让 `TranscriptView` 放宽本地窗口并 `scrollTo`。
- **`/` 菜单 + @ 面板**：
  - 用 iOS 26 `TextField(selection:prompt:axis:)` 取光标，输入框上方显示建议卡。
  - 命令来源依次为：两条流的 snapshot、`available_commands` 事件（空闲时由观察者转发）、草稿 probe；第一次输入 `/` 且没有任何来源时才 probe，按 agent+folder 缓存。
  - @ 只做 files + agents。输入框里显示 `@relpath`，发送 / 转向 / 排队时编码成 web 同款 Markdown 链接，放回时解码。
  - 顺带修了「+」sheet 把 `$x` 插成 `/$x`，并去掉已过时的 expert 过滤。
  - **未验证**：硬件方向键/回车是否能到达 `onKeyPress`；CJK 输入法组字期间的表现。
- **Markdown**：
  - 列表统一成带层级（0–4）的 `.list`，任务项用复选框图标。
  - 围栏有 `closed` 标志。
  - 图片块：本地路径规则逐条移植自 web；按屏幕的加载器并发 4、合并在途请求，只在内存缓存，不按 turn id 作键；全屏查看器可缩放、复制、分享。
  - 偏差：SVG 只显示文字；列表 / 引用 / 表格里的图片仍只显示 alt。
  - Info.plist 加了 `NSPhotoLibraryAddUsageDescription`（分享菜单里的「存储图像」需要它）。
  - ```spec 显示为折叠的「可交互卡片」。
- **Codex 审查**：各 agent 内部都审过。合并后又审了两轮，各抓到 1 个 Important，均已修复，复审 APPROVED：
  - 观察者断开期间错过 fork 后残留旧任务；
  - fork / 选项面板新建的连接没有被 watch。
- **尚未在模拟器上做 UI 验证**。

### 阶段四第二波实际做法与偏差（2026-11-14）

- **共享离屏 WebKit 渲染器**（`Rendering/WebRender/`）：
  - 一个串行队列，相同请求合并为一次；每一步有超时，卡住的页面直接丢弃。
  - 两个 WKWebView：一个开 JS，常驻已加载的 mermaid；另一个关 JS，渲染 HTML，用到时才建。
  - 都用非持久数据存储，内容规则表屏蔽一切加载（只放行 `about:` / `data:` / `blob:`），导航委托只放行预期的那一次加载。
  - 视图停在当前窗口外的 1×1 裁剪容器里，不可交互、对辅助功能隐藏。不在窗口里时 WebKit 会节流定时器，mermaid 11 的解析会被拖慢。
  - 截图用 `createPDF` 按精确区域截取，再绘制成位图，以免高图要放超大视图。
  - 缓存键是「内容 + 主题 + 尺寸」的 SHA-256：SVG 文本 32 条 / 8 MB，位图 32 条 / 48 MB。
- **Mermaid**：
  - 打包 mermaid 11.17.2，sha512 与 codeg lockfile 一致，许可证记入 `THIRD_PARTY_NOTICES.md`；`project.yml` 把它固定为资源，不参与编译。
  - `securityLevel: strict`；源码通过 `evaluateJavaScript` 的参数字典传入，不做字符串拼接。
  - **偏差**：
    - 围栏闭合（或流式结束）后才渲染，之前显示「正在渲染图表…」占位；web 是逐 token 重画。
    - 内联是静态图，点开全屏，可缩放的 SVG 保持清晰；导出方式是分享 PNG / SVG / .mmd。
    - 字体换成 `ui-monospace`：iOS 上的 `monospace` 会落到 Courier。
- **HTML 预览**：
  - 外观设置里的「在聊天中渲染 HTML」，默认关，仅本机。
  - 只认**闭合**的 ```html / ```htm 围栏，且只在 assistant 回复里。
  - 清洗器与文档构建是逐条移植的纯函数（字节级 tokenizer），注入 CSP 与主题变量。内容 JS 始终关闭，含全屏视图。
  - 内联截图有 Code / Preview 切换，高度在 96–12000 pt 之间，超过 640 pt 折叠并显示「展开全部」。
  - **偏差**：不处理原始 HTML 块；流式中仍显示为代码块（web 显示「Generating HTML…」）。
- **验证**：
  - 编译、1042 个测试（158 个 suite）全绿。agent 写的测试里有 `#"…"#` 原始字符串包含 `"#`，提前截断，导致编译失败，已改成 `##"…"##`。
  - Codex：agent 内部审了一轮；合并后又做一轮安全向审查，APPROVED，只留下加固建议：HTML 清洗不限输入大小、超大 SVG 条目会突破文本缓存预算。
  - **未在真机 / 模拟器验证**：冷启动时网络确实被拦、超时后能恢复渲染、内存告警发生在截图过程中、切换场景、触摸与 VoiceOver 不受停靠视图影响。

### 模拟器 UI 验证（2026-11-14）

阶段三、四的界面用 mock（HTTP + WebSocket，按 0.44 线格式）和临时 XCUITest 在 iPhone 17 模拟器上过了一遍（英文界面）。测试 target 和 mock 都没有提交。

- **正常**：
  - Markdown：复选框、多级列表、工作区图片、远程图片、spec 折叠卡、图片全屏。
  - Mermaid：流程图、时序图、错误卡、全屏。
  - HTML 预览：脚本没有执行，外链图片没有发出请求；代码/预览切换、Show all、全屏都可用。
  - goal 行、后台任务行、委派卡、被拒的恢复卡。
  - live runs 芯片、列表和 Stop；建议的「Use」；`/` 菜单和过滤；`@` 面板（agent 与文件）。
  - 消息导航器，包括跳到窗口之外的历史。
  - fork（确认框、截断改名、「打开原会话」）。
  - 权限卡（拒绝为主按钮、授权说明）、排队条、长按插入当前回合、「Allow」后继续、回合结束后自动发出排队消息、409 每秒重试。
  - 重试条，conversation moved 的提示和重发。
- **发现并修复**：
  - **崩溃**（0893d53）：发送被秒拒时，`List` 的 `scrollTo` 行号在合并更新里越界（`NSInternalInconsistencyException`），约每 1～4 次一次。这个问题在 iOS 端一开始就存在，阶段三的 moved / 409 让秒拒变得常见。现在贴底改为直接设置底层 `UIScrollView` 的 contentOffset，不再按行滚动。`.scrollPosition` 在 `List` 上不起作用，所以没用它。
  - 最后一条回复带 Mermaid / HTML / 图片的会话打开时停在顶部（同一提交）：这几类块在结果到达时通知时间线，原本在底部的读者保持在底部；读者自己的 Show all 和代码/预览切换不触发。
  - 「N running」芯片、状态条、键盘在贴底之后出现时会盖住最后一条回复的页脚（同一提交）：可见区域变小且读者原本在底部时，重新贴底。
  - 权限卡有授权说明时，按钮上方有一大块空白（e2a36a0，0.23 适配时就有）：现在主体只占内容高度，超过 300pt 才滚动。
- **仍未验证**：中文界面下逐屏查看；CJK 输入法组字期间的 `/`、`@` 触发；硬件键盘的方向键、Tab、回车；VoiceOver；HTML 冷启动时的拦截和渲染超时恢复；真机。

### 中文界面与输入法验证（2026-11-15）

同一套 mock 和临时 XCUITest，换成中文界面（`-AppleLanguages (zh-Hans)`）把上面的界面再过一遍，并用拼音键盘测了组字。

- **文案**：
  - 用 `SWIFT_EMIT_LOC_STRINGS=YES` 构建，拿编译器抽出的全部可本地化字符串对照 `Localizable.xcstrings`：阶段三、四新增的界面没有漏翻。
  - 其余漏翻的 114 条大多是占位符、品牌名、纯格式串，少数是设置页里的旧句子（如 "Couldn’t Open Folder"、"Switch server"、主题色名）。
    - 随后补齐：45 条加了中文；另有 6 处原本把英文拼成 `String` 直接显示（模型覆盖数、模型占位符、供应商占用提示、渠道摘要、MCP 缺少 command/url、克隆路径预览），改为走本地化。
    - 剩下的 71 条是刻意不翻的：占位符、示例值、品牌名、格式串、技术词，以及语言名「English / 中文」。
  - 截图里留下的英文，大多来自服务端或第三方：权限选项名（Allow / Always Allow / Reject）、工具 kind（execute）、Mermaid 的报错原文、broker 的「Not resumed: …」。web 端也原样显示这些。
  - 紧凑时长「22.0s」「9m 18s」「48s」与 web 的 `formatDuration` 一致，web 在中文下也不翻。
- **软键盘拼音**：组字、选词、`/` 和 `@` 后接中文、发送中文都正常，文字没有重复或错乱。
  - 组字期间菜单会用拼音字母过滤（`@wen` 会搜 "wen"），选词后再按汉字过滤。
  - web 端同样让组字中的文本参与匹配，所以没改。
- **发现并修复**：
  - **组字时菜单抢按键**（4413a33）：`/re` 的 "re" 还在组字时，硬件 ↓ 移动了菜单高亮，Tab 直接选中 `/review` 替换掉拼音。
    - 现在输入框有 marked text 时，菜单不接任何按键，与 web 的 `isImeCompositionKey` 一致。
    - marked text 从第一响应者的 `UITextInput.markedTextRange` 读，SwiftUI 不暴露这个状态。
  - **拼音键盘下发送后不跟随到底部**（e5dfe96）：
    - 现象：清空输入框时拼音键盘重新布局，`List` 的 scroll view 被临时缩小（bounds 874→423，底部 inset 456→0）再恢复，offset 被带上去约一个键盘高度。
    - 原因：旧的「是否在底部」观察者把这当成读者自己上滑，取消了跟随。英文键盘不会这样。
    - 修法：两个几何观察者合成一个。可见区域下边缘变化、原本在跟随、手指没在拖时，重新贴底并继续跟随；读者自己滑动越过阈值的处理不变。
  - **中文里的英文「now」**（353d0bd）：不到一分钟的相对时间是硬编码的 "now"。现在从字符串表取「刚刚」，并跟随 app 内的语言设置。
    - 同一提交把中文译文里的「Agent / 子 Agent」统一为「智能体 / 子智能体」，与 web zh-CN 和 app 其他地方一致。
- **模拟器上验证不了的**：
  - XCUITest 的 `typeKey` 在软键盘开着的模拟器里不像真实的硬件键盘：回车、Esc 到不了 SwiftUI 的 `onKeyPress`，组字中的 ↓、Tab 也会被输入法清掉。
  - 所以「硬件键盘回车选中菜单项」和「组字中回车提交拼音字母」仍需在真机或 iPad 外接键盘上确认。
- **仍未验证**：VoiceOver；HTML 冷启动时的拦截和渲染超时恢复；真机。

### 对照 Android 客户端后的修复（2026-11-15）

对照本地 codeg-android 的 63 个 0.44 同步提交，先修了一批小而确定的问题。每项一个提交：

- **MCP 编辑丢分配**（aab197b）：`McpAppType` 原来只有 7 个 app，解码时丢掉其余的；服务端保存的语义是「只挂在列出的 app 上」，所以一次编辑就会把服务器从另外 13 个智能体上摘掉。现在保留原始字符串，可勾选列表照 web 的 18 个，保存时把界面没提供的已有分配（OpenClaw、pi、未知 app）原样带回。
- **MCP 页在 0.30.2 起的服务端上加载失败**（3dae3ea）：`mcp_scan_local` 改成返回 `{servers, warnings}`，iOS 一直按数组解码。现在两种都认，并照 web 显示读不了的配置来源。（所以上一条只在 0.30.2 以前的服务端上会触发。）
  - 扫描不完整时禁止保存（f8f92e5，Codex 抓的）：读不到的智能体在编辑器里显示为未勾选，修好文件后再保存就会把服务器从它身上摘掉。照 web，新建和编辑都置灰，要重新读一次完整列表才能保存。
- **Kimi 保存 API Key 清掉推理设置**（1b3d0aa）：apikey 模式会重建模型表，缺省即「不开推理」。保存前重读 `acp_list_agents`，把 `reasoningEnabled / alwaysThinking / supportEfforts / defaultEffort` 原样带回；读失败就不写。最大上下文预填 262144。
- **Grok 自发回合被抢占**（6330bfe）：服务端先用 `turn_complete(cancelled)` 结束 Grok 自己的回合，再开始新 prompt。现在发送的回复只在服务端开始本轮后（`prompting`、带本次 clientMessageId 的 `user_message`、或重连 snapshot 的 `pending_user_message` 就是这条）才接收内容、失败判定和回合结束；reattach 的回合一开始就算已开始。
- **重新挂上回合时的隐藏锚点**（c2ce115）：改为以 `in_flight_user_turn_id` 为锚点，不在窗口内时才退回「最后一条用户消息」。
- **新版压缩标记**（e303d84、6b23235）：认 `{version: ≥1 的整数}`，分隔线显示 token 数、耗时、失败和服务端声明的摘要；失败的压缩计入回复头部的「N 失败」；放不下时「Summary」换行，不截断 token 数。
- **Codex 直播无匹配搜索**（f0a899a）：直播 `failed`、无输出、带 `codeg.codexSearchAction` 的搜索按成功（no matches）显示。
- **思考行重复标题**（825fc84）：展开后去掉已作为标题的那行；去掉后为空则不可展开。

验证：
- 全量 1109 个单元测试通过。
- Codex 审查：前四轮 APPROVED；MCP 扫描那条第一轮 CHANGES_REQUESTED（上面的禁止保存），修后复审。
- 模拟器对 mock：
  - Grok 抢占：撤掉修复跑反事实能复现「回复混入残余、真正回复丢失」，恢复后通过。注意短回复会被回合后的转录重读掩盖，反事实要用长于约 2.5 秒的回复。
  - 压缩、无匹配搜索、思考行：历史和直播各看了一遍。直播 mock 必须照真实线格式只给标题、不给 `raw_input`，否则会按输入形状推断成 Read。
  - MCP 和 Kimi：在 app 里保存，检查发出的请求体。

刻意未做、留待后续：压缩的提升 / 去重 / 空回合（`hoistedCompaction`、`dedupeCompactionItems`、`isEmptyTurnItem`）；思考行和摘要的展开状态在 cell 回收后会丢（没有按 step 的展开状态存储）；Kimi 推理设置的编辑器（web 有）。对照中发现的其余缺口见 memory `android-parity-gaps-2026-11`。

### 回合后对账吃掉最终答案（2026-11-15）

服务端发出 `turn_complete` 时，智能体最后一次写转录还要再过一会儿（codeg 0.44 测得约 8ms；web 的 `completeTurn` 因此干脆不再重读）。iOS 回合结束后会重读转录并替换流式回复，原判据（`transcriptHasReply`）只要最后一条是有内容的 assistant 就接受。只写到最后一个工具调用的读数也能过，于是最终答案从屏幕上消失，要重开会话才回来。

照对照报告定的临时修法（不做 web 那套本地移交 + 元数据回填）：

- **必须含已流式出的结尾**（`ReplyReconcile`）：读数从本轮起点往后的 assistant 文本里，要包含回复最后一段文字的末尾（只比对字母和数字的最后 64 个，容忍分块、换行、空格差异）。没有文字的回复仍按形状判断。
- **本地折叠过的轮次**：对账一直失败时，`promoteUnreconciled` 会把流式副本折进 `turns`。之后 `loadedEnd` 是本地条数，不再是服务端的轮次起点，下一轮就定不了位：
  - 记下折叠起点 `localRoundsFrom`。下一轮只在读数稳定后（第二次读起，≥400–500ms）才判断，起点取「折叠区里最后一条含本次 prompt 词序的用户消息」之后，这样本轮插入的留言仍算本轮。
  - 本次 prompt 的词在折叠区里已出现过（同文重发、留言说过同样的词），或 prompt 没有文字（只有图片）时，认不出是哪一条，就不定位：对账保留流式副本；断线路径走原有的「请重开会话确认」。
  - 折叠后等空闲再重读：2 秒一次，要求最新一轮含最后折叠回复的结尾；8 秒一次，按服务端现状接管，所以文本记法和流式不同的智能体最终也会收敛。这个任务由 VM 持有，开流、fork、teardown 都会取消它，fork 进行中也不接管。
- 不再按用户消息条数定位：服务端可能把留言存成用户消息，停在发送前的 prompt 又根本没存，计数两头都会错（Codex 第二轮指出）。

验证：
- 新增 25 个单元测试，全量 1134 个通过。
- Codex 审查五轮：前四轮 CHANGES_REQUESTED（折叠后 `loadedEnd` 失准、计数被留言和未发送 prompt 带偏、本轮留言卡住断线恢复、重读会覆盖 fork、同文 prompt 有歧义），逐一修掉，第五轮 APPROVED。
- 模拟器对 mock（加了「结尾晚 1.2 秒 / 5 秒才写入」两种场景）：
  - 普通回合：第一次读就接管。
  - 结尾晚写：早期读数被拒，答案一直在。撤掉结尾检查跑反事实，答案流完 0.5 秒后消失且不再回来。
  - 先折叠一轮、再来一轮同样答案：两条答案都在。反事实（定位退回 `loadedEnd`）时第二条答案消失。
  - 折叠后的重读：2 秒时写入还没到，放弃；8 秒时接管，回复头部出现服务端耗时，答案只显示一次。

已知残留（概率都很低）：
- 折叠区里有一条本端没折进来、但词序相同的用户消息（比如别的客户端同时发了同样的话），且两轮结尾也相同，仍可能被认错。
- 折叠后 8 秒那次重读按服务端现状接管：如果智能体 8 秒后还没写完折叠的那轮，这轮会暂时从屏幕上消失，要等下次读取。

根治办法仍是 web 那套本地移交加元数据回填（Android d7849b4、855c581）。

### 权限卡接线：排队数、审批记录、等待中的调用（2026-11-15）

对照 Android 时发现：iOS 已经移植了「审批记录」的解析和合并（`ActivityApproval`）、行上的 `.awaiting`（「待你处理」琥珀色），但都没人喂；`permission_queue_depth`、`tool_approval` 和 `queued` 字段也没解码。这次照 web 0.44 接上：

- **排队数**：`permission_request.queued`、快照 `pending_permission.queued`，之后由 `permission_queue_depth{depth}` 更新。卡片头部显示「+N waiting / 还有 N 项待审批」。没有卡片时收到 depth 不做任何事（不能把已清掉的卡片复活）。
- **审批记录**：`tool_approval{approval}` 事件和快照的 `tool_approvals`（两个开流路径和空闲观察者都合并），存进 VM 的 `toolApprovals`，同一调用以后决定的为准，只增不减，整个页面生命周期内保留。读不懂或没有调用 id 的记录单独丢掉，不影响整帧。
- **行上的叠加层**（web `useLiveToolStep`）：不进 memo 的回复模型，而是 `SessionDetailView` 在转录上设环境值 `ActivityLive`（等待中的调用 id + 审批记录），`ActivityToolRow` / `ActivityGroupRow` 绘制时叠加：
  - 卡片问的那个调用（未结束的）读作「needs you」，琥珀色，自动展开。
  - 有审批记录的调用在右侧显示徽标（「approved once / always allowed / declined」），连接的记录优先，否则用转录自带的 `codeg.approval` 标记。点徽标弹出选项原文、谁批的（聊天频道 / 权限策略）、时间（web 是悬停提示）。
  - 被拒且转录只显示失败的调用读作「declined」，此时不再叠徽标。
  - 分组里有等待中的成员时，组头也读「needs you」；用户把组折起来，这个成员仍留在组头下面。
  - 原来 `BuildActivity.build` 上从没被传过的 `awaitingToolIds` 参数删掉了（web 0.44 的 build 也没有它）。
- **请求先于调用**（web `PERMISSION_REQUEST`）：请求到达时，若直播回合里已有这个调用但没有输入，就用请求的输入补上；若还没有这个调用（Claude 沙箱网络请求就是先到请求），就先放一个 pending 的占位调用，让被问的那一步出现在时间线上；真正的 `tool_call` 到了会原地接管这一条。

验证：
- 新增 18 个单元测试（解码、叠加层、请求输入提取、占位调用），全量 1152 个通过。
- Codex 审查第一轮 APPROVED，无阻塞问题。
- 模拟器对 mock（会话 220 加了排队数、4 秒后的 depth、快照里一条权限策略的审批、批准后 1.5 秒来一个先于调用的网络请求）用临时 XCUITest 驱动：+2 → +3 → +1；等待中的行「needs you」；快照审批徽标和弹出详情；批准后「approved once」；占位调用出现并被真调用原地接管；拒绝后只显示一次「declined」；折叠分组后只剩等待中的成员。反事实：把环境值换成 `.none`，这些断言全部失败。

没做：子智能体 / 委派等卡片式工具（非 activity 行）不显示审批徽标，web 在这些行上有；web 在等待用户时停掉回复底部的转圈，iOS 没有对应的转圈，不需要。占位调用如果被拒且智能体始终不发它的 `tool_call`，会一直转到回合结束（web 相同）。

### 会话提示条与空闲时的事件转发（2026-11-15）

对照 Android（570d145、c23a6c1、4d4280e）和 web 0.44：iOS 已经有会话通知、插件加载失败和 `session_load_failed` 的文字，但下面这些缺着，而且空闲观察者只转发三种事件，回合之间（大多数这类事情发生的时候）收到的都被丢掉。

- **状态放在 `ConnectionRunsModel`**：「远程控制已开启」和「设置已过期」都是连接的当前状态，每个快照都会重述，两条流都喂它，seq 去重、新旧快照规则、换连接重置、fork 清理都是现成的。新增 `remoteControl`、`configStale`（含本地的「已忽略」）、`isPrompting`（连接在跑回合，包括别的客户端的）。快照字段 `remote_control` / `config_stale` / `config_stale_kind` 放进 `ConnectionRunsSnapshot`。
  - 远程控制：`remote_control` 事件设置/清除；`status_changed` 为 disconnected/error、`session_started` 换了会话 id（fork）、换连接时清掉。
  - 设置过期：事件 stale=true 新建（即使之前忽略过也重新显示），stale=false 清掉；快照重述同一种类时保留忽略状态，种类不同说明有一次没看到的漂移，重新显示。
- **一次性提示走 VM 的 `tellAdvisory`**：`session_notice`、`plugin_load_failures`、新增的 `config_option_rejected`（「{智能体} 把{选项}设成了 {实际}，而不是 {所选}」，只报告，偏好仍保留所选值），回合流和空闲观察者共用。`session_load_failed` 两条路径都会设置加载失败横幅。
- **重连以应用**（web `reapplyConfig`）：琥珀色横幅，在提示卡区域，「重连以应用」+ 忽略；远程控制开着时多一行「重连也会关闭远程控制」。回合进行中（本端的或连接上别的客户端的）禁用。流程：结束连接（`acp_disconnect`，新加的客户端方法），丢掉本屏对它的一切（任务、远程控制、过期状态），再用已有的 `resolveConnectionForOptions()` 起一个新连接并观察它。
  - 要恢复的会话：优先用被结束的连接自己的会话（`runs.sessionID`，别的客户端 fork 过时它是对的），其次 `summary.externalId`，都没有就重读会话行；已有会话但不知道会话 id 时拒绝重连（会丢上下文），草稿直接重起。
  - 重连期间发出的消息进队列（和 fork 期间一样），重连完成后再发；断开前最后一刻再查一次是否有回合在跑。这两条是 Codex 第一轮指出的。
- **远程控制芯片**：和「N 运行中」芯片同一处，点开菜单：链接原文、复制链接、在浏览器中打开（只开 http/https）、关闭（发送 Claude Code 自己的 `/remote-control off`，回合进行中禁用）。没做 web 的二维码。
- **加载失败横幅**：顶替输入框（发送只会以同样方式失败），转录仍可读，草稿保留。按钮：复制命令（只有 codex + UUID 才有 `codex unarchive <id>`）、重新加载（丢掉连接、重读会话）、新建会话（同一文件夹的草稿）。恢复会话的连接在流挂上之前就没了、连续两次时（服务端会结束 `session/load` 失败的连接，原因只在那条连接的流上说），也显示这个横幅（「无法打开这个会话…」），不再只是「连接已不可用」。

验证：
- 新增 20 个单元测试（解码、快照字段、远程控制和过期状态的生命周期、文案、恢复命令门禁），全量 1172 个通过。
- Codex：第一轮指出重连期间可能打断新回合、别的客户端 fork 后恢复了旧会话，修复后复审 APPROVED。
- 模拟器对 mock（新增会话 250 归档的 codex 会话、260 远程控制开着的空闲连接；`acp_disconnect` 延迟 6 秒）用临时 XCUITest 驱动，中英文：打开时快照里的远程控制芯片和过期横幅；空闲时实时漂移、忽略后新漂移重新显示、选项被调整的提示；芯片菜单；「关闭」发出命令后芯片消失；回合结束后重连可用；别的客户端 fork 后重连恢复的是 fork 出的会话；重连期间发的消息只发一次、发在新连接上；加载失败横幅的三个按钮、复制反馈、重新加载、新建会话。
- 反事实：去掉空闲转发 → 选项调整提示不出现；去掉重连期间排队 → 消息发到了即将结束的连接上；恢复会话改回优先 `summary` → 重连恢复了 fork 前的会话；关掉三种新事件的解码 → 实时漂移、忽略后重新显示、调整提示都失败。

没做 / 已知：
- 状态为「已完成」的会话打开时不会去找连接（原有逻辑），所以这种会话上开着的远程控制、过期设置，要到下一次发送后才看得到。
- VM 里拼的提示文字（选项调整、加载失败原因、重连提示）跟随系统语言而不是应用内语言，和现有提示一致。
- 远程控制没有二维码；web 的「重连中」提示条在 iOS 上是按钮里的转圈。

### 委派卡实时状态与时间线标记（2026-11-15）

对照 Android（6988bb7、4a3af0c、d3edfac）和 web 0.44（`use-delegation-card-model.ts`、`delegation-rows.tsx`），加上用户的要求「文本步骤用小圆点，只有委派用 agent 图标」。

- **时间线标记**：助手文字从会话 agent 头像改成小圆点（`MarkerKind.prose`，Android `Prose`，脊线照常在标记周围断开）；回复头部保留会话 agent 头像（Android 同）。委派画成接手任务的 agent 的图标，外圈按状态着色（运行中强调色并脉动、等待琥珀、完成绿、失败红），恢复的委派右下角有回放小标；有权限请求在等这次调用时是琥珀色。委派检查（`get_delegation_status` / `cancel_delegation`）是沙漏 / 禁止图标，按所查任务的状态着色（web `pollsStatus`）。
- **状态来源**（`DelegationModel.card`，Android `Delegations.model` 的移植）：连接的实时绑定（`delegation_started` / `_completed`、快照的 `active_delegations`，经 `ActivityLive.delegations` 在绘制时叠加，不进 memo）→ broker 写在调用 meta 上的 `codeg.delegation` → 调用报错 → 之后一次检查报告的结束状态（web `taskEnding`）→ ack 表示运行中 → 结果 → 完成 → 启动中；运行中而最近一次检查报告卡在用户决定上（`blocked_on` 或 "Awaiting your decision:"）→ 等待。宿主丢掉结构化报告后只剩 "Delegation successful. task_id=…" 文本时仍算 ack（Android 的补丁，也加进了旧的 `resolveStatus`）。
- **恢复委派**：`resume_delegation` 现在画成同一张委派卡（标「已恢复」、详情里有恢复原因）；它自己的调用 id 不是绑定的键，按参数里的 task id 找绑定，但必须有本次调用自己的证据：结果里的子会话 id 相同，或者在没有结构化报告时结果以 "Delegation resumed" 开头（web `isAffirmedResume`，测试也移植了）。被拒的恢复仍是说明卡。
- **卡片**（`DelegationTaskCard`，替换 `DelegatedSubThreadCard`）：名字（assistant 名或 agent 名）· #任务 id · 已恢复；右侧状态词带耗时；任务两行；进度行是子任务步数、结束后结果的第一行（进行中是当前步骤）和「打开会话」；展开看完整任务、工作目录、恢复原因、结果（过长时「展开」）。「打开会话」用子智能体查看器按会话 id 读子会话（`get_folder_conversation`，最近 200 轮，按子会话的 in-flight 判定活跃）。
- **折叠**：回复折叠时委派行只在还在跑时保留；这一步在 memo 之后的 `ReplyFolding.apply` 里按实时绑定判断（web 的 `pinnedOnly` 也是绘制时判断）。
- **Codex 指出的问题**：屏幕离开期间子任务结束，回来时新快照不再列它，但内存里的「运行中」绑定还在，会压过 meta 的结束状态。现在比所有已应用事件都新的快照没有重述的运行中绑定会被删掉，卡片退回到 meta。

验证：
- 新增 22 个单元测试（卡片状态优先级、等待、恢复绑定、`isAffirmedResume` 的 web 用例、标记映射、检查状态、构建出的委派节点、折叠、离开期间结束的绑定），全量 1199 个通过。
- 模拟器对 mock（新增会话 270：快照绑定的运行中委派、按 task id 找到绑定且检查报告等待中的恢复委派；271 是子会话）用临时 XCUITest 驱动，中英文：小圆点和头部头像；委派图标与外圈颜色；`delegation_completed` 到达后卡片原地变「完成」、外圈变绿、「N 运行中」减一；「打开会话」读出子会话；展开详情。
- Codex：第一轮指出上面的绑定残留，修复后复审 APPROVED。

没做 / 已知：
- 回复头部的「运行中 / N 失败」汇总仍按 memo 里的信息算，不看实时绑定。
- web 的实时子会话进度（直接订阅子连接）和运行时长时钟没做；步数和当前步骤来自检查报告。
- 一条之后几轮才出现的检查只在同一条回复内交给委派卡（Android 做了整个会话的索引）。

### 计划跟着修改位置走（2026-11-15）

移植 Android e35e19a（由并行 agent 写，Codex 审查通过，合进来后编译和测试一次通过）：直播计划从回复顶部的固定字段改成回复里的一段，每次 `plan_update` 移到最后（web `PLAN_UPDATE`），被它切开的文字/思考重新接上；回合交接时按 TodoWrite 调用原地保留；历史里的 TodoWrite / Kimi `TodoList` / codex `update_plan`（有清单的）画成同一张计划卡，行 id 一致；ExitPlanMode 的计划文档用计划卡显示，过长「展开」。模拟器验证：回合中计划跟到最新文字下面，回合结束后留在最后一次修改的位置。

没做：失败的计划类调用仍是工具卡；web 的单行「Updated plan」折叠行没做，历史里多次 TodoWrite 是多张卡。

### 非本端发起的回合（2026-11-15）

- **别的客户端发起的回合实时显示**：空闲观察者看到 `status_changed(prompting)` 或 `user_message`，且本屏空闲时，在那条连接上走现成的 reattach 跟随这个回合（`followForeignTurn`）；回合在挂上之前就结束了则重读转录（`serverSaysLive`）。
  - 这种回合开始时本屏的转录早于它：不能开 `liveTurnFromReattach`（它按最新的已加载用户消息隐藏后面的助手回复，会把上一条回答藏掉），提示词也不会再有 `user_message` 重放。所以从快照的 `pending_user_message`（新解码了 blocks 文本）放一条待定用户消息，和本端发送时一样，回合结束对账后替换。这是 Codex 第一轮指出的。
  - 回合中断线重连时保持这个模式（`reconnectStream` 按 `!liveTurnFromReattach` 传 `foreign`），待定提示词只放一次。这是 Codex 第二轮指出的。
- **Claude 的回合外活动**（后台任务完成、之后的工作、cron / loop 回合，这些不走 ACP，只在转录里）：`background_activity` 现在解码这一批的 `turns`（只计数）和 `settled`；非空时在空闲后重读转录（`refreshAfterAutonomousTurn`），已结束（非 interim）的任务提示一次（「Claude Code：Dependency audit finished」/「N 个后台任务已结束」）。

验证：新增解码和提示文案测试，全量 1224 个通过；模拟器对 mock（快照带 `pending_user_message`、新增 `/mock/append` 往转录追加一轮、`/mock/drop` 断开订阅）：空闲时别的客户端发长回合，回合中上一条回答仍在、对方的提示词和直播回复都显示；回合中断线重连后不变、提示词只出现一次；回合结束只对账一次；快回合；回合外活动的提示和重读。反事实：去掉观察者的两个转发 → 五个断言全失败；外来回合改回旧分支 → 回合中两个断言失败；重连不传模式 → 「上一条回答仍在」失败。

没做：Android 的回合外内存叠加层（按时间穿插、按 transcript_watermark 退役），iOS 用重读代替；Android 0cf00e4（智能体自己发起、前面没有提示词的直播回复接到上一条回复上），这种回合现在是单独一条回复，对账后合并。

### 会话标签与移动会话（2026-11-15）

由并行 agent 移植 Android 9fea1a7 / 3108b44 / 1f089c2 / 35dfc87（标签）和 aac73a8 / 176d0ef / 37f1636（移动），接口按 Rust 源码核对（`web/router.rs`、`web/handlers/conversation_tags.rs`、`move_conversations`），agent 自己跑过 Codex 审查（修了一处）。合进来后应用代码一次编译通过，只修了测试里一处原始字符串分隔符（`#"…"#6e7781"…"#` 要用 `##`），补了 71 条中文。

- 标签：会话行标题后显示标签（放不下时 `+N`），列表按标签筛选（任一 / 全部，按服务器保存），标签管理（新建 / 改名 / 改色 / 删除 / 上下移，全局和文件夹标签，分支标签开关），行的长按菜单和会话页「…」里的「标签…」。每个（服务器，会话）只有一个写入方，改动逐个发送，创建中的标签算作待办，迟到的打开不再生效（Android 的四条规则）。
- 移动：长按菜单和会话页「…」里的「移动到…」，列出服务器上其他已打开的文件夹，确认后移动；会话页移动期间消息排队（和 fork、重连一样），完成后丢掉旧文件夹的连接，下一条消息在新文件夹起智能体。iPad 上列表移动了旁边打开的会话，会话页也跟着切换。
- 合并时补了一处：别的客户端的回合在移动进行中不去跟随（`followForeignTurn` 加 `!isMoving`）。

验证：全量 1269 个单元测试通过；模拟器对 mock（新增标签和移动的接口）：行上的标签、按 review 筛选只剩一条、清除筛选、长按菜单打开标签选择、勾上 review 后行上立即出现、移动确认页、移动后列表少一条并提示「已移动到 website」。

没做：会话页头部不显示标签；没有拖拽排序（用上移 / 下移代替）；活动和搜索的行不显示标签；不能多选批量移动；标签错误显示服务器的英文原文；不监听服务器的标签变更广播（靠重读）。

### 目标的暂停 / 清除（2026-11-15）

移植 web（`use-goal-actions.ts`、`goal-tool-call.tsx`）和 Android cd31131 / d3edfac：

- 快照的 `goal_actions` 三种情况：列表 = 已知；`null` = 智能体还没完成 `initialize`，什么都不提供，并按 0.4/0.8/1.6/3.2 秒重读 `acp_get_session_snapshot`；字段缺失 = 老服务端，按旧的 `pause` / `clear`。放在 `ConnectionRunsModel`，一条连接定下来就不再变，换连接清空。
- 目标行展开后：进行中给「暂停」和「清除」，已暂停只给「清除」（继续靠重新发 `/goal`）；只用智能体声明的动作（Claude 的目标扩展没有 pause）；只在会话里**最新**的那个目标上出现（按钮作用于当前目标）。「最新」在折叠之前确定：最新那条回复折叠着时，展开更早的目标也不会出现按钮（Codex 第一轮指出）。
- 发出后该目标的按钮先收起。服务端立即返回，智能体的结果之后才来：拒绝是 `goal_control_failed` 错误（提示并恢复按钮），成功是目标的更新。回合中这条更新会直播进回复；回合之间没有东西直播它，所以重读转录（codex 把变化写进 rollout，历史解析成同样的 `update_goal`）；4 秒后按钮恢复。空闲观察者现在也转发提示级的错误（目标控制、模式、选项失败）。Codex 第一轮指出空闲时看不到结果，第二轮指出离开页面时待定标记残留，都已修复。

验证：新增解码、状态、按钮条件、最新目标的测试，全量 1277 个通过；模拟器对 mock（会话 280：更早的已暂停目标 + 最新的进行中目标，codex 连接声明 pause/clear）：更早的目标没有按钮（最新回复折叠时也一样，反事实：折叠后再取最新 → 这一断言失败）；最新目标有暂停和清除；暂停后按钮收起、重读后显示已暂停且只剩清除；被拒的清除提示「goal is busy」并恢复按钮。

### 8 个新内置智能体与 ACP 适配器说明（2026-11-15）

- 移植 Android 5353e77：DeepSeek Harness、Qoder、Google Antigravity、Kiro CLI、ZCode、TRAE CLI、Command Code、MiniMax Code 成为 `AgentType` 的内置值（以前是 `.other`，名字是 slug、没有图标、设置页当成自定义智能体）。名字、品牌图标（web `agent-icon.tsx` 的 SVG，Qoder / Antigravity 是单色模板）和强调色按 web。iOS 没有它们的设置面板，服务端多数也没有本地配置文件，所以详情页显示「设置在 codeg 桌面端管理」，不给配置编辑器和保存（启用开关照常）。`custom:zcode` 等仍是各自的自定义身份。
- 移植 Android d05d95c：`acp_preflight` 的 `adapter` 解码成 `AdapterInfo`，详情页在预检下面显示五种状态之一（已安装 / 已安装且找到了你自己的 CLI / 未安装 / 未安装但找到了你自己的 CLI / 需要官方运行时的桥接），措辞指向桌面端的「智能体设置」，「了解详情」只开 http/https。

验证：新增测试，全量 1282 个通过；Codex 审查一次通过；模拟器对 mock：智能体列表 8 个新图标和名字、DeepSeek 详情的桌面端管理说明、Claude Code 的「已安装且找到你自己的 claude」说明、Codex 的「未安装」说明。资源目录里那条 CoreSVG 警告是原有的（去掉新图标也有）。

### 余下可选项一次补齐（2026-11-15）

用户要求把上一轮列出的「没做」、旧清单余项和对照后 Android 的新提交一次做完，最后统一验收。并行 agent 写了 Kimi 推理编辑器、Codex 命令显示、标签头部/拖拽/批量移动、压缩位置与展开状态（各自跑过 Codex 审查）；时间线和会话页的几项是主线写的。

- **回复合并**（Android 0cf00e4）：持久层记住它结尾的回复（`PersistedTier.tail`）；直播回复前面没有提示词时（智能体自己发起），画成那条回复的延续：沿用它的 id，两段的步骤一起计数，先前的页脚让给直播回合的结尾。只合并第一次插话之前的那段；只有一次 `/compact` 的直播段不合并（历史里它是分隔线）。
- **计划单行**（web `PlanRow`）：每次计划更新一行「更新了计划 · 当前步骤 2/3」，正在写的那次自动展开，历史里的收起。
- **委派**：
  - 回复头部按卡片状态计数委派（实时绑定、整会话最新检查），子任务在回复结束后失败也会显示「1 个失败」。
  - 整会话检查索引（Android `DelegationTaskIndex`）：持久层构建时折叠所有委派和检查，按构建版本判等，经 `ActivityLive.delegationTasks` 叠加到行上。
  - 子任务实时进度（web `useChildProgress`）：对运行中的子连接各开一个事件流（最多 4 个），按工具调用计数，结束 2 秒后释放；运行超过 10 秒显示计时（web `useLiveElapsed`，从本屏第一次看到它运行算起）。
- **回合外叠加层**（web `conversation-runtime-store`、Android `BackgroundOverlays`）：`background_activity` 的 turns（逐条解码）按 id 增量合并，带 watermark；按墙钟时间和本地折叠的回合穿插；读到 `transcript_watermark` 覆盖它们时退役；fork 或换了会话时清空。已结束的后台子任务的启动卡原地变成结果（`[[codeg-background-task]]` 生命周期，web `background-agent.ts`）。只有读不了的 turn 或缺 `tool_use_id` 的结算才重读转录。叠加层里的回合不提供「从这里分叉」（服务端认不出它的 id；Codex 审查指出），在末尾时照常按末尾分叉。
- **回合结束刷新会话列表**（Android 0c26234）：`finalize` 和 `failLive` 发 `conversationsDidChange`。新建任务已有（Android 76b7b11 说的就是 iOS 的做法）。
- **Codex 已保存命令**（Android 7526a6b，agent）：`cat`/`head`/`sed -n`/`ls`/`rg`/`grep` 等单命令按直播时的身份显示（读取/列目录/搜索），带管道、连接符、重定向、展开的仍是命令；直播 `Read file '<path>'` 带上文件输入；标题修正。
- **压缩**（Android 52f2021，agent）：后面没有回复内容的压缩是回合之间的分隔线；直播和转录的同一次压缩只画一次；回复轮次之间的空占位轮次不再把回复切开。
- **展开状态**（agent）：思考、工具行、分组、计划、委派卡等的展开状态存在每屏的 `DisclosureStore`，滚走再回来不丢。
- **标签和移动**（agent）：会话页标题下显示标签（点开标签选择）；活动和搜索的行也显示；标签管理可拖拽排序；会话列表多选后批量移动，部分成功分两行提示。
- **Kimi 推理设置编辑器**（agent，web `kimi-code-config-panel`）：推理开关、可选档位（含自定义）、默认档位（必须在可选档位里）、始终推理；保存时用户改过的用改后的值，没改的沿用重读到的磁盘值；与别处的修改冲突时不写入并重新载入。

验证：
- 全量单元测试 1390 个通过（新增回复合并、叠加层、分叉点、委派索引、头部计数、子任务进度等）。
- Codex：主线部分第一轮指出叠加层回合会被当成分叉点，修复后复审 APPROVED。
- 模拟器对 mock（新增 273 跨回复检查、290 后台审计、291 计划修订、292 Codex 命令、293 智能体自己的回合、294 回合间压缩、子连接 `conn-child-271`、`/mock/autonomous/<会话>`、`/mock/append` 可带 id 和 watermark、详情带 `transcript_watermark`）用临时 XCUITest 跑，中英文：以上每项都看过截图；Kimi 保存的请求体、标签排序请求、回合结束后 40 ms 内会话列表重新拉取、回合外事件后没有重读都对过 mock 日志。
- 反事实：去掉回复合并 → 「上面没有单独的已结束回复」失败；去掉整会话索引 → 委派卡仍显示「运行中」。

没做 / 已知：
- 批量设置状态和批量删除（web 管理对话框有）；选择模式只在会话列表根页。
- 叠加层和子任务进度只在本屏可见期间生效；子任务进度最多跟 4 个。
- 会话列表的提示条不在无障碍树里（原有）。
