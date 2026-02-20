# CodeForge

## 🎯 Product Vision
A native macOS agentic code editor purpose-built for Apple Silicon M4 Macs, delivering a premium single-file editing experience with an embedded AI assistant powered by a local MLX model — no cloud, no server, no compromise on privacy.

## ❓ Problem Statement
Existing code editors on macOS are either bloated Electron apps with poor native performance, or lightweight editors lacking AI assistance. Developers on M4 Macs have no editor that fully exploits Apple Silicon for local AI inference while providing a fast, native, privacy-respecting coding experience.

## 🎯 Goals
- Deliver a premium native macOS code editor optimized for M4 Apple Silicon
- Provide accurate syntax highlighting for Swift and Python via TreeSitter
- Integrate a local AI agent using MLX that can read, explain, and suggest edits to the current file without any network dependency
- Include an integrated terminal for running scripts and commands
- Ensure all data and AI inference stays on-device with zero cloud requirement
- Achieve sub-100ms launch time and buttery 120fps scrolling leveraging Metal
- Support offline-first operation with SwiftData persistence and optional CloudKit sync

## 🚫 Non-Goals
- Language Server Protocol (LSP) integration
- Multi-file project management or workspace support
- Extension or plugin system
- Support for macOS versions prior to 15 (Sequoia)
- Cloud-hosted AI models or API-based inference
- Collaborative real-time editing
- Support for languages beyond Swift and Python in v1
- Git integration or version control UI

## 👥 Target Users
- Solo developers on M4 Macs who want a fast, native, AI-assisted editor for quick scripting and single-file work
- Privacy-conscious developers who refuse to send code to cloud AI services
- Swift and Python developers seeking a lightweight alternative to Xcode or VS Code for focused editing sessions
- Power users who value native macOS design language, keyboard-driven workflows, and Apple Silicon performance

## 🧩 Core Features
- [object Object]
- [object Object]
- [object Object]
- [object Object]
- [object Object]
- [object Object]
- [object Object]

## ⚙️ Non-Functional Requirements
- Launch to editable state in under 100ms on M4 MacBook Pro
- Syntax highlighting must not block the main thread; TreeSitter parsing runs on a background actor
- AI inference must stream tokens at 30+ tokens/second on M4 using MLX
- Memory usage under 200MB with a file up to 50,000 lines open
- All user data encrypted at rest using AES-256 with Keychain-stored keys
- Zero network calls in default configuration; CloudKit sync is opt-in
- Full VoiceOver accessibility for all editor and AI panel interactions
- Keyboard-navigable UI with customizable key bindings stored in SwiftData
- App must be fully functional without Rosetta — arm64 native only
- Structured Concurrency throughout; no unstructured Task usage outside of explicit cancellation scopes

## 📊 Success Metrics
- Cold launch to interactive editor in under 100ms (p95) on M4 hardware
- AI agent responds with first token in under 500ms for files under 1000 lines
- TreeSitter re-parse completes within one frame (8ms) for incremental edits
- Crash-free rate above 99.9% in first 30 days post-launch
- User retention: 40% of installers use the app at least 3 days per week after first month
- Terminal command execution latency within 5ms of native Terminal.app
- Export/import round-trip preserves 100% of user data fidelity

## 📌 Assumptions
- Target hardware is M4 Mac or later with at least 16GB unified memory for comfortable MLX inference
- A suitable quantized LLM (e.g., CodeLlama 7B Q4) can run at acceptable quality and speed via MLX on M4
- TreeSitter Swift and Python grammars are stable and maintained for the parsing needs of v1
- macOS 15 Sequoia APIs (SwiftUI 6, Observation framework, SwiftData) are stable for production use
- Users are comfortable downloading a bundled or separately fetched MLX model (1-4GB) on first launch
- Single-file editing covers a meaningful use case for the target audience without project-level features
- CloudKit sync for settings uses last-write-wins; full CRDT conflict resolution is deferred beyond v1 since collaborative editing is a non-goal

## ❓ Open Questions
- Which specific MLX model should be bundled or recommended — CodeLlama 7B, DeepSeek Coder 6.7B, or a fine-tuned variant?
- Should the AI conversation history be per-file or global across sessions?
- What is the maximum file size the editor should gracefully handle before warning the user?
- Should the app be distributed via the Mac App Store, direct download, or both — and how does sandboxing affect terminal and file access?
- How should the AI agent handle context that exceeds the local model's token window — truncation, summarization, or sliding window?
- Should there be a model download/management UI, or should the model be bundled in the app binary?
- What is the encryption strategy for CloudKit-synced data — encrypt before upload, or rely on CloudKit's built-in encryption?
- Should the integrated terminal support multiple tabs or sessions, or strictly one terminal instance in v1?