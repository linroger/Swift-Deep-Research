# Swift Deep Research

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-red" />
  <img src="https://img.shields.io/badge/Swift-5.9-orange" />
  <img src="https://img.shields.io/badge/License-MIT-green" />
  <img src="https://img.shields.io/badge/Platform-Apple%20Silicon-blue" />
</p>

**Swift Deep Research** is an open-source macOS application that brings AI-powered deep research to your desktop. It leverages Large Language Models (LLMs) to autonomously conduct multi-step web research — generating search queries, extracting content, analyzing findings iteratively, and synthesizing comprehensive answers with source citations.

Built with 100% Swift and SwiftUI, it runs entirely on your Mac (Apple Silicon) with optional cloud LLM support.

---

## Screenshots

| | |
|:--|:--:|
| **Main Chat View** — Research results with structured academic format, source citations, and sidebar navigation | ![Main Chat View](./Swift%20Deep%20Research%202026-04-15%20at%2005.04.37@2x.png) |
| **Sources Panel** — All 24 cited sources from the research, organized with direct links to original content | ![Sources Panel](./Swift%20Deep%20Research%202026-04-15%20at%2005.13.16@2x.png) |
| **Settings** — Provider configuration for Gemini, Ollama (local), and MLX (on-device) | ![Settings](./Swift%20Deep%20Research%202026-04-15%20at%2005.13.21@2x.png) |
| **Research Progress** — Real-time view of the agent's iterative reasoning loop: generated queries, sources found, and analysis steps | ![Research Progress](./Swift%20Deep%20Research%202026-04-15%20at%2005.30.33@2x.png) |

---

## Features

### Deep Research Agent
- **Iterative Research Loop**: The agent autonomously searches, extracts, and analyzes web content in a reasoning loop until a comprehensive answer is synthesized
- **Smart Query Generation**: Uses the LLM to generate diverse, effective search queries
- **Source Citations**: Every claim is backed by cited sources with clickable links
- **Research Progress Tracking**: Real-time view of each research step, URLs being read, and findings

### Triple LLM Provider Support
Switch between three provider types in Settings:

| Provider | Type | Models | Notes |
|----------|------|--------|-------|
| **Gemini** | Cloud | Gemini 1.5 Flash 8B, 1.5 Pro, 2.0 Flash, 2.0 Pro | Requires Google API key |
| **Ollama** | Local Server | Any Ollama-compatible model | Streams responses, model management built-in |
| **MLX** | On-Device (Apple Silicon) | Mistral Small 24B, Qwen 2.5 7B, DeepSeek R1 Distill | Privacy-first, runs fully offline |

### AI Memory System
- The agent can save memories during research using `[MEMORY:category]content[/MEMORY]` markers
- Categories: `preference`, `project`, `insight`, `correction`, `instruction`, `general`
- Memories are injected into the system prompt for persistent context
- Manual CRUD operations via the Memory panel (Cmd+Shift+M)

### Web Content Extraction
- **Generic Websites**: Parses HTML via SwiftSoup, removing scripts/styles/navigation clutter
- **Reddit**: Specialized client with recursive comment fetching and rate limiting
- **Redirect Resolution**: Automatically resolves DuckDuckGo redirects to final URLs

### Conversation Management
- Multiple concurrent research conversations with sidebar navigation
- Auto-titled from the first user message
- Up to 50 conversations persisted in UserDefaults
- Keyboard shortcut: Cmd+N for new conversation

### Custom Prompts
- Define and manage custom system prompts with templates
- Quick access via Cmd+Shift+P
- Adjust research behavior, tone, and output format

---

## Architecture

Swift Deep Research follows **MVVM** (Model-View-ViewModel) with a service-oriented design.

```
┌─────────────────────────────────────────────────────────────┐
│                    Swift_Deep_ResearchApp                    │
│                      (App Entry Point)                        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                         AppState                             │
│                    (Global Singleton State)                   │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────────────┐   │
│  │ LLMProvider │ │MemoryManager │ │ConversationManager │   │
│  └─────────────┘ └──────────────┘ └────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
     │  ChatView    │ │SettingsView  │ │MemoryListView│
     │ (Main Chat)  │ │              │ │              │
     └──────────────┘ └──────────────┘ └──────────────┘
              │
              ▼
     ┌──────────────┐       ┌──────────────────────────────────┐
     │ ChatViewModel│──────▶│           Agent                  │
     └──────────────┘       │  (Research Orchestration Loop)   │
                            └──────────────────────────────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
           ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
           │SearchService │  │WebReaderSvc  │  │ LLMProvider   │
           │ (DuckDuckGo) │  │(SwiftSoup)   │  │(Gemini/Ollama)│
           └──────────────┘  └──────────────┘  └──────────────┘
```

### Key Components

| Layer | Directory | Purpose |
|-------|-----------|---------|
| **Models** | `Models/` | Data structures (Memory, Conversation, AppSettings, CustomPrompt, ModelConfiguration) |
| **Core** | `Core/` | Agent orchestrator, LLM response parser, protocol definitions |
| **Services** | `Services/` | LLM providers (Gemini, Ollama, MLX), Search, WebReader, Reddit API |
| **Views** | `Views/` | SwiftUI views, ViewModels, chat bubble, research steps, settings |
| **LLMLibrary** | `LLMLibrary/` | Local LLM model management UI |

### Research Loop Flow (Agent.swift)

