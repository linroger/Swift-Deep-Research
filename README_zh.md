# Swift Deep Research

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%20Tahoe-red" />
  <img src="https://img.shields.io/badge/Swift-6.2-orange" />
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-purple" />
  <img src="https://img.shields.io/badge/License-MIT-green" />
  <img src="https://img.shields.io/badge/Platform-Apple%20Silicon-blue" />
</p>

<p align="center">
  <a href="./README.md">English</a> · <a href="./README_zh.md">简体中文</a>
</p>

**Swift Deep Research** 是一款开源的 macOS 深度研究 Agent，基于 **ReAct（推理 + 行动）框架**对公开网络与你本地私有文档进行多轮研究：规划器分解问题，多个并行工作者通过工具调用（搜索、抓取、知识库、arXiv、Wikipedia、Reddit、计算器）进行检索与推理，反思器识别信息缺口，综合器输出带引文的 Markdown 报告。最多六轮迭代——前半段以缺口发现为主，后半段切换到深化与交叉验证。

私有文档由内置的 **SeekDB** 向量知识库管理，通过 Python FastAPI sidecar 暴露给 App，首次启动自动拉起。PDF 自动分块、向量化并支持语义检索——Agent 会**先**调用 `knowledge_base` 再访问公网，让你自己的笔记拥有优先级。

在深度研究之外，全新的 **Forecast（预测）工作区**回答另一类问题——关于*未来*的问题：它通过 HTTP 驱动本地 **DeepResearchForecast** 预测后端（原 MiroFish），跑通六阶段流水线——深度研究（DeerFlow）→ 角色本体 → 本地 Graphiti 时序知识图谱（内嵌 FalkorDB，无需 API Key）→ Agent 人格构建 → 多 Agent 社会模拟（OASIS，数百个 LLM Agent 在模拟的 Twitter / Reddit 上发帖互动）→ 可对话的最终预测报告。每个阶段都以原生 SwiftUI 渲染，包括一个可交互的力导向知识图谱。

整个项目使用 Swift 6.2 / SwiftUI 为 macOS 26 Tahoe 从零构建，启用严格并发，统一封装跨厂商的结构化工具调用协议，UI 适配 Liquid Glass 设计语言。

---

## 演示视频

### Forecast：模拟一个社会，读出预测结果

一次完整的「2030 年半导体行业」预测——DeerFlow 研究控制台与角色档案、六阶段流水线步进器、OASIS 社会模拟（40 轮、1,600+ 次 Agent 行为，覆盖模拟 Twitter 与 Reddit，实时逐轮遥测），以及最终的预测报告。

<video src="https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.11.33.mp4" controls muted width="100%"></video>

> ▶ 直链：[Forecast 流水线演示](https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.11.33.mp4)

### 深度研究

一次完整的多轮研究运行——规划器分解任务、并行工作者发起工具调用、实时活动监控，以及最终带引文的综合报告。

<video src="https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/Swift%20Deep%20Research%202026-06-08%20at%2002.05.10%201.mp4" controls muted width="100%"></video>

> ▶ 如果播放器未内嵌加载，可点此观看：[完整研究运行](https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/Swift%20Deep%20Research%202026-06-08%20at%2002.05.10%201.mp4)

同一流程的 **5 倍速**精简演示：

<video src="https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/SwiftDeepResearch%202026-06-08at01.42.541_5x.mp4" controls muted width="100%"></video>

