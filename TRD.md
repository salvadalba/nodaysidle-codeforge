# Technical Requirements Document

## 🧭 System Context
CodeForge is a local-first native macOS single-file code editor for M4 Apple Silicon Macs running macOS 15+ Sequoia. Built with SwiftUI 6 and Swift 6 Structured Concurrency using four isolated actor domains: MainActor (UI + EditorService), ParsingActor (TreeSitter incremental parsing), InferenceActor (MLX model inference), TerminalActor (pseudoterminal I/O). All data persists in SwiftData with SQLite backing store. Zero network calls in default configuration. MLX 4-bit quantized 7B model for on-device AI. Single-file editing for Swift and Python only. Distributed as signed/notarized .dmg. arm64-only, no Rosetta.

## 🔌 API Contracts
### AIAgent.explain
- **Method:** async
- **Path:** InferenceActor.explain(selection:fileContext:)
- **Auth:** none (in-process actor call)
- **Request:** selection: String (user-selected text, 1–5000 chars), fileContext: String (full file content truncated to model context window via sliding window centered on selection)
- **Response:** AsyncStream<String> — streaming tokens. Each element is 1–4 tokens of explanation text. Stream completes on EOS token or cancellation.
- **Errors:** modelNotLoaded: MLX model not yet loaded into memory, contextWindowExceeded: file + prompt exceed model context window after truncation, inferenceTimeout: generation exceeded 30s wall clock, taskCancelled: user cancelled or view dismissed

### AIAgent.answer
- **Method:** async
- **Path:** InferenceActor.answer(question:fileContext:)
- **Auth:** none (in-process actor call)
- **Request:** question: String (user natural language question, 1–2000 chars), fileContext: String (full file content truncated to context window via sliding window)
- **Response:** AsyncStream<String> — streaming tokens of answer text. Same streaming semantics as explain.
- **Errors:** modelNotLoaded, contextWindowExceeded, inferenceTimeout, taskCancelled

### AIAgent.suggestEdit
- **Method:** async
- **Path:** InferenceActor.suggestEdit(instruction:fileContext:)
- **Auth:** none (in-process actor call)
- **Request:** instruction: String (edit instruction, 1–2000 chars), fileContext: String (full file content). Response includes structured edit markers for apply/reject UI.
- **Response:** AsyncStream<EditSuggestion> where EditSuggestion = { range: Range<String.Index>, original: String, replacement: String, explanation: String }. Stream may emit multiple non-overlapping suggestions.
- **Errors:** modelNotLoaded, contextWindowExceeded, inferenceTimeout, taskCancelled, parseFailure: model output did not conform to edit suggestion format

### EditorService.openFile
- **Method:** async
- **Path:** EditorService.open(url:) -> FileDocument
- **Auth:** macOS file access (NSOpenPanel / security-scoped bookmark)
- **Request:** url: URL (file path). Validates file exists, is readable, is under 50,000 lines, and has .swift or .py extension.
- **Response:** FileDocument { content: String, url: URL, language: Language, encoding: String.Encoding }. Triggers ParsingActor.parse() on open.
- **Errors:** fileNotFound, fileNotReadable: permission denied, fileTooLarge: exceeds 50,000 lines, unsupportedLanguage: not .swift or .py, encodingError: not valid UTF-8

### EditorService.saveFile
- **Method:** async
- **Path:** EditorService.save(document:to:)
- **Auth:** macOS file access (security-scoped bookmark)
- **Request:** document: FileDocument (current buffer content), to: URL (save destination). Writes atomically via Data.write(to:options:.atomic).
- **Response:** Void on success. Updates RecentFile entry in SwiftData.
- **Errors:** writePermissionDenied, diskFull, atomicWriteFailed

### ParsingService.parse
- **Method:** async
- **Path:** ParsingActor.parse(content:language:) -> SyntaxTree
- **Auth:** none (in-process actor call)
- **Request:** content: String (full file text), language: Language enum (.swift | .python). For initial full parse on file open.
- **Response:** SyntaxTree wrapping TSTree. Emits [HighlightRange] via AsyncStream<[HighlightRange]> where HighlightRange = { range: NSRange, tokenType: TokenType }.
- **Errors:** grammarNotFound: TreeSitter grammar binary missing for language, parseTimeout: full parse exceeded 100ms

