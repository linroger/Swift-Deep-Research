# Swift Deep Research

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-red" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange" />
  <img src="https://img.shields.io/badge/License-MIT-green" />
  <img src="https://img.shields.io/badge/Platform-Apple%20Silicon-blue" />
</p>

**Swift Deep Research** 是一款开源 macOS 应用程序，将 AI 驱动的深度研究能力带到您的桌面。它利用大语言模型（LLM）自主进行多步网络研究——生成搜索查询、提取内容、迭代分析 findings，并综合生成带有来源引用的综合答案。

应用 100% 使用 Swift 和 SwiftUI 构建，可完全在 Mac（Apple Silicon）上运行，亦支持云端 LLM。

---

## 截图

| | |
|:--|:--:|
| **主聊天界面** — 结构化学术格式的研究结果，带来源引用和侧边栏导航 | ![主聊天界面](./Swift%20Deep%20Research%202026-04-15%20at%2005.04.37@2x.png) |
| **来源面板** — 研究中引用的全部 24 个来源，带到原始内容的直接链接 | ![来源面板](./Swift%20Deep%20Research%202026-04-15%20at%2005.13.16@2x.png) |
| **设置页面** — Gemini、Ollama（本地）和 MLX（设备端）提供商的配置 | ![设置页面](./Swift%20Deep%20Research%202026-04-15%20at%2005.13.21@2x.png) |
| **研究进度** — 智能体迭代推理循环的实时视图：生成的查询、找到的来源和分析步骤 | ![研究进度](./Swift%20Deep%20Research%202026-04-15%20at%2005.30.33@2x.png) |

---

## 功能特点

### 深度研究智能体
- **迭代研究循环**：智能体在推理循环中自主搜索、提取并分析网络内容，直至综合出完整答案
- **智能查询生成**：利用 LLM 生成多样化、有效的搜索查询
- **来源引用**：每个论点均有来源支撑，提供可点击链接
- **研究进度跟踪**：实时显示每个研究步骤、正在读取的 URL 及研究发现

### 三合一 LLM 提供商支持
在设置中切换三种提供商类型：

| 提供商 | 类型 | 模型 | 说明 |
|--------|------|------|------|
| **Gemini** | 云端 | Gemini 1.5 Flash 8B, 1.5 Pro, 2.0 Flash, 2.0 Pro | 需要 Google API 密钥 |
| **Ollama** | 本地服务器 | 任何 Ollama 兼容模型 | 流式响应，内置模型管理 |
| **MLX** | 设备端（Apple Silicon） | Mistral Small 24B, Qwen 2.5 7B, DeepSeek R1 Distill | 隐私优先，完全离线运行 |

### AI 记忆系统
- 智能体可在研究过程中使用 `[MEMORY:category]content[/MEMORY]` 标记保存记忆
- 分类：`preference`（偏好）、`project`（项目）、`insight`（洞察）、`correction`（纠正）、`instruction`（指令）、`general`（通用）
- 记忆被注入系统提示词中，提供持久上下文
- 通过记忆面板手动增删改查（Cmd+Shift+M）

### 网页内容提取
- **通用网站**：使用 SwiftSoup 解析 HTML，移除脚本/样式/导航栏等干扰元素
- **Reddit**：专用 API 客户端，支持递归评论获取并遵守速率限制
- **重定向解析**：自动解析 DuckDuckGo 重定向至最终 URL

### 对话管理
- 多会话并列研究，侧边栏导航
- 自动以第一条用户消息作为会话标题
- 最多在 UserDefaults 中保留 50 个会话
- 键盘快捷键：Cmd+N 新建会话

### 自定义提示词
- 定义和管理自定义系统提示词模板
- 快速访问：Cmd+Shift+P
- 调整研究行为、语气和输出格式

---

## 架构设计

Swift Deep Research 采用 **MVVM**（Model-View-ViewModel）架构，辅以服务导向设计。

