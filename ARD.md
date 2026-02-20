# Architecture Requirements Document

## 🧱 System Overview
CodeForge is a native macOS single-file code editor for M4 Apple Silicon Macs. It combines TreeSitter-powered syntax highlighting for Swift and Python, an integrated terminal, and a local AI agent running on-device via MLX/CoreML. The architecture is local-first: all data persists in SwiftData with optional CloudKit sync. Zero network calls in default configuration. Built entirely with SwiftUI 6 and Swift 6 Structured Concurrency targeting macOS 15+ Sequoia.

## 🏗 Architecture Style
Local-first monolithic native macOS app using MVVM with the Observation framework. Single-process architecture with isolated concurrency domains: UI on MainActor, TreeSitter parsing on a background actor, AI inference on a dedicated MLX actor, terminal I/O on an async stream actor. No server, no IPC beyond pseudoterminal communication with the shell subprocess.

## 🎨 Frontend Architecture
- **Framework:** SwiftUI 6 targeting macOS 15+ Sequoia. NSWindow customization for premium chrome with .ultraThinMaterial and .regularMaterial vibrancy. matchedGeometryEffect for panel transitions, PhaseAnimator for AI streaming token animations, TimelineView for cursor blink and terminal refresh. Menu bar scene for quick actions, Settings scene for preferences. Full VoiceOver accessibility on all interactive elements.
- **State Management:** Observation framework (@Observable) for all view models. Three primary observable models: EditorModel (file content, cursor, selection, undo stack), AIAgentModel (conversation history, streaming state, model status), TerminalModel (output buffer, process state). No Combine, no ObservableObject. State flows unidirectionally from models to views. SwiftData @Model types for persistence, observed via @Query in settings views only.
- **Routing:** Single-window app with a three-panel layout: editor (center), AI panel (trailing sidebar, collapsible), terminal (bottom, collapsible). NavigationSplitView not needed — panels toggle via toolbar buttons and keyboard shortcuts. Settings scene opens as a separate window via Settings { }. No deep navigation hierarchy; all state is flat and panel-based.
- **Build Tooling:** Xcode 16+ with Swift 6 language mode strict concurrency. Swift Package Manager for dependencies: TreeSitter (swift-tree-sitter), MLX Swift bindings (mlx-swift), and a pseudoterminal library. Metal shader compilation at build time for editor gutter glow and selection effects. Asset catalogs for SF Symbols and accent colors. No CocoaPods, no external build systems.

## 🧠 Backend Architecture
- **Approach:** No backend server. All logic runs in-process on the user's Mac. The app is structured as four concurrency domains (actors): MainActor for UI, ParsingActor for TreeSitter incremental parsing, InferenceActor for MLX model loading and token generation, and TerminalActor for pseudoterminal I/O. Communication between actors uses Swift Structured Concurrency (async/await, AsyncStream, TaskGroup). No unstructured Task usage outside explicit cancellation scopes.
- **API Style:** No network API. Internal communication is actor-to-actor via async method calls and AsyncStreams. The AI agent exposes a simple protocol: func explain(selection: String, fileContext: String) -> AsyncStream<String>, func answer(question: String, fileContext: String) -> AsyncStream<String>, func suggestEdit(instruction: String, fileContext: String) -> AsyncStream<String>.
- **Services:**
- EditorService: Manages file I/O (open, save, autosave), undo/redo stack, and text buffer. Runs on MainActor. Notifies ParsingActor on every edit via an AsyncStream of text changes.
- ParsingService: Wraps TreeSitter via swift-tree-sitter. Runs on a dedicated background actor. Performs incremental re-parsing within 8ms per edit. Emits syntax highlight ranges as an AsyncStream consumed by the editor view.
- AIAgentService: Manages MLX model lifecycle (load, warm, infer, unload). Runs on InferenceActor. Accepts the current file content as context, streams generated tokens back via AsyncStream. Supports three operations: explain selection, answer question, suggest edit. Handles context window limits via truncation with a sliding window over the file.
- TerminalService: Spawns a shell subprocess via posix_openpt/forkpty. Runs on TerminalActor. Bridges pseudoterminal I/O to AsyncStreams for the terminal view. Supports one terminal session in v1.
- PersistenceService: Thin wrapper over SwiftData ModelContext. Stores user preferences, key bindings, recent files, and AI conversation history. All reads/writes hit local SwiftData first. Optional CloudKit sync uses last-write-wins for settings only.
- EncryptionService: Encrypts sensitive data at rest using AES-256 with keys stored in the macOS Keychain. Wraps Security framework APIs. Applied to AI conversation history and any cached file content in SwiftData.