### ParsingService.applyEdit
- **Method:** async
- **Path:** ParsingActor.applyEdit(edit:) -> [HighlightRange]
- **Auth:** none (in-process actor call)
- **Request:** edit: TextEdit { range: NSRange, newText: String, newEndPoint: TSPoint }. Incremental re-parse using TSTree.edit() + ts_parser_parse().
- **Response:** [HighlightRange] — only the changed highlight ranges. Must complete within 8ms for single-character edits.
- **Errors:** invalidEditRange: range outside document bounds, incrementalParseFailed: falls back to full re-parse

### TerminalService.spawn
- **Method:** async
- **Path:** TerminalActor.spawnShell() -> TerminalSession
- **Auth:** none (local process spawning via forkpty)
- **Request:** No parameters. Spawns user's default shell ($SHELL or /bin/zsh) via forkpty(). Sets TERM=xterm-256color, COLUMNS=80, LINES=24.
- **Response:** TerminalSession { pid: pid_t, inputStream: AsyncStream<Data>, outputWriter: (Data) async -> Void }. inputStream yields shell stdout/stderr chunks.
- **Errors:** forkFailed: forkpty() returned -1, shellNotFound: $SHELL path invalid

### TerminalService.write
- **Method:** async
- **Path:** TerminalActor.write(data:)
- **Auth:** none
- **Request:** data: Data (user keyboard input encoded as UTF-8 bytes, including control sequences for arrow keys, Ctrl+C, etc.)
- **Response:** Void. Data written to pseudoterminal master fd.
- **Errors:** sessionTerminated: shell process has exited, writeFailed: write() syscall error

### TerminalService.resize
- **Method:** async
- **Path:** TerminalActor.resize(columns:rows:)
- **Auth:** none
- **Request:** columns: UInt16, rows: UInt16. Sends TIOCSWINSZ ioctl to pseudoterminal.
- **Response:** Void. Shell receives SIGWINCH.
- **Errors:** sessionTerminated, ioctlFailed

### PersistenceService.savePreferences
- **Method:** sync
- **Path:** PersistenceService.save(_ preferences: UserPreferences)
- **Auth:** none (local SwiftData write)
- **Request:** UserPreferences @Model instance with updated fields. Upserts singleton record.
- **Response:** Void. Triggers CloudKit sync if enabled.
- **Errors:** swiftDataWriteFailed, cloudKitSyncConflict: resolved via last-write-wins

### EncryptionService.encrypt
- **Method:** sync
- **Path:** EncryptionService.encrypt(data:) -> Data
- **Auth:** macOS Keychain access for AES-256 key retrieval
- **Request:** data: Data (plaintext bytes to encrypt). Key retrieved from Keychain on first call and cached in-memory.
- **Response:** Data (IV + AES-256-GCM ciphertext + authentication tag). 12-byte IV prepended.
- **Errors:** keychainAccessDenied, keychainKeyNotFound: generates new key on first use, encryptionFailed

### EncryptionService.decrypt
- **Method:** sync
- **Path:** EncryptionService.decrypt(data:) -> Data
- **Auth:** macOS Keychain access
- **Request:** data: Data (IV + ciphertext + tag as produced by encrypt).
- **Response:** Data (decrypted plaintext bytes).
- **Errors:** keychainAccessDenied, authenticationFailed: tampered ciphertext, decryptionFailed

## 🧱 Modules
### EditorModule
- **Responsibilities:**
- Render code editor view with line numbers, cursor, and selection using SwiftUI Canvas or NSTextView bridged via NSViewRepresentable
- Apply TreeSitter highlight ranges as NSAttributedString attributes for syntax coloring
- Manage undo/redo stack via UndoManager with coalesced text edits
- Handle keyboard input including customizable key bindings from KeyBinding SwiftData model
- Autosave to a temporary file every 5 seconds via a debounced timer if document is dirty
- Emit TextEdit structs to ParsingActor on every keystroke via AsyncStream
- **Interfaces:**
- EditorView: SwiftUI View — main code editor surface
- EditorModel: @Observable — content: String, cursorPosition: Int, selection: Range<String.Index>?, language: Language, isDirty: Bool, highlightRanges: [HighlightRange]
- EditorService: @MainActor class — open(url:), save(document:to:), autosave(), applyAISuggestion(EditSuggestion)
- **Dependencies:**
- ParsingModule
- PersistenceModule