```
┌─────────────────────────────────────────────────────────────┐
│                    Swift_Deep_ResearchApp                    │
│                      (应用入口点)                              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                         AppState                             │
│                    (全局单例状态管理)                           │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────────────┐   │
│  │ LLMProvider │ │MemoryManager │ │ConversationManager │   │
│  └─────────────┘ └──────────────┘ └────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
     │  ChatView    │ │SettingsView  │ │MemoryListView│
     │  (主聊天界面) │ │   (设置)     │ │  (记忆管理)   │
     └──────────────┘ └──────────────┘ └──────────────┘
              │
              ▼
     ┌──────────────┐       ┌──────────────────────────────────┐
     │ ChatViewModel│──────▶│           Agent                  │
     └──────────────┘       │  (研究编排循环)                     │
                            └──────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
           ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
           │SearchService │  │WebReaderSvc  │  │ LLMProvider  │
           │ (DuckDuckGo) │  │ (SwiftSoup)  │  │(Gemini/Ollama│
           └──────────────┘  └──────────────┘  └──────────────┘
```

### 核心组件

| 层级 | 目录 | 用途 |
|------|------|------|
| **Models** | `Models/` | 数据模型（Memory, Conversation, AppSettings, CustomPrompt, ModelConfiguration） |
| **Core** | `Core/` | Agent 编排器、LLM 响应解析器、协议定义 |
| **Services** | `Services/` | LLM 提供商（Gemini, Ollama, MLX）、搜索服务、网页读取器、Reddit API |
| **Views** | `Views/` | SwiftUI 视图、ViewModel、聊天气泡、研究步骤、设置页面 |
| **LLMLibrary** | `LLMLibrary/` | 本地 LLM 模型管理界面 |

### 研究循环流程（Agent.swift）

```
用户输入
    │
    ▼
┌─────────────────┐
│ 生成查询         │◀──────┐
└────────┬────────┘       │
         ▼                │
┌─────────────────┐       │
│   网页搜索       │       │
│  (DuckDuckGo)   │       │
└────────┬────────┘       │
         ▼                │
┌─────────────────┐       │
│  提取内容        │       │
│  (SwiftSoup)    │       │
└────────┬────────┘       │
         ▼                │
┌─────────────────┐       │
│  LLM 分析       │───────┤ (迭代循环)
│  (action:       │       │
│   answer/search │       │
│   /reflect)     │       │
└────────┬────────┘       │
         ▼                │
┌─────────────────┐       │
│  最终综合        │───────┘
└────────┬────────┘
         ▼
   最终答案
   (含引用来源)
```

---

## 系统要求

- **macOS 14.0+**（Sonoma 或更高版本）
- **Apple Silicon Mac**（M1/M2/M3/M4）— 设备端 MLX 模型必需
- **Intel Mac** — 仅支持 Gemini 或 Ollama 提供商
- **推荐 12GB+ 内存**（运行本地 LLM）

---

## 安装

### 从源码构建

1. 克隆仓库：
```bash
git clone https://github.com/linroger/Swift-Deep-Research.git
cd Swift-Deep-Research
```

2. 用 Xcode 打开：
```bash
open "Swift Deep Research.xcodeproj"
```

3. 选择目标 Mac，点击运行

### 配置 LLM 提供商

1. 打开应用 → **设置**（齿轮图标或 Cmd+,）
2. 选择提供商标签页：
   - **Gemini**：输入您的 Google API 密钥
   - **Ollama**：确保 Ollama 本地运行（`ollama serve`）
   - **MLX**：选择模型（首次运行推荐 Qwen 2.5 7B）

---

## 使用方法

### 基础研究

1. 启动应用
2. 在聊天输入框中输入研究问题
3. 按回车或点击发送
4. 观看研究智能体实时工作
5. 收到带有来源引用的综合答案

### 键盘快捷键

| 快捷键 | 功能 |
|--------|------|
| `Cmd+N` | 新建研究会话 |
| `Cmd+,` | 打开设置 |
| `Cmd+Shift+M` | 打开记忆面板 |
| `Cmd+Shift+P` | 打开自定义提示词 |

