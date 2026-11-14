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