### ParsingModule
- **Responsibilities:**
- Load TreeSitter grammars for Swift and Python from bundled .dylib files
- Maintain a single TSParser and TSTree instance per open file
- Perform full parse on file open and incremental re-parse on each text edit
- Convert TSTree nodes to [HighlightRange] using a language-specific highlight query (.scm file)
- Guarantee incremental re-parse within 8ms for single-character edits up to 50,000 lines
- **Interfaces:**
- ParsingActor: actor — parse(content:language:), applyEdit(edit:), highlightStream: AsyncStream<[HighlightRange]>
- SyntaxTree: struct wrapping TSTree pointer with Sendable conformance via nonisolated(unsafe)
- HighlightRange: struct { range: NSRange, tokenType: TokenType } where TokenType is an enum (keyword, string, comment, function, type, number, operator, punctuation, variable, plain)
- TextEdit: Sendable struct { range: NSRange, newText: String }

### AIAgentModule
- **Responsibilities:**
- Load a 4-bit quantized 7B MLX model from ~/Library/Application Support/CodeForge/Models/ on first use
- Download model on first launch with SHA-256 integrity check and progress UI
- Manage model lifecycle: load into unified memory, keep warm, unload on memory pressure (respond to NSNotification.Name.NSProcessInfoPowerStateDidChange or didReceiveMemoryWarning equivalent)
- Construct prompts from system template + file context + user query using a sliding window truncation strategy centered on selection or cursor position
- Stream generated tokens via AsyncStream with 30s timeout and user-cancellable Task
- Parse suggestEdit output into structured EditSuggestion values with range mapping back to document positions
- Persist conversation history to SwiftData AIConversation model encrypted via EncryptionService
- **Interfaces:**
- InferenceActor: actor — loadModel(), unloadModel(), explain(selection:fileContext:) -> AsyncStream<String>, answer(question:fileContext:) -> AsyncStream<String>, suggestEdit(instruction:fileContext:) -> AsyncStream<EditSuggestion>
- AIAgentModel: @Observable — messages: [AIMessage], isGenerating: Bool, modelState: ModelState enum (notDownloaded, downloading(progress), loaded, unloaded, error(String)), currentStreamingText: String
- AIAgentView: SwiftUI View — chat-style interface in trailing sidebar with streaming token animation via PhaseAnimator
- EditSuggestion: Sendable struct { range: Range<String.Index>, original: String, replacement: String, explanation: String }
- ModelState: Sendable enum { case notDownloaded, downloading(Double), loaded, unloaded, error(String) }
- **Dependencies:**
- EditorModule
- PersistenceModule
- EncryptionModule

### TerminalModule
- **Responsibilities:**
- Spawn a single shell subprocess via forkpty() with user's default shell
- Bridge pseudoterminal file descriptor I/O to Swift async streams
- Parse ANSI escape sequences for color, cursor movement, and clearing
- Render terminal output in a monospace SwiftUI view with 256-color support
- Forward user keyboard input to shell stdin including control sequences
- Handle SIGWINCH for terminal resizing when panel is resized
- Clean up subprocess on terminal close or app termination (SIGHUP then SIGKILL after 2s)
- **Interfaces:**
- TerminalActor: actor — spawnShell(), write(data:), resize(columns:rows:), terminate(), outputStream: AsyncStream<Data>
- TerminalModel: @Observable — outputBuffer: AttributedString (parsed ANSI output), isRunning: Bool, shellPID: pid_t?, columns: Int, rows: Int
- TerminalView: SwiftUI View — monospace rendered terminal with TimelineView for 60fps refresh, keyboard event forwarding
- TerminalSession: Sendable struct { pid: pid_t, masterFD: Int32 }

