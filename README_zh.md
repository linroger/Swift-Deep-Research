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

整个项目使用 Swift 6.2 / SwiftUI 为 macOS 26 Tahoe 从零构建，启用严格并发，统一封装跨厂商的结构化工具调用协议，UI 适配 Liquid Glass 设计语言。

---

## 截图

| | |
|:--|:--:|
| **主输入区** — Spotlight 风格的输入框，可切换研究深度、开启知识库，实时显示当前 LLM 提供方与模型 | ![Composer](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.17.21%402x.png) |
| **迭代研究画布** — 每一轮的规划、并行工作者状态、工具调用展开、右侧实时活动监控 | ![Canvas](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.17.39%402x.png) |
| **来源检视面板** — 已发现、已抓取、已引用的来源与正文同屏对照 | ![Sources](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.19.44%402x.png) |
| **知识库** — 拖入 PDF 即可通过 SeekDB sidecar 完成分块与向量化，研究过程中自动检索 | ![Knowledge Base](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2010.53.03%402x.png) |
| **设置页** — 为规划器 / 工作者 / 综合器分别选择 LLM，配置 API Key、sidecar 主机以及预算 | ![Settings](./Screenshots/Swift%20Deep%20Research%202026-05-26%20at%2011.17.46%402x.png) |

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
- **跨厂商统一的工具调用协议。** 同一份 `LLMRequest(messages:, tools:, …)` 信封会自动翻译成 Anthropic 的 `tool_use`、OpenAI 的 `tools[].function`、Gemini 的 `function_declarations`，以及 Ollama 的 `/api/chat tools` 字段，并对各家的流式 `tool_call` 增量做解析。
- **硬性预算上限。** 共享的 `BudgetMeter` actor 同时控制总挂钟时间、Token 上限、每工作者工具调用次数与来源数。Fast / Standard / Thorough 三档预设按比例放大所有维度。

---

## SeekDB —— 内嵌的私有知识库

绝大多数研究问题在你已有的文档里就已有答案。Swift Deep Research 把 **SeekDB**（`pyseekdb`）作为一等公民工具集成进 Agent 的工具目录，在访问公网之前**先**调用：

- **内嵌向量库。** 不依赖外部服务。App 自带轻量级 FastAPI **sidecar**，首次启动时自动拉起（`SidecarSupervisor` 监听 `/health`，并自动拼接 pyenv / Homebrew 的 PATH 来定位 Python）。退出 App 时 sidecar 同步关闭。
- **拖拽即入库。** 把 PDF 拖到知识库标签页，sidecar 自动按 NLTK 句界进行分块、向量化并持久化到本地。
- **语义检索作为工具暴露。** 工作者的工具目录中包含 `knowledge_base(query, k)`。系统提示要求：只要私有文档可能相关，**先**调用知识库，再用网络检索做交叉印证。返回的命中结果通过相同的 `sourceDiscovered` / `sourceFetched` 事件流推送，引文抽取与检视器对它们一视同仁。
- **`kb://` 引文协议。** 知识库段落使用 `kb://<doc-id>/<chunk-id>` 形式的合成 URL，便于来源面板与正文 hover 区分私有命中与网页来源。

举个端到端的例子：把 DeepSeek-v4 论文 PDF 入库，输入 *"research the architectural innovations of DeepSeek-v4"*，工作者会先调用 `knowledge_base` 拿到 5 段高相关度内容，再发起 `web_search` 找最新基准评测——最终的综合报告同时引用你本地的私有 PDF 与近期的外部博客。

---

## 功能特性

### 多厂商 LLM 路由
规划器 / 工作者 / 综合器可分别指定不同的 LLM——规划阶段省钱，综合阶段堆料。

| 提供方 | 类型 | 备注 |
|---|---|---|
| **Ollama** | 本地服务 | 支持 qwen2.5 / llama3.3 / gpt-oss / mistral-small 等工具调用，上下文窗口自动设为 131,072 |
| **Anthropic** | 云端 | Claude Opus 4.x、Sonnet 4.x，原生 `tool_use` 流式 |
| **OpenAI** | 云端 | GPT-5.5 / 5.4 / 4.1 系列，SSE 流式与函数调用 |
| **Gemini** | 云端 | 2.0 / 2.5 Flash 与 Pro，函数调用 |
| **Foundation Models** | 端侧 | macOS 26 上的 Apple Intelligence（条件可用） |
| **MLX** | 端侧 | Mistral Small 24B、Qwen 2.5 7B、DeepSeek-R1 Distill |

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
- Python 3.10+（用于 SeekDB sidecar — `pip install pyseekdb fastapi uvicorn`）
- 可选：Anthropic / OpenAI / Gemini / Tavily / Exa / Brave 的 API Key（任意组合）
- 可选：本地 Ollama（`ollama serve`）+ 至少一个支持工具调用的模型

### 构建与运行
1. 用 Xcode 26 打开 `Swift Deep Research.xcodeproj`。
2. 构建（⌘B）并运行（⌘R）。
3. 首次启动时，App 会自动在 `127.0.0.1:9100` 拉起 SeekDB sidecar（`sidecar/seekdb_sidecar.py`）并等待其就绪。
4. 打开设置，粘贴你需要使用的 API Key。
5. 把 PDF 拖入知识库标签页（如需启用私有 KB）。
6. 在主输入区输入问题、选择研究深度，开始。

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
├── Interface/        # SwiftUI：MainScene、Composer、ResearchCanvas、
│                     # SourcePanel、SettingsSheet、ConversationView
├── Knowledge/        # SeekDBClient、SidecarSupervisor、KnowledgeBase actor
├── LLM/              # 各家 LLM Provider 客户端（Anthropic、OpenAI、Gemini、
│                     # Ollama、FoundationModels、MLX）统一在 LLMClient 协议之下
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

---

## License
MIT，详见 `LICENSE`。