## 🗄 Data Layer
- **Primary Store:** SwiftData with a local SQLite backing store. Four @Model types: UserPreferences (theme, font, key bindings), RecentFile (path, last opened, cursor position), AIConversation (file path, messages array, timestamp), and KeyBinding (action, key combo, scope). All models are local-first with immediate writes. Optional CloudKit sync enabled per-model for UserPreferences and KeyBinding only — no file content or AI history synced to cloud.
- **Relationships:** AIConversation has a one-to-many relationship with AIMessage (role, content, timestamp). RecentFile is standalone with no relationships. UserPreferences is a singleton. KeyBinding references an action enum. No complex relationship graphs — the data model is intentionally flat for a single-file editor. No CRDT needed in v1 since there is no collaborative editing; last-write-wins suffices for CloudKit settings sync.
- **Migrations:** SwiftData lightweight migration with VersionedSchema. v1 schema is the baseline. Future schema changes use SchemaMigrationPlan with explicit MigrationStage definitions. No manual SQLite migrations. CloudKit schema evolution handled by SwiftData's automatic CloudKit schema management.

## ☁️ Infrastructure
- **Hosting:** No hosting. Fully local macOS app distributed as a signed and notarized .dmg for direct download. Mac App Store distribution evaluated but deferred due to sandbox restrictions on terminal subprocess spawning and arbitrary file access. The MLX model is downloaded on first launch from a bundled URL into ~/Library/Application Support/CodeForge/Models/ with integrity verification via SHA-256 checksum.
- **Scaling Strategy:** Not applicable — single-user local app. Performance scaling is handled via concurrency architecture: TreeSitter parsing scales with file size using incremental edits (O(log n) re-parse). MLX inference scales with M4 GPU/ANE cores automatically. Terminal I/O is bounded by shell subprocess throughput. Memory budget is 200MB max with a 50,000-line file open. Metal shaders offload visual effects from CPU entirely.
- **CI/CD:** Xcode Cloud or GitHub Actions with macOS arm64 runners. Build pipeline: Swift 6 strict concurrency compilation, unit tests (XCTest) for all service actors, UI tests (XCUITest) for editor and AI panel interactions, TreeSitter grammar validation, notarization via notarytool. No server deployment. Release artifacts are signed .dmg files uploaded to a static download page.

## ⚖️ Key Trade-offs
- Local MLX inference trades cloud-level model quality for complete privacy and zero latency variance. A quantized 7B model on M4 delivers acceptable code understanding but cannot match GPT-4 class reasoning. This is an intentional product decision aligned with the privacy-first value proposition.
- Single-file architecture trades project-level features for radical simplicity. No workspace, no file tree, no LSP. This constrains the user to one file at a time but enables a focused, fast, and maintainable v1 codebase with minimal state management complexity.
- SwiftData over raw SQLite trades fine-grained query control for rapid development and automatic CloudKit sync. SwiftData's ORM overhead is negligible for the small data volumes in a single-file editor (preferences, recent files, conversation history).
- Last-write-wins CloudKit sync trades conflict resolution correctness for implementation simplicity. Since there is no collaborative editing and sync is limited to user preferences, conflicts are rare and low-impact. Full CRDT resolution is deferred beyond v1.
- Dedicated actors per concern (parsing, inference, terminal) trade memory overhead for strict data isolation and elimination of data races under Swift 6 strict concurrency. Four actors is the minimum viable isolation for this app's concurrent workloads.
- Bundling TreeSitter grammars for only Swift and Python trades language breadth for smaller binary size and reduced maintenance burden. Adding languages later requires shipping updated grammar binaries but no architectural changes.

## 📐 Non-Functional Requirements
- Cold launch to interactive editor in under 100ms (p95) on M4 MacBook Pro. Measured from process start to first editable character input accepted.
- TreeSitter incremental re-parse completes within one frame (8ms at 120fps) for single-character edits in files up to 50,000 lines.
- MLX AI agent streams first token within 500ms of request for files under 1,000 lines. Sustained generation at 30+ tokens/second on M4 with 16GB unified memory.
- Memory usage under 200MB with a 50,000-line file open, AI model loaded, and terminal session active.
- All user data encrypted at rest using AES-256 with keys stored in macOS Keychain. No plaintext secrets on disk.
- Zero network calls in default configuration. CloudKit sync is opt-in and disabled by default.
- Full VoiceOver accessibility for all editor, AI panel, and terminal interactions. All interactive elements have accessibility labels and traits.
- Keyboard-navigable UI with customizable key bindings. All primary actions reachable without mouse input.
- arm64 native only. No Rosetta dependency. No x86_64 slice in the universal binary.
- Structured Concurrency throughout. No unstructured Task creation outside explicit cancellation scopes. Swift 6 strict concurrency mode with zero warnings.
- Crash-free rate above 99.9% in first 30 days post-launch. All actor boundaries enforce Sendable compliance.
- Terminal command execution latency within 5ms of native Terminal.app for interactive shell responsiveness.