### PersistenceModule
- **Responsibilities:**
- Configure SwiftData ModelContainer with local SQLite store and optional CloudKit container
- Define all @Model types: UserPreferences, RecentFile, AIConversation, AIMessage, KeyBinding
- Provide ModelContext access scoped to MainActor for UI queries and background contexts for services
- Manage VersionedSchema and SchemaMigrationPlan for future schema evolution
- Enable CloudKit sync only for UserPreferences and KeyBinding when user opts in
- **Interfaces:**
- PersistenceService: @MainActor class — shared ModelContainer, save(), fetch<T: PersistentModel>(_:predicate:sortBy:), delete(_:)
- UserPreferences: @Model — id: UUID, theme: String, fontName: String, fontSize: Double, cloudKitSyncEnabled: Bool, createdAt: Date, updatedAt: Date
- RecentFile: @Model — id: UUID, filePath: String, lastOpened: Date, cursorPosition: Int, language: String
- AIConversation: @Model — id: UUID, filePath: String, createdAt: Date, encryptedMessages: Data
- AIMessage: Codable Sendable struct — role: Role enum (user, assistant, system), content: String, timestamp: Date
- KeyBinding: @Model — id: UUID, action: String, keyCombination: String, scope: String
- **Dependencies:**
- EncryptionModule

### EncryptionModule
- **Responsibilities:**
- Generate AES-256-GCM key on first launch and store in macOS Keychain under a service-specific identifier
- Retrieve key from Keychain for encrypt/decrypt operations, cache in-memory for session lifetime
- Encrypt AIConversation message data before SwiftData persistence
- Decrypt AIConversation message data on read
- Use 12-byte random IV per encryption operation, prepend to ciphertext
- **Interfaces:**
- EncryptionService: final class Sendable — encrypt(data:) throws -> Data, decrypt(data:) throws -> Data
- KeychainHelper: struct — save(key:service:account:), load(service:account:) -> Data?, delete(service:account:)

### AppShellModule
- **Responsibilities:**
- Define the top-level App struct with WindowGroup, Settings, and MenuBarExtra scenes
- Layout three-panel interface: center editor, trailing AI sidebar, bottom terminal
- Manage panel visibility state (AI panel collapsed/expanded, terminal collapsed/expanded)
- Apply NSWindow customization for .ultraThinMaterial toolbar and .regularMaterial sidebar
- Register global keyboard shortcuts and route to appropriate modules
- Handle app lifecycle: model preloading on launch, cleanup on termination
- **Interfaces:**
- CodeForgeApp: App struct — @main entry point with Scene declarations
- ContentView: SwiftUI View — three-panel layout container with toolbar
- AppModel: @Observable — isAIPanelVisible: Bool, isTerminalVisible: Bool, activePanel: Panel enum
- **Dependencies:**
- EditorModule
- AIAgentModule
- TerminalModule
- PersistenceModule

## 🗃 Data Model Notes
- UserPreferences is a singleton — fetch with FetchDescriptor<UserPreferences>(fetchLimit: 1). Create default on first launch.

- AIConversation.encryptedMessages stores the full [AIMessage] array encoded as JSON via JSONEncoder, then encrypted via EncryptionService.encrypt(). On read, decrypt then JSONDecode.

- RecentFile stores absolute file paths as Strings. On open, validate path still exists and is readable. Max 20 recent files maintained via LRU eviction on insert.

- KeyBinding.keyCombination uses a string format: 'modifiers+key' e.g. 'cmd+shift+p', 'ctrl+`'. Parsed at runtime into EventModifiers + KeyEquivalent.

- KeyBinding.action maps to an enum of editor actions: openFile, saveFile, toggleAIPanel, toggleTerminal, undo, redo, explain, suggestEdit, askQuestion.

- CloudKit sync uses automatic schema generation from SwiftData. Only UserPreferences and KeyBinding models have cloudKitContainerIdentifier set. AIConversation and RecentFile are local-only.

- All @Model types use UUID as primary key. No external identifiers needed for a single-user local app.

- AIMessage is not a @Model — it is a Codable struct stored as encrypted Data blob inside AIConversation. This avoids relationship overhead for a simple append-only log.