### 记忆指令

研究过程中，智能体可以保存记忆。您也可以手动添加记忆：

```
[MEMORY:preference]我希望答案简洁，用项目符号列出[/MEMORY]
[MEMORY:project]当前项目：研究 LLM 架构[/MEMORY]
```

---

## 项目结构

```
Swift Deep Research/
├── Swift_Deep_ResearchApp.swift    # 应用入口，命令菜单
├── AppState.swift                  # 全局单例状态
├── ContentView.swift               # 根 SwiftUI 视图
├── Core/
│   ├── Agent.swift                 # 研究编排器
│   ├── LLMResponseParser.swift     # JSON 响应解析
│   └── Protocols.swift             # 提供商协议定义
├── Models/
│   ├── Memory.swift                # MemoryEntry 和 MemoryManager
│   ├── Conversation.swift          # Conversation 和 ConversationManager
│   ├── AppSettings.swift           # UserDefaults 设置
│   ├── ModelConfiguration.swift    # MLX 模型配置
│   └── CustomPrompt.swift          # CustomPrompt 和 Manager
├── Services/
│   ├── GeminiProvider.swift        # Google Gemini API
│   ├── OllamaProvider.swift        # 本地 Ollama 服务器
│   ├── LocalLLMProvider.swift     # Apple MLX 设备端
│   ├── SearchService.swift         # DuckDuckGo 搜索
│   ├── WebReaderService.swift     # SwiftSoup 内容提取
│   └── RedditAPI.swift            # Reddit API 客户端
├── Views/
│   ├── ChatView.swift              # 主聊天界面
│   ├── ChatViewModel.swift         # 聊天协调器
│   ├── ChatBubbleView.swift        # 消息气泡（含 Markdown 渲染）
│   ├── ChatMessage.swift           # ChatMessage 和 SourceCitation
│   ├── SettingsView.swift          # 多标签页设置
│   ├── ResearchStepsView.swift     # 研究进度界面
│   ├── MemoryListView.swift        # 记忆管理界面
│   └── PromptEditorView.swift      # 系统提示词编辑器
└── LLMLibrary/
    ├── LLMLibraryView.swift        # 模型管理界面
    └── LLMLibraryViewModel.swift   # 模型列表 ViewModel
```

---

## 技术细节

### LLM 提供商协议

所有 LLM 提供商均遵循 `LLMProviderProtocol`：

```swift
protocol LLMProviderProtocol: AnyObject {
    var providerName: String { get }
    func generateResponse(messages: [ChatMessage], stream: Bool) async throws -> String
    func generateResponseStream(messages: [ChatMessage]) -> AsyncStream<String>
}
```

### 搜索服务

使用 DuckDuckGo HTML 搜索配合 SwiftSoup 解析。每次查询最多过滤 5 个 URL，并自动解析重定向。

### 内容提取

- **通用网站**：基于 SwiftSoup 的 HTML 解析，过滤元素（移除 `<script>`、`<style>`、`<nav>`、`<footer>`、`<iframe>`）
- **Reddit**：专用 API 客户端，支持递归评论获取，遵守 Reddit 速率限制

### 数据持久化

- **会话**：通过 `ConversationManager` 存储至 UserDefaults
- **设置**：通过 `AppSettings` 存储至 UserDefaults
- **记忆**：通过 `MemoryManager` 存储至 UserDefaults
- **自定义提示词**：通过 `CustomPromptManager` 存储至 UserDefaults

---

## 贡献

欢迎提交 Issue 或 Pull Request！

---

## 许可证

MIT 许可证 — 详见 LICENSE 文件。

---

## 致谢

- 基于 [SwiftUI](https://developer.apple.com/xcode/swiftui/)、[SwiftSoup](https://github.com/scinfu/SwiftSoup) 和 [MLX](https://github.com/ml-explore/mlx) 构建
- 灵感来源于 ChatGPT、Perplexity 和 Gemini 的云端深度研究功能