> ▶ 直链：[完整演示（5 倍速）](https://github.com/linroger/Swift-Deep-Research/raw/main/Screenshots/SwiftDeepResearch%202026-06-08at01.42.541_5x.mp4)

---

## 截图

| | |
|:--|:--:|
| **主输入区** — Spotlight 风格的输入框，可切换研究深度、开启知识库，实时显示当前 LLM 提供方与模型 | ![Composer](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.17.21%402x.png) |
| **迭代研究画布** — 每一轮的规划、并行工作者状态、工具调用展开、右侧实时活动监控 | ![Canvas](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.17.39%402x.png) |
| **来源检视面板** — 已发现、已抓取、已引用的来源与正文同屏对照，并新增「知识库」分区，按相关度评分列出检索到的文本块（点击查看完整原文） | ![Sources](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.19.44%402x.png) |
| **知识库** — 拖入 PDF 即可通过自动拉起的 SeekDB sidecar 完成分块与向量化，研究过程中自动检索 | ![Knowledge Base](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.53.03%402x.png) |
| **设置页** — 为规划器 / 工作者 / 综合器在 12 个带品牌图标的提供方间分别选择 LLM，一键测试 API Key 并实时拉取最新模型，配置 LM Studio / 自定义端点、sidecar 控制以及预算 | ![Settings](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2011.17.46%402x.png) |
| **Forecast 工作区** — 提问「某个社会将如何对某事件作出反应」；深度预设（Quick / Standard / Deep）、完整预测 vs 仅研究两种模式、后端就绪状态横幅，侧边栏列出历史预测与后端上的流水线 | ![Forecast composer](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.15.22%402x.png) |
| **Forecast 设置** — DeepResearchForecast 后端状态与一键启动、引导式安装助手、环境修复，模拟 / 报告 LLM 提供方切换（含 MiniMax 国内平台）、后端目录与 Host URL、按需自动拉起、默认研究深度 | ![Forecast settings](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.15.06%402x.png) |
| **提供方路由** — 编排器 / 工作者 / 综合器各自独立选择提供方与模型；「Test key & fetch」一键向真实 API 验证密钥并拉取最新模型列表 | ![Providers](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.13.45%402x.png) |
| **预算预设** — Fast / Standard / Thorough 同步缩放最大 Token、工作者数、每工作者来源数与工具调用数，也可逐项手动调整 | ![Budget](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.14.57%402x.png) |
| **关于页** — 一眼看懂整体架构：编排器–工作者模式、完整的 LLM 提供方阵容、搜索 fallback 链、SeekDB 知识库、Keychain 密钥存储 | ![About](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2021.14.35%402x.png) |

---

## 深度研究 Agent —— 端到端 ReAct 循环

引擎采用 **编排器–工作者–综合器** 架构，实现经典 **ReAct（Reason + Act）** 模式，并参考 Anthropic 多 Agent 研究系统设计，扩展出多轮反思循环：

```
                ┌───────────────────────────────────────────┐
   用户提问 ──▶ │  规划器（编排器 LLM）                       │── ResearchPlan ──┐
                └───────────────────────────────────────────┘                  │
                                                                               ▼
                                  ┌────────────────────────────────────────────────────┐
                                  │  工作者池（TaskGroup，N 个并行 ReAct Agent）       │
                                  │   每个子任务循环执行：                              │
                                  │     思考 ─▶ 行动（调用工具）─▶ 观察 ─▶ 思考 …       │
                                  │   工具：knowledge_base · web_search · fetch_url    │
                                  │         read_pdf · wikipedia · arxiv · reddit      │
                                  │         calculator · current_datetime              │
                                  └────────────────────────────────────────────────────┘
                                                       │  WorkerOutput[]
                                                       ▼
                                  ┌────────────────────────────────────────────────────┐
                                  │  综合器（云端或本地 LLM）                          │
                                  │   每个关键结论附 [1][2] 引文标记                   │
                                  └────────────────────────────────────────────────────┘
                                                       │  draft markdown
                                                       ▼
                                  ┌────────────────────────────────────────────────────┐
                                  │  反思器  ── 第 2–3 轮：缺口发现                     │
                                  │           ── 第 4–6 轮：深化 + 交叉验证             │
                                  └────────────────────────────────────────────────────┘
                                                       │  新的子任务
                                                       └─────▶ 循环直到达到 maxRounds
```

相比一次性 RAG 流程，这套架构带来的实际收益：

- **不再提前退出。** 旧版反思一旦判定为 "ready" 就提前终止，导致 Fast 与 Thorough 模式效果差异不大。现在引擎承诺跑满所有配置的轮次；若反思器找不到缺口，会自动切换到**深化模式**——交叉验证关键结论、寻找反例与质疑、聚焦近 30–90 天的更新、用具体数字替换概括性描述。如果 LLM 仍然返回空，引擎会自行合成深化子任务，确保没有一轮变成空转。
- **真正的来源多样性。** 每个工作者被要求至少发起 2 次不同表述的搜索，并抓取**至少** `sourceTarget − 2`、**最多** `sourceTarget` 个不同来源（Fast = 4 / Standard = 6 / Thorough = 12）。遇到付费墙或离题页面时自动 fallback 到下一个 URL，而不是默默放弃。
- **跨厂商统一的工具调用协议。** 同一份 `LLMRequest(messages:, tools:, …)` 信封会自动翻译成 Anthropic 的 `tool_use`、OpenAI 的 `tools[].function`、Gemini 的 `function_declarations`，以及 Ollama 的 `/api/chat tools` 字段，并对各家的流式 `tool_call` 增量做解析。DeepSeek、MiniMax、Kimi、Qwen、LM Studio 与自定义端点通过同一个 `OpenAICompatibleClient` 复用 OpenAI 路径（推理模型的 `reasoning_content` 会被解析但绝不会混入正文答案）。工具调用参数的解析同时兼容两种线缆格式：OpenAI 规范的增量字符串分片，以及部分网关（阿里云 DashScope / Qwen 兼容模式）一次性下发的完整 `arguments` JSON 对象——后者过去会被静默丢弃导致每次工具调用都报「参数无效」。
- **硬性预算上限。** 共享的 `BudgetMeter` actor 同时控制总挂钟时间、Token 上限、每工作者工具调用次数与来源数。Fast / Standard / Thorough 三档预设按比例放大所有维度。

---

## Forecast —— 预测一个社会的反应

**Forecast 工作区**（工具栏切换：Research ⇄ Forecast）回答的不是「什么是真的？」，而是「将会发生什么？」。输入一个事件——例如*「美国芯片出口管制将如何重塑 2030 年的半导体行业？」*——App 会驱动本地 **DeepResearchForecast** 预测后端（原 MiroFish）跑通六阶段流水线，并以原生界面渲染每个阶段：

```
 提问 ─▶ ① 深度研究（DeerFlow）─▶ ② 本体 ─▶ ③ 知识图谱（Graphiti）
                                                         │
 ⑥ 预测报告 ◀─ ⑤ 社会模拟（OASIS）◀─ ④ Agent 构建 ◀───────┘
```

输入区提供三档研究深度（**Quick / Standard / Deep**——越深意味着 DeerFlow 跑更多轮研究、角色档案更丰富），以及两种模式：**完整预测**，或只想要研究档案时的**仅研究**（跑完阶段 ① 即停）。工作区以六枚芯片组成的**阶段步进器**呈现整次运行——每枚芯片实时显示状态、进度与该阶段的最新消息；后面的阶段还在跑时就可以点击任意芯片查看其内容，视图默认自动跟随流水线推进，手动选择后则固定在该阶段。

### 流水线六阶段详解

**① 深度研究。** DeerFlow 进行多轮背景调查（轮数随所选深度增加），产出两类成果：研究档案，以及一组**真实世界角色**——人物、公司、机构——每个都带有角色定位、立场、影响力权重与记忆种子。实时控制台逐行流式展示研究过程，角色档案以卡片形式呈现在下方。

**② 本体。** 在抽取任何东西之前，流水线先决定*这个问题需要关注哪些类型的事物*——为本次提问量身定制的实体类型与关系类型 schema，每个类型都附有指导抽取的自然语言描述。对一个半导体行业预测来说，就是 `ChipCompany`、`AILab`、`CEO`、`MediaOutlet` 这样的实体类型，与 `LEADS`、`WORKS_FOR`、`SUPPLIES`、`COMPETES_WITH` 这样的关系类型：

![本体阶段——推断出的实体与关系类型](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.47.32%402x.png)

**③ 知识图谱。** 实体与关系从研究成果中被抽取进**本地 Graphiti 时序知识图谱（内嵌 FalkorDB，无需 API Key）**，并以*原生*交互式力导向图渲染（[Grape](https://github.com/li3zhen1/Grape) 包——不是 Web View）。节点按实体类型着色、按连接数定大小；控制栏可暂停/恢复物理布局、缩放、开关标签；图例标注配色对应的类型。点按任意节点，检视面板滑入，展示其类型、摘要与全部关系——点空白处即可关闭。超大图谱会按连接度截取前 ~140 个节点，保证布局流畅：

![知识图谱——力导向 Graphiti 图谱与节点检视面板](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.47.59%402x.png)

**④ Agent 构建。** 图谱中的每个角色都变成一个自治 LLM Agent：人格从其档案条目提炼而来，拥有记忆与按平台区分的发帖行为。模拟规模（Agent 数 × 轮数）确定后会显示在该阶段。

**⑤ 社会模拟。** OASIS 让这个 Agent 社会在模拟的 **Twitter 与 Reddit** 上并行运行数十轮（下图：第 40/40 轮，共 1,668 次行为——613 条推文、1,055 条 Reddit 发帖/评论）。阶段视图展示按平台的卡片、逐轮行为柱状图，以及每一条发帖、评论、点赞的实时动态流——Agent 既对事件作出反应，也彼此互动：

![模拟阶段——平台遥测、逐轮行为图、实时 Agent 动态流](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.48.06%402x.png)

**⑥ 预测报告。** ReAct 报告 Agent 回读整个模拟——它可以通过工具调用「采访」单个模拟 Agent——写出结构化预测：核心判断前置、情景分析、来自模拟的证据链。报告以原生 Markdown 渲染并附目录，之后你还可以**与报告对话**：追问会带着完整的模拟上下文运行，回答会注明采访了哪些 Agent：

![预测报告——结构化预测](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.48.10%402x.png)

![预测报告——AI 竞争格局预测示例](./Screenshots/Swift%20Deep%20Research%202026-06-10%20at%2022.47.29%402x.png)

### App 如何驱动后端

整条流水线在本地 **DeepResearchForecast**（原 MiroFish）Flask 后端（`127.0.0.1:5001`）中运行；Swift 侧是一层轻薄的强类型 REST 封装加一个可观察状态机：

- **`MiroFishClient`** 把每个端点（`/api/research/*`、`/api/graph/*`、`/api/simulation/*`、`/api/report/*`、`/api/settings/*`）封装为 `Codable` 类型，统一处理后端的 `{success, data, error}` 信封。长耗时调用（报告对话）有独立超时；取消/删除能容忍流水线已自行结束的竞态。
- **`ForecastRun`** 是工作区的 `@Observable` 核心：发起流水线后持续轮询状态——更新每个阶段的进度、流式追加研究控制台的新行、跟随后端当前所在阶段。运行完成（或导入一条已有流水线）时一次性水合*全部*内容：研究记录、角色档案、本体、图谱 JSON、模拟时间线与遥测、报告 Markdown。
- **SwiftData 持久化。** 每次预测都是一条 `ForecastRecord`——提问、流水线 id、状态、进度、错误文本——侧边栏在重启后完整保留。打开一条仍在运行的记录会**重连**轮询循环；打开已完成的记录则按需从后端重新水合所有阶段。
- **`MiroFishSupervisor`** 负责后端进程：拉起、监听 `/health`，进程退出时把原因分类（端口被占、虚拟环境损坏、`.env` 缺少密钥）成附带解决方案的提示——包括一键**环境修复**重建 Python 侧。

### 为真实流水线而生的健壮性

一次预测要对着本地 Python 后端跑几十分钟，所以整个生命周期都做了加固：

- **引导式安装助手。** 首次运行的引导流程会检查环境、把后端的 `setup.sh` 流式输出到内置控制台并启动后端——全程无需打开终端。知识图谱在本地运行（内嵌 FalkorDB），所以无需录入任何图谱密钥；首次预测会一次性下载约 470MB 的本地嵌入模型。
- **取消 / 恢复 / 重连。** 运行中可随时停止；恢复会从第一个未完成的阶段重启，已完成的研究、图谱与模拟产物全部复用。运行中途退出 App，重新打开该预测会自动重连仍在运行的流水线。
- **后端浏览器。** 侧边栏的 *On backend* 分区列出存在于后端上、但不是从本 App 发起的流水线（Web UI、命令行、另一台机器）。一键导入并完整水合——研究记录、角色档案、本体、图谱、模拟遥测与报告全部呈现。
- **提供方切换。** 模拟 / 报告所用的 LLM 可在 设置 → Forecast 中切换——包括 **MiniMax 国内平台**（`api.minimaxi.com`，MiniMax-M3）、DeepSeek、Qwen 等——密钥与研究侧共用同一个 Keychain。

后端（DeepResearchForecast + 内置的 DeerFlow）位于 App 之外；在 设置 → Forecast 中指向其目录，启动、健康检查与关闭都由 App 接管。

---

## SeekDB —— 内嵌的私有知识库

绝大多数研究问题在你已有的文档里就已有答案。Swift Deep Research 把 **SeekDB**（`pyseekdb`）作为一等公民工具集成进 Agent 的工具目录，在访问公网之前**先**调用：

- **内嵌向量库。** 不依赖外部服务。App 自带轻量级 FastAPI **sidecar**，应用启动时自动拉起（`SidecarSupervisor` 监听 `/health`，并自动拼接 pyenv / Homebrew 的 PATH 来定位 Python）。多个并发启动请求会合并为一次拉起；**父进程死亡看门狗**会在 App 退出、强制退出甚至崩溃时让 sidecar 自动结束——确保不会有残留进程占住 9100 端口、阻塞下一次启动。
- **零配置依赖。** 如果系统缺少所需的 Python 包，Supervisor 会在 `~/Library/Application Support/SwiftDeepResearch/sidecar-venv` 下自动创建一个独立虚拟环境并 `pip install pyseekdb fastapi uvicorn pydantic`，随后从该环境重新拉起——首次启动知识库即开即用，无需打开终端。设置 → 知识库 提供「启动 / 修复」与「重装依赖」按钮用于恢复。
- **拖拽即入库。** 把 PDF 拖到知识库标签页，sidecar 自动按段落 / 句界进行分块、向量化并持久化到本地。
- **语义检索作为工具暴露。** 工作者的工具目录中包含 `knowledge_base(query, k)`。系统提示要求：只要私有文档可能相关，**先**调用知识库，再用网络检索做交叉印证。返回的命中结果通过相同的 `sourceDiscovered` / `sourceFetched` 事件流推送，引文抽取与检视器对它们一视同仁。若研究过程中 sidecar 掉线，工具会请求 Supervisor 恢复它并重试一次。
- **查看被检索到的文本块。** 检视器中有专门的 **知识库** 分区，按语义相关度评分（带颜色标识）列出 Agent 检索到的每一个文本块。点击任意块即可在阅读弹窗中查看完整原文——最终报告里的知识库来源也会打开同一个阅读器，因为 `kb://` URL 无法在浏览器中打开。
- **`kb://` 引文协议。** 知识库段落使用 `kb://<doc-id>/<chunk-id>` 形式的合成 URL，便于来源面板与正文 hover 区分私有命中与网页来源。

举个端到端的例子：把 DeepSeek-v4 论文 PDF 入库，输入 *"research the architectural innovations of DeepSeek-v4"*，工作者会先调用 `knowledge_base` 拿到 5 段高相关度内容，再发起 `web_search` 找最新基准评测——最终的综合报告同时引用你本地的私有 PDF 与近期的外部博客。

---

## 可靠性与韧性

面对不稳定的网络、缓慢的推理模型与首次运行的冷启动，整套流程都能扛住而不丢任务：

- **单个工作者不会拖垮整次研究。** 工作者失败——触达工具调用上限、重试耗尽后连接断开、预算用尽——会被隔离：该工作者带着已收集到的内容收尾、发出一条警告，其余工作者照常进入综合阶段。只有用户显式取消才会整体终止。
- **每家厂商都有瞬时网络重试。** 推理模型（deepseek-reasoner、Kimi thinking）在首个 token 之前会空转，中间链路会掐断空闲连接（"the network connection was lost"）。每个流式客户端都会重试瞬时断连——但**仅在服务端开始返回之前**，因此已经流出的内容绝不会重复。流式传输以「空闲间隔」而非「整次请求硬上限」来计时，所以长篇综合不会在中途被截断。
- **自愈 sidecar。** 在上面的启动合并与崩溃看门狗之外：冷启动的 pyseekdb 初始化拥有更宽裕的健康检查窗口；半成品的虚拟环境会被清除并重建（含 `ensurepip` 修复与安装后校验）；解释器探测带超时，避免某个卡死的 Python 拖住启动。知识库工具还会对冷启动的 `5xx` 响应重试，并把「仍在启动中」的 sidecar 视为「预热中」而非「离线」。
- **稳健的网页抓取。** 网页 / PDF / Reddit / Wikipedia / arXiv 抓取都会发送真实的浏览器 User-Agent（不再被 403/429 拦截），对瞬时失败按退避重试（遵循 `Retry-After`），并对非 UTF-8 页面做兜底解码（UTF-8 → Windows-1252 → ISO-8859-1）。单个坏链接会被优雅跳过而非令整次研究失败；抓取失败会把占用的来源额度退还，而不是白白消耗预算。
- **校准过的相关度评分。** 知识库相似度被归一化到稳定的 `(0, 1]` 区间（越高越相关），无论底层使用何种距离度量，检视器里带颜色的评分徽章与文本块排序都真正有意义。

**有引导的首次运行。** 如果所选工作者提供方还没有配置 API Key，主页会内联显示一条「添加 Key」提示并可直接打开设置——而不是让一次好奇的点击触发一次注定深处失败的研究。本地提供方（Ollama、LM Studio、Apple Foundation Models）完全无需 Key；研究进行时还有一个实时计时器，让真正耗时数分钟的 Thorough 运行可以与「卡死」明确区分开来。

---

## 功能特性

### 多厂商 LLM 路由
规划器 / 工作者 / 综合器可分别指定不同的 LLM——规划阶段省钱，综合阶段堆料。

| 提供方 | 类型 | 备注 |
|---|---|---|
| **Anthropic** | 云端 | Claude Opus 4.x、Sonnet 4.x，原生 `tool_use` 流式 |
| **OpenAI** | 云端 | GPT-5.5 / 5.4 / 4.1 系列，SSE 流式与函数调用 |
| **Gemini** | 云端 | 2.0 / 2.5 Flash 与 Pro，函数调用 |
| **DeepSeek** | 云端 | `deepseek-chat`（V3）/ `deepseek-reasoner`（R1），OpenAI 兼容 |
| **MiniMax** | 云端 | MiniMax-M3 / M2.x，走国内平台 `api.minimaxi.com`，OpenAI 兼容 |
| **Moonshot Kimi** | 云端 | Kimi K2.6 / K2 系列，OpenAI 兼容 |
| **Qwen（阿里云百炼）** | 云端 | qwen-max / plus / turbo、qwen3 系列，通过 Model Studio（百炼）`/compatible-mode/v1` 的 OpenAI 兼容网关 |
| **LM Studio** | 本地服务 | 任意已加载模型，无需 API Key，支持 `/v1/models` 实时发现 |
| **自定义端点** | 云端 / 本地 | 任意 OpenAI 兼容的 base URL（可选 Key）——配置在重启后保留 |
| **Ollama** | 本地服务 | 支持 qwen2.5 / llama3.3 / gpt-oss / mistral-small 等工具调用，上下文窗口自动设为 131,072 |
| **Foundation Models** | 端侧 | macOS 26 上的 Apple Intelligence（条件可用） |
| **MLX** | 端侧 | Mistral Small 24B、Qwen 2.5 7B、DeepSeek-R1 Distill |

DeepSeek、MiniMax、Kimi、Qwen、LM Studio 与自定义端点都使用 OpenAI Chat Completions 协议，共用同一个经过充分测试的 `OpenAICompatibleClient`。你选择的提供方 / 模型 / 端点会在重启后自动保留。

**测试密钥并拉取模型。** 每个提供方都带有品牌图标，「API keys」页可对任意密钥一键「测试」（实际请求 `/v1/models` 等发现端点验证可用性），「Providers」页的「测试密钥并拉取模型」会从各厂商 API 实时拉取最新模型列表（Anthropic `/v1/models`、OpenAI `/v1/models`、Gemini `/v1beta/models`、各 OpenAI 兼容网关的 `/v1/models`、Ollama 的 `/api/tags`），免去手动维护模型名。

### 多后端网络搜索（自动 fallback）
固定优先级：**Tavily**（Agent 优化）→ **Exa**（语义）→ **Brave**（通用）→ **DuckDuckGo**（HTML，无需 Key）。每个后端在解码前先校验 HTTP 状态——遇到 401 / 429 / 422 会在检视器里显示真实错误，而不是被静默吞掉变成 "no results"。

### 三档研究深度
| 预设 | 轮数 | 工作者数 | 每工作者来源数 | 每工作者工具调用数 | 挂钟上限 |
|---|---|---|---|---|---|
| **Fast** | 1 | 2 | 4 | 6 | 180 秒 |
| **Standard** | 3 | 4 | 6 | 20 | 900 秒 |
| **Thorough** | 6 | 6 | 12 | 36 | 1 800 秒 |

### 检视器与实时事件流
每一次规划、工作者启动、工具调用、工具结果、来源发现、来源抓取、反思、引文都通过强类型的 `ResearchEvent` 异步流推送出来。右侧检视器实时渲染，让你看见 Agent 的整个推理过程。

### 引文抽取
综合完成后，专门的 `CitationExtractor` 再读一次正文，把每一个 `[N]` 标记映射回它所引用的具体来源，并在右侧的来源面板中展示标题、URL、抓取的正文片段与点击跳转。

---

## 快速开始

### 运行环境
- macOS 26（Tahoe），Apple Silicon
- Xcode 26
- PATH 中可用的 Python 3.10+（App 首次运行会自动创建虚拟环境并安装 SeekDB 依赖——手动 `pip install pyseekdb fastapi uvicorn pydantic` 为可选）
- 可选：Anthropic / OpenAI / Gemini / DeepSeek / MiniMax / Moonshot(Kimi) / Qwen（阿里云百炼） / 自定义端点 / Tavily / Exa / Brave 的 API Key（任意组合）
- 可选：本地运行的 Ollama 或 LM Studio + 至少一个支持工具调用的模型
- 可选（Forecast）：本地的 DeepResearchForecast 检出目录（含其内置 DeerFlow；知识图谱在本地运行——无需 API Key，默认路径 `~/Downloads/DeepResearchForecast`）——App 内置的引导助手会代你运行 `setup.sh` 并启动后端

### 构建与运行
1. 用 Xcode 26 打开 `Swift Deep Research.xcodeproj`。
2. 构建（⌘B）并运行（⌘R）。
3. 首次启动时，App 会自动在 `127.0.0.1:9100` 拉起 SeekDB sidecar（`sidecar/seekdb_sidecar.py`），并在需要时自动创建虚拟环境、安装 Python 依赖。
4. 打开设置，粘贴你需要使用的 API Key（Anthropic、OpenAI、Gemini、DeepSeek、MiniMax、Kimi、Qwen……），可点「测试」即时校验；在 LM Studio / 自定义端点卡片中填写本地或自托管服务地址。
5. 把 PDF 拖入知识库标签页（如需启用私有 KB）。
6. 在主输入区输入问题、选择研究深度，开始。
7. 如需预测：把工具栏切换到 **Forecast**，让引导助手完成 DeepResearchForecast 后端的安装与启动（或在 设置 → Forecast 指向已有检出目录），然后提问「某个社会将如何对某事件作出反应」。

### 手动启动 sidecar
若自动拉起失败（PATH 异常 / 缺 Python），可手动启动：
```bash
cd sidecar
python3 seekdb_sidecar.py
```
App 会通过 `/health` 自动发现已运行的 sidecar 并连接。

---

## 项目结构

```
Swift Deep Research/
├── Bootstrap/        # App 生命周期、依赖装配
├── Domain/           # 值类型：LLMMessage、LLMRequest、ResearchPlan、
│                     # ResearchEvent、AgentBudget、FetchedSource……
├── Engine/           # ResearchEngine、Planner、WorkerAgent（ReAct 循环）、
│                     # Synthesizer、Reflector、IterationController
├── Forecast/         # MiroFishClient（REST）、ForecastRun（流水线状态）、
│                     # MiroFishSupervisor（后端拉起/修复）、ForecastOnboarding
├── Interface/        # SwiftUI：MainScene、Composer、ResearchCanvas、
│                     # SourcePanel、KBChunkDetail、SettingsSheet、ConversationView
│   └── Forecast/     # 流水线步进器、KnowledgeGraphView（Grape）、模拟遥测、
│                     # 报告 + 对话、引导流程、后端浏览器
├── Knowledge/        # SeekDBClient、SidecarSupervisor（虚拟环境自举）、KnowledgeBase
├── LLM/              # 各家 LLM Provider 客户端（Anthropic、OpenAI、Gemini、
│                     # Ollama、FoundationModels、MLX）+ OpenAICompatibleClient
│                     #（DeepSeek/MiniMax/Kimi/LM Studio/自定义）统一在 LLMClient 协议之下
├── ResearchTools/    # 工具实现：WebSearchTool、WebReaderTool、
│                     # KnowledgeBaseTool、ArXivTool、WikipediaTool……
├── Shared/           # KeychainStore、日志、HTTP 工具
└── Storage/          # SwiftData @Model 持久化
sidecar/              # Python FastAPI seekdb sidecar
```

---

## 灵感与参考
- Anthropic《Building effective agents》与多 Agent 研究系统设计笔记
- **ReAct** 原论文（Yao 等人，*Reasoning + Acting in Language Models*）
- Perplexity / ChatGPT Search 的引文渲染范式
- 开源 Agent：STORM、GPT-Researcher、smolagents
- Forecast 技术栈：DeepResearchForecast、字节跳动 **DeerFlow**、本地 **Graphiti** 时序知识图谱（内嵌 FalkorDB）、CAMEL-AI **OASIS** 社会模拟、**Grape** 力导向图

---

## License
MIT，详见 `LICENSE`。