- SwiftData lightweight migration baseline is SchemaV1. No migrations needed until v2 schema changes.

## 🔐 Validation & Security
- File open validates: file exists, is regular file (not symlink to sensitive path), is readable, is under 50,000 lines, has .swift or .py extension, is valid UTF-8.
- File save writes atomically via Data.write(to:options:[.atomic]) to prevent corruption on crash or power loss.
- AI prompt construction sanitizes file content by escaping any prompt injection markers. File content is enclosed in delimiters the model is instructed to treat as data, not instructions.
- AI model files verified on download via SHA-256 checksum against a bundled expected hash. Redownload triggered if checksum fails.
- AES-256-GCM encryption key stored in macOS Keychain with kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly. Key never leaves Keychain except into process memory.
- Terminal subprocess inherits only PATH, HOME, SHELL, USER, LANG, TERM environment variables. No secrets passed to shell environment.
- No network calls in default configuration. CloudKit sync requires explicit user opt-in in Settings. Model download URL is hardcoded and pinned to a known host.
- All actor boundaries enforce Sendable. No mutable shared state. Swift 6 strict concurrency mode with -strict-concurrency=complete flag.
- NSOpenPanel and NSSavePanel used for all file access — no hardcoded paths except ~/Library/Application Support/CodeForge/ for app data.
- Security-scoped bookmarks stored for recent files to maintain sandbox-compatible access across launches.

## 🧯 Error Handling Strategy
Errors propagate via Swift typed throws within actor boundaries. Each actor defines a domain-specific error enum conforming to LocalizedError. UI-facing errors are caught at the ViewModel layer and presented via SwiftUI .alert() modifiers with user-actionable messages. Non-recoverable errors (model corruption, Keychain unavailable) present a single-action alert directing the user to app support. Recoverable errors (file not found, parse timeout) allow retry. AI inference errors fall back to a 'model unavailable' state in AIAgentModel. Terminal errors (shell exit, forkpty failure) display inline in the terminal view. All errors are logged to OSLog with appropriate log levels (fault for crashes, error for user-impacting, info for recoverable). No force-unwraps or try! in production code. Actor isolation guarantees no error can leave a module in an inconsistent state.

## 🔭 Observability
- **Logging:** OSLog with subsystem 'com.codeforge.app' and four categories: 'editor', 'parsing', 'inference', 'terminal'. Log levels: .fault for unrecoverable errors, .error for user-impacting failures, .info for lifecycle events (file open, model load, shell spawn), .debug for performance metrics. Logs viewable in Console.app with subsystem filter. No log output to stdout/stderr in release builds. Sensitive data (file contents, AI conversations) never logged.
- **Tracing:** SignpostID-based Instruments tracing via os_signpost for all performance-critical paths. Signpost intervals for: file open-to-ready, parse cycle, inference request-to-complete, terminal spawn. Viewable in Instruments.app with custom CodeForge instrument template. Points of Interest signposts for model load/unload events. No distributed tracing needed — single-process local app.
- **Metrics:**
- editor.fileOpen.duration — time from open request to editor ready (target: <50ms)
- parsing.incrementalParse.duration — time per incremental re-parse (target: <8ms p99)
- parsing.fullParse.duration — time for initial full parse (target: <100ms for 50K lines)
- inference.firstToken.latency — time from request to first streamed token (target: <500ms)
- inference.tokenRate — tokens per second during generation (target: >30 tps)
- inference.modelLoad.duration — time to load MLX model into memory (target: <3s)
- terminal.spawn.duration — time to spawn shell subprocess (target: <50ms)
- app.coldLaunch.duration — time from process start to first interactive frame (target: <100ms p95)
- app.memoryUsage — resident memory in MB (target: <200MB under full load)