```
User Input
    │
    ▼
┌─────────────────┐
│ Generate Queries│◀──────┐
└────────┬────────┘       │
         ▼                │
┌─────────────────┐       │
│   Web Search    │       │
│  (DuckDuckGo)   │       │
└────────┬────────┘       │
         ▼                │
┌─────────────────┐       │
│Extract Content  │       │
│ (SwiftSoup)     │       │
└────────┬────────┘       │
         ▼                │
┌─────────────────┐       │
│  LLM Analysis   │───────┤ (iterative loop)
│  (action:       │       │
│   answer/search/│       │
│   reflect)      │       │
└────────┬────────┘       │
         ▼                │
┌─────────────────┐       │
│ Final Synthesis │───────┘
└────────┬────────┘
         ▼
   Final Answer
   (with citations)
```

---

## Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon Mac** (M1/M2/M3/M4) — required for on-device MLX models
- **Intel Mac** — supported with Gemini or Ollama providers only
- **12GB+ RAM** recommended for local LLM execution

---

## Installation

### From Source

1. Clone the repository:
```bash
git clone https://github.com/linroger/Swift-Deep-Research.git
cd Swift-Deep-Research
```

2. Open in Xcode:
```bash
open "Swift Deep Research.xcodeproj"
```

3. Select your target Mac and click Run

### Configure LLM Provider

1. Open the app → **Settings** (gear icon or Cmd+,)
2. Choose your provider tab:
   - **Gemini**: Enter your Google API key
   - **Ollama**: Ensure Ollama is running locally (`ollama serve`)
   - **MLX**: Select a model (Qwen 2.5 7B recommended for first run)

---

## Usage

### Basic Research

1. Launch the app
2. Type your research question in the chat input
3. Press Enter or click Send
4. Watch the research agent work in real-time
5. Receive a comprehensive answer with source citations

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Cmd+N` | New research conversation |
| `Cmd+,` | Open Settings |
| `Cmd+Shift+M` | Open Memory panel |
| `Cmd+Shift+P` | Open Custom Prompts |

### Memory Commands

During research, the agent can save memories. You can also manually add memories:

```
[MEMORY:preference]I prefer concise answers with bullet points[/MEMORY]
[MEMORY:project]Current project: investigating LLM architectures[/MEMORY]
```

---

## Project Structure

```
Swift Deep Research/
├── Swift_Deep_ResearchApp.swift    # App entry point, command menu
├── AppState.swift                  # Global singleton state
├── ContentView.swift               # Root SwiftUI view
├── Core/
│   ├── Agent.swift                 # Research orchestrator
│   ├── LLMResponseParser.swift     # JSON response parsing
│   └── Protocols.swift            # Provider protocols
├── Models/
│   ├── Memory.swift                # MemoryEntry & MemoryManager
│   ├── Conversation.swift          # Conversation & ConversationManager
│   ├── AppSettings.swift           # UserDefaults settings
│   ├── ModelConfiguration.swift    # MLX model configs
│   └── CustomPrompt.swift          # CustomPrompt & Manager
├── Services/
│   ├── GeminiProvider.swift        # Google Gemini API
│   ├── OllamaProvider.swift        # Local Ollama server
│   ├── LocalLLMProvider.swift     # Apple MLX on-device
│   ├── SearchService.swift         # DuckDuckGo search
│   ├── WebReaderService.swift     # SwiftSoup content extraction
│   └── RedditAPI.swift            # Reddit API client
├── Views/
│   ├── ChatView.swift              # Main chat UI
│   ├── ChatViewModel.swift         # Chat coordination
│   ├── ChatBubbleView.swift        # Message bubbles w/ Markdown
│   ├── ChatMessage.swift           # ChatMessage & SourceCitation
│   ├── SettingsView.swift          # Multi-tab settings
│   ├── ResearchStepsView.swift     # Research progress UI
│   ├── MemoryListView.swift        # Memory management UI
│   └── PromptEditorView.swift      # System prompt editor
└── LLMLibrary/
    ├── LLMLibraryView.swift        # Model management UI
    └── LLMLibraryViewModel.swift   # Model list ViewModel
```

---

## Technical Details

### LLM Provider Protocol

All LLM providers conform to `LLMProviderProtocol`:

```swift
protocol LLMProviderProtocol: AnyObject {
    var providerName: String { get }
    func generateResponse(messages: [ChatMessage], stream: Bool) async throws -> String
    func generateResponseStream(messages: [ChatMessage]) -> AsyncStream<String>
}
```

### Search Service

Uses DuckDuckGo HTML search with SwiftSoup parsing. Results are filtered to the top 5 URLs per query, with automatic redirect resolution.

### Content Extraction

- **Generic**: SwiftSoup-based HTML parsing with element filtering (removes `<script>`, `<style>`, `<nav>`, `<footer>`, `<iframe>`)
- **Reddit**: Dedicated API client with recursive comment fetching and Reddit's rate limits respected

### Data Persistence

- **Conversations**: UserDefaults via `ConversationManager`
- **Settings**: UserDefaults via `AppSettings`
- **Memories**: UserDefaults via `MemoryManager`
- **Custom Prompts**: UserDefaults via `CustomPromptManager`

---

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

---

## License

MIT License — see LICENSE file for details.

---

## Acknowledgments

- Built with [SwiftUI](https://developer.apple.com/xcode/swiftui/), [SwiftSoup](https://github.com/scinfu/SwiftSoup), and [MLX](https://github.com/ml-explore/mlx)
- Inspired by cloud deep research features from ChatGPT, Perplexity, and Gemini
