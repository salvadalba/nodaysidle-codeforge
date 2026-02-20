# CodeForge — Native macOS Agentic Code Editor

## Project Overview
A native macOS single-file code editor for M4 Apple Silicon Macs with TreeSitter syntax highlighting, integrated terminal, and local AI agent powered by MLX. Local-first, zero cloud dependency.

## Architecture
- **Stack:** SwiftUI 6, Swift 6, SwiftData, macOS 15+ Sequoia, arm64-only
- **Concurrency:** Four isolated actors — MainActor (UI), ParsingActor (TreeSitter), InferenceActor (MLX), TerminalActor (PTY)
- **State:** @Observable via Observation framework. No Combine, no ObservableObject.
- **Persistence:** SwiftData with SQLite backing store. Optional CloudKit for preferences only.
- **Editor:** NSTextView bridged via NSViewRepresentable (TextKit 1, NOT TextKit 2)
- **AI:** mlx-swift for 4-bit quantized 7B model inference on-device
- **Terminal:** forkpty() shell subprocess with ANSI escape sequence parsing

## Mandatory Rules

### Do
- Use Swift 6 strict concurrency (-strict-concurrency=complete) in ALL files
- Use SwiftData for ALL persistence; Observation framework (@Observable) for state
- Target macOS 15+ arm64-only; deployment target 15.0
- Use OSLog with subsystem `com.codeforge.app` and categories: editor, parsing, inference, terminal
- Use actors for concurrency isolation: ParsingActor, InferenceActor, TerminalActor
- Verify offline CRUD works before adding any CloudKit sync
- Use AsyncStream for inter-actor communication
- Use typed throws with domain-specific error enums per actor
- Precompile all Metal shaders at build time (.metal files)
- Write unit tests for every service and actor
- Use security-scoped bookmarks for file access persistence
- Encrypt AI conversation history via AES-256-GCM before SwiftData storage
- Read the full specs in PRD.md, ARD.md, TRD.md, TASKS.md, AGENT.md before implementing

### Don't
- Do NOT introduce any server-side backend — this is fully local-first
- Do NOT use CoreML or NaturalLanguage — use mlx-swift for inference
- Do NOT use TextKit 2 (NSTextLayoutManager) — use TextKit 1 NSTextView
- Do NOT use LSP, multi-file projects, or extension systems
- Do NOT runtime-compile Metal shaders
- Do NOT use Combine or ObservableObject — use Observation framework only
- Do NOT use unstructured Task outside explicit cancellation scopes
- Do NOT use force-unwraps (!) or try! in production code
- Do NOT log sensitive data (file contents, AI conversations) via OSLog
- Do NOT hardcode file paths except ~/Library/Application Support/CodeForge/

## File Structure
```
CodeForge/
├── App/CodeForgeApp.swift
├── Actors/
│   ├── ParsingActor.swift
│   ├── InferenceActor.swift
│   └── TerminalActor.swift
├── Models/
│   ├── SchemaV1.swift
│   ├── AIMessage.swift
│   ├── EditorModel.swift
│   ├── AIAgentModel.swift
│   ├── TerminalModel.swift
│   ├── HighlightRange.swift
│   ├── TokenType.swift
│   ├── EditSuggestion.swift
│   └── VirtualScreenBuffer.swift
├── Services/
│   ├── PersistenceService.swift
│   ├── EncryptionService.swift
│   ├── KeychainHelper.swift
│   ├── EditorService.swift
│   ├── PromptBuilder.swift
│   ├── ModelDownloader.swift
│   ├── ANSIParser.swift
│   └── KeyBindingService.swift
├── Views/
│   ├── ContentView.swift
│   ├── EditorView.swift
│   ├── LineNumberGutter.swift
│   ├── AIAgentView.swift
│   ├── EditSuggestionOverlay.swift
│   ├── TerminalView.swift
│   └── SettingsView.swift
├── Shaders/
│   ├── GutterGlow.metal
│   └── SelectionEffect.metal
└── Resources/
    ├── highlights-swift.scm
    └── highlights-python.scm
```

## Data Models (SwiftData)
- **UserPreferences** — singleton, CloudKit-synced when opt-in
- **RecentFile** — local-only, 20-entry LRU eviction
- **AIConversation** — local-only, encrypted messages blob, 50-conversation LRU
- **AIMessage** — Codable Sendable struct (NOT @Model)
- **KeyBinding** — CloudKit-synced when opt-in

## Performance Targets
- Cold launch to interactive: <100ms (p95)
- TreeSitter incremental re-parse: <8ms per edit
- AI first token latency: <500ms
- Token streaming rate: >30 tokens/sec
- Memory usage: <200MB (excluding MLX model shared memory)

## Key Dependencies (SPM)
- swift-tree-sitter — TreeSitter Swift bindings
- mlx-swift — MLX on-device inference

## Implementation Order
Execute tasks in this order (each task is defined in AGENT.md):
1. Task 1: Project Foundation & Persistence Layer
2. Task 2: Editor Core with TreeSitter Syntax Highlighting
3. Task 3: Terminal Integration with forkpty and ANSI Parsing
4. Task 4: AI Agent with MLX On-Device Inference
5. Task 5: App Shell, Settings, Accessibility & Distribution

Build and verify after each task before moving to the next.