## ⚡ Performance Notes
- TreeSitter incremental parsing is O(log n) for single-character edits. Full re-parse is O(n) but only triggered on file open or catastrophic parse tree corruption. Benchmark target: 8ms p99 for incremental, 100ms for full parse of 50K lines.
- MLX model inference runs on M4 GPU/ANE via unified memory. The 4-bit quantized 7B model requires approximately 4GB unified memory. Model kept warm (loaded) while AI panel is visible; unloaded on panel collapse after 60s idle to reclaim memory.
- Editor view uses NSTextView bridged via NSViewRepresentable rather than pure SwiftUI Text for performance with large files. NSTextStorage lazily applies highlight attributes only for visible line range + 100-line buffer above and below viewport.
- Terminal view refreshes at display refresh rate (120fps on ProMotion) via TimelineView but only redraws if outputBuffer has changed since last frame. ANSI parsing runs on TerminalActor, not MainActor.
- Autosave writes are debounced to 5-second intervals and execute on a background context to avoid blocking the editor during large file saves.
- Memory budget: EditorModule ~20MB (50K line NSTextStorage), ParsingModule ~10MB (TSTree + query cursors), AIAgentModule ~4GB (MLX model in unified memory, shared with GPU), TerminalModule ~5MB (scrollback buffer), PersistenceModule ~1MB. Total process RSS target: <200MB excluding MLX model unified memory pages shared with GPU.
- Cold launch path: App struct init → ContentView render → EditorView ready. No model loading, no file opening, no shell spawning on launch. All heavy initialization is lazy and triggered by user action. Target: <100ms to interactive.
- Metal shaders for gutter glow and selection effects are precompiled at build time via .metal files in the Xcode project. No runtime shader compilation.

## 🧪 Testing Strategy
### Unit
- ParsingActor: Test full parse and incremental edit for both Swift and Python grammars. Assert correct HighlightRange output for known code snippets. Benchmark incremental parse completes within 8ms for 50K line files.
- EncryptionService: Test encrypt/decrypt roundtrip with known plaintext. Test tampered ciphertext produces authenticationFailed error. Test key generation and Keychain storage/retrieval.
- EditorService: Test open/save file roundtrip. Test file validation rejects symlinks, non-UTF-8, oversized files, and unsupported extensions. Test autosave debounce behavior.
- AIAgentService prompt construction: Test sliding window truncation centers on selection. Test prompt template produces valid model input. Test EditSuggestion parsing from mock model output.
- PersistenceService: Test CRUD for all @Model types using in-memory SwiftData ModelContainer. Test recent file LRU eviction at 20 entries. Test AIConversation encryption roundtrip.
- KeyBinding parsing: Test key combination string parsing produces correct EventModifiers + KeyEquivalent pairs for all supported combinations.
- TerminalActor ANSI parsing: Test 256-color ANSI escape sequence parsing produces correct AttributedString attributes. Test cursor movement sequences. Test screen clear.
### Integration
- Editor + Parser integration: Open a real .swift file, type characters, verify highlight ranges update within 8ms. Verify undo/redo produces correct re-parse.
- Editor + AI Agent integration: Open a file, select code, invoke explain. Verify streaming tokens appear in AIAgentModel. Verify suggestEdit produces valid EditSuggestion with ranges that map correctly to document positions.
- AI Agent + Persistence: Invoke AI operations, verify AIConversation is persisted with encrypted messages. Reopen app, verify conversation history decrypts and displays correctly.
- Terminal integration: Spawn shell, send 'echo hello', verify 'hello' appears in outputBuffer. Test resize sends SIGWINCH. Test terminate cleans up subprocess.
- Full app integration: Launch app, open .py file, verify syntax highlighting, type code, invoke AI explain, run code in terminal, verify all panels function concurrently without data races.
### E2E
- XCUITest: Launch app → open .swift file via NSOpenPanel → verify editor displays content with syntax highlighting → select function body → click Explain in AI panel → verify streaming response appears → click Apply on suggestion → verify edit applied to document → save file → reopen and verify content persisted.
- XCUITest: Launch app → toggle terminal panel → verify shell prompt appears → type 'python3 -c print(42)' → verify '42' appears in terminal output → resize terminal panel → verify output reflows.
- XCUITest: Launch app → open Settings → change theme → verify editor re-renders with new theme colors → toggle CloudKit sync → verify preferences persist across app restart.
- XCUITest: VoiceOver audit — navigate all interactive elements with VoiceOver enabled, verify all elements have accessibility labels, verify focus order is logical.
- Performance XCUITest: Measure cold launch to interactive (p95 < 100ms), measure file open to editor ready (< 50ms), measure AI first token latency (< 500ms).

## 🚀 Rollout Plan
- Phase 0 — Project Setup (Week 1): Initialize Xcode project with Swift 6 strict concurrency. Add SPM dependencies: swift-tree-sitter, mlx-swift. Configure SwiftData ModelContainer and VersionedSchema. Set up OSLog categories. Create actor stubs for all four domains. Configure Xcode Cloud CI with arm64 runner.

- Phase 1 — Editor Core (Weeks 2–3): Implement NSTextView bridge with NSViewRepresentable. Build EditorModel and EditorService for file open/save. Integrate TreeSitter via ParsingActor with Swift and Python grammars. Implement syntax highlighting via NSTextStorage attributes. Add line numbers, cursor, selection. Wire undo/redo via UndoManager. Add autosave. Unit and integration tests for editor + parser.

- Phase 2 — Terminal (Week 4): Implement TerminalActor with forkpty() shell spawning. Build ANSI escape sequence parser. Create TerminalView with TimelineView refresh and keyboard forwarding. Implement resize via SIGWINCH. Add subprocess cleanup on termination. Unit and integration tests for terminal.

- Phase 3 — AI Agent (Weeks 5–7): Implement InferenceActor with MLX model loading, warm/unload lifecycle. Build model download flow with SHA-256 verification and progress UI. Implement prompt construction with sliding window context truncation. Build explain, answer, suggestEdit operations with AsyncStream output. Implement EditSuggestion parsing and apply/reject UI. Create AIAgentView chat interface with PhaseAnimator token streaming. Wire conversation persistence with encryption. Unit and integration tests for AI agent.

- Phase 4 — App Shell and Polish (Week 8): Build three-panel layout with toolbar toggles. Apply NSWindow .ultraThinMaterial customization. Implement customizable key bindings via Settings scene. Add Metal shaders for gutter glow and selection effects. Implement VoiceOver accessibility for all interactive elements. Add recent files tracking. Configure CloudKit sync opt-in for preferences.

- Phase 5 — Testing and Hardening (Week 9): Full XCUITest suite for all e2e scenarios. Performance benchmarking in Instruments. Memory profiling under max load. VoiceOver audit. Crash-free rate baseline in TestFlight-equivalent local testing. Fix all Swift 6 strict concurrency warnings.

- Phase 6 — Distribution (Week 10): Code-sign with Developer ID. Notarize via notarytool. Package as .dmg with background image and Applications alias. Set up static download page. Write release notes. Ship v1.0.

## ❓ Open Questions
- Which specific 7B MLX model to bundle? Candidates: CodeLlama-7B-Instruct (4-bit GGUF), DeepSeek-Coder-7B-Instruct (4-bit), or Qwen2.5-Coder-7B-Instruct (4-bit). Need to benchmark code understanding quality and tokens/sec on M4 with 16GB unified memory.
- Should the MLX model be bundled in the .dmg (adds ~4GB to download) or downloaded on first launch (adds first-run friction)? ARD specifies download on first launch — confirm this is acceptable UX.
- What is the exact context window size of the chosen MLX model after quantization? This determines the sliding window truncation parameters for file context injection.
- Should the editor use a pure NSTextView bridge or TextKit 2 (NSTextLayoutManager)? TextKit 2 is the modern path but has known issues with large documents on macOS 15. NSTextView with TextKit 1 is battle-tested.
- Should terminal scrollback buffer be capped? Unbounded scrollback can consume significant memory. Propose 10,000 lines default, configurable in Settings.
- How to handle .swift files that use Swift macros or result builders with deeply nested TreeSitter parse trees? May need to cap highlight depth or simplify token mapping for performance.
- Mac App Store vs direct distribution: The ARD defers MAS due to sandbox restrictions on forkpty(). Confirm that com.apple.security.temporary-exception.sbpl entitlements for pseudoterminal access are viable for direct distribution with notarization.
- Should AI conversation history have a retention limit? Unbounded history with large file contexts could grow the encrypted SwiftData blob significantly. Propose 50-conversation limit with oldest eviction.