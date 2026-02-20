# Agent Prompts — CodeForge

## Global Rules

### Do
- Use Swift 6 strict concurrency (-strict-concurrency=complete) in all files
- Use SwiftData for all persistence; SwiftUI Observation framework for state
- Target macOS 15+ arm64-only; use OSLog with subsystem com.codeforge.app
- Use actors for concurrency isolation: ParsingActor, InferenceActor, TerminalActor
- Verify offline CRUD works before adding CloudKit sync

### Don't
- Do NOT introduce any server-side backend; this is fully local-first
- Do NOT use CoreML or NaturalLanguage—use mlx-swift for on-device inference
- Do NOT use TextKit 2 (NSTextLayoutManager)—use TextKit 1 NSTextView bridge
- Do NOT use LSP, multi-file projects, or extension systems in v1
- Do NOT runtime-compile Metal shaders—precompile all .metal files at build time

---

## Task Prompts
### Task 1: Project Foundation & Persistence Layer

**Role:** Expert Swift 6 macOS Engineer specializing in SwiftData and CryptoKit
**Goal:** Scaffold Xcode project with SwiftData persistence, Keychain-backed AES-256-GCM encryption, and encrypted AI conversation storage

**Context**
Initialize the Xcode project with Swift 6 strict concurrency, define all SwiftData models (UserPreferences, RecentFile, AIConversation, AIMessage, KeyBinding), build PersistenceService with CRUD and LRU eviction, implement AES-256-GCM EncryptionService with Keychain-backed key storage, and wire encrypted AIConversation persistence. CloudKit sync is opt-in for UserPreferences and KeyBinding only.

**Files to Create**
- CodeForge/App/CodeForgeApp.swift
- CodeForge/Models/SchemaV1.swift
- CodeForge/Models/AIMessage.swift
- CodeForge/Services/PersistenceService.swift
- CodeForge/Services/EncryptionService.swift
- CodeForge/Services/KeychainHelper.swift
- CodeForge/Actors/ParsingActor.swift
- CodeForge/Actors/InferenceActor.swift

**Files to Modify**
- Package.swift

**Steps**
1. Create macOS app target (arm64, macOS 15+) with Swift 6 language mode. Add SPM deps: swift-tree-sitter, mlx-swift. Configure OSLog subsystem com.codeforge.app with categories: editor, parsing, inference, terminal. Create empty actor stubs for ParsingActor, InferenceActor, TerminalActor.
2. Define SchemaV1 with @Model types: UserPreferences (singleton, CloudKit-synced), RecentFile (local, 20-entry LRU), AIConversation (local, encrypted messages blob), KeyBinding (CloudKit-synced). AIMessage is a Codable Sendable struct. Set up SchemaMigrationPlan baseline.
3. Build PersistenceService as @MainActor class with shared ModelContainer (SQLite at ~/Library/Application Support/CodeForge/). Implement generic save/fetch/delete, RecentFile LRU eviction at 20, and default UserPreferences creation on first launch.
4. Build EncryptionService as final Sendable class. Generate AES-256-GCM key on first use, store in Keychain with kSecAttrAccessibleWhenUnlockedThisDeviceOnly. Implement encrypt(data:)->Data (12-byte IV prepended + ciphertext + tag) and decrypt(data:)->Data. Cache key in-memory.
5. Wire AIConversation encrypted roundtrip: encode [AIMessage] via JSONEncoder -> encrypt -> store as Data blob in SwiftData. Reverse on read. Configure CloudKit opt-in toggle on UserPreferences and KeyBinding only. Write unit tests for encryption roundtrip, CRUD, and LRU eviction.

**Validation**
`xcodebuild test -scheme CodeForge -destination 'platform=macOS' -only-testing CodeForgeTests/PersistenceTests -only-testing CodeForgeTests/EncryptionTests 2>&1 | tail -20`

---

### Task 2: Editor Core with TreeSitter Syntax Highlighting

**Role:** Expert macOS AppKit/SwiftUI Engineer specializing in NSTextView and TreeSitter integration
**Goal:** Build NSTextView-based editor with TreeSitter syntax highlighting, file I/O validation, undo/redo, and autosave

**Context**
Build the single-file code editor: bridge NSTextView (TextKit 1) into SwiftUI via NSViewRepresentable, implement EditorModel as @Observable with cursor/selection tracking, add line number gutter, implement EditorService for file open (with validation: UTF-8, <50K lines, .swift/.py only, no symlinks) and atomic save, wire undo/redo with coalesced edits, add 5-second debounced autosave to temp file, and implement TreeSitter full parse + incremental re-parse with highlight range application to NSTextStorage.

**Files to Create**
- CodeForge/Views/EditorView.swift
- CodeForge/Models/EditorModel.swift
- CodeForge/Services/EditorService.swift
- CodeForge/Views/LineNumberGutter.swift
- CodeForge/Models/HighlightRange.swift
- CodeForge/Models/TokenType.swift
- CodeForge/Resources/highlights-swift.scm
- CodeForge/Resources/highlights-python.scm

**Files to Modify**
- CodeForge/Actors/ParsingActor.swift

**Steps**
1. Create EditorView as NSViewRepresentable wrapping NSTextView (monospace font, no line wrap, editable). Set up Coordinator to relay text changes to EditorModel without infinite loops. Build EditorModel as @Observable with content, cursorPosition, selection, language (.swift/.python), isDirty, and highlightRanges.
2. Build EditorService.open(url:) with validation (exists, regular file, readable, UTF-8, <50K lines, .swift/.py). Use NSOpenPanel filtered to .swift/.py. Store security-scoped bookmarks. Build save(document:to:) with Data.write(options:[.atomic]) and NSSavePanel. Add 5-second debounced autosave to temp file with crash recovery.
3. Implement line number gutter as an NSRulerView attached to NSTextView's enclosing scroll view. Auto-adjust width for digit count, highlight current line number, sync scroll position. Wire UndoManager with coalesced undo groups for rapid character insertions.
4. Implement ParsingActor: load bundled TreeSitter .dylib grammars for Swift and Python, full parse returning [HighlightRange] via highlight .scm queries. Define TokenType enum (keyword, string, comment, function, type, number, operator, punctuation, variable, plain). Implement incremental re-parse via TSTree.edit() on text edits streamed from EditorModel.
5. Subscribe EditorView to ParsingActor.highlightStream. Apply NSAttributedString color attributes to NSTextStorage lazily (visible range + 100-line buffer). Define dark theme color mapping for all 10 TokenType values. Write unit tests for parse correctness and benchmark incremental parse <8ms on 50K lines.

**Validation**
`xcodebuild test -scheme CodeForge -destination 'platform=macOS' -only-testing CodeForgeTests/EditorTests -only-testing CodeForgeTests/ParsingTests 2>&1 | tail -20`

---

### Task 3: Terminal Integration with forkpty and ANSI Parsing

**Role:** Expert macOS Systems Engineer specializing in pseudoterminals and ANSI terminal emulation
**Goal:** Build integrated terminal with forkpty shell spawning, ANSI rendering, keyboard forwarding, and resize support

**Context**
Spawn a shell subprocess via forkpty(), parse ANSI escape sequences into AttributedString with 256-color support, render in a SwiftUI terminal view with keyboard forwarding (including Ctrl+C, arrow keys, Tab), handle terminal resize via SIGWINCH ioctl, implement subprocess cleanup (SIGHUP then SIGKILL), and add a 10K-line scrollback buffer.

**Files to Create**
- CodeForge/Actors/TerminalActor.swift
- CodeForge/Models/TerminalModel.swift
- CodeForge/Views/TerminalView.swift
- CodeForge/Services/ANSIParser.swift
- CodeForge/Models/VirtualScreenBuffer.swift

**Files to Modify**
_None_

**Steps**
1. Build TerminalActor as an actor. Spawn $SHELL (or /bin/zsh) via forkpty(). Set TERM=xterm-256color, COLUMNS=80, LINES=24. Inherit only PATH, HOME, SHELL, USER, LANG, TERM. Bridge master fd to AsyncStream<Data> for output and write(data:) for input.
2. Implement ANSIParser: parse SGR sequences (256-color foreground/background, bold, underline), cursor movement (CUP, CUU, CUD, CUF, CUB), erase (ED, EL), screen clear. Maintain VirtualScreenBuffer of cols x rows cells. Handle partial escape sequences spanning data chunk boundaries.
3. Create TerminalView rendering TerminalModel.outputBuffer as AttributedString in monospace font. Use TimelineView for 120fps refresh but only redraw on buffer change. Forward keyboard input: arrow keys as ANSI escapes, Ctrl+C as 0x03, Tab as 0x09. Manage focus so terminal captures keyboard when active.
4. Implement resize(columns:rows:) sending TIOCSWINSZ ioctl. Detect view size changes and recalculate cols/rows from font metrics. Add subprocess cleanup: SIGHUP on close, wait 2s, then SIGKILL. Handle voluntary shell exit with inline status message. Add 10K-line scrollback buffer with LRU eviction and snap-to-bottom on new output.
5. Write unit tests for ANSI parsing (256-color SGR, cursor movement, partial sequences). Write integration test: spawn shell, send 'echo hello', verify output. Test resize sends SIGWINCH. Test cleanup leaves no zombie processes.

**Validation**
`xcodebuild test -scheme CodeForge -destination 'platform=macOS' -only-testing CodeForgeTests/TerminalTests -only-testing CodeForgeTests/ANSIParserTests 2>&1 | tail -20`

---

### Task 4: AI Agent with MLX On-Device Inference

**Role:** Expert Swift ML Engineer specializing in mlx-swift on-device inference and SwiftUI streaming interfaces
**Goal:** Implement on-device MLX code AI agent with explain, answer, suggest-edit operations and streaming chat UI

**Context**
Load a 4-bit quantized 7B model via mlx-swift, implement explain/answer/suggestEdit operations with streaming AsyncStream output, build prompt construction with sliding window context truncation centered on cursor, parse structured EditSuggestion output from model, build chat UI with streaming token animation, implement inline diff accept/reject UI in editor, and persist encrypted conversation history with 50-conversation LRU limit.

**Files to Create**
- CodeForge/Models/AIAgentModel.swift
- CodeForge/Models/EditSuggestion.swift
- CodeForge/Services/PromptBuilder.swift
- CodeForge/Views/AIAgentView.swift
- CodeForge/Views/EditSuggestionOverlay.swift
- CodeForge/Services/ModelDownloader.swift

**Files to Modify**
- CodeForge/Actors/InferenceActor.swift
- CodeForge/Views/EditorView.swift

**Steps**
1. Build ModelDownloader: download 4-bit 7B model to ~/Library/Application Support/CodeForge/Models/ on first launch. Verify SHA-256 checksum. Show SwiftUI progress sheet with cancel. Implement InferenceActor.loadModel()/unloadModel() lifecycle: keep loaded while AI panel visible, unload 60s after collapse, unload immediately on memory pressure.
2. Build PromptBuilder: system prompt + file context (with prompt injection markers escaped) + user query. Implement sliding window truncation centered on cursor/selection to fit model context window. Implement explain(selection:fileContext:)->AsyncStream<String> with 30s timeout and cancellation. Implement answer(question:fileContext:)->AsyncStream<String>.
3. Implement suggestEdit(instruction:fileContext:)->AsyncStream<EditSuggestion>. Parse model output into EditSuggestion{range, original, replacement, explanation}. Map ranges to document positions. Handle parseFailure for malformed output. Build AIAgentModel as @Observable with messages, isGenerating, modelState, currentStreamingText.
4. Create AIAgentView: chat-style sidebar with user/assistant bubbles, streaming token animation via PhaseAnimator, input field for questions, explain/suggest buttons using editor selection. Build EditSuggestionOverlay: inline diff in editor showing original (strikethrough) and replacement (green) with Accept/Reject buttons per suggestion. Accept registers undo action.
5. Wire AI conversation persistence: append AIMessage after each interaction, encrypt and store via AIConversation. Load history on panel open. Enforce 50-conversation LRU. Write unit tests for prompt truncation, EditSuggestion parsing, and encrypted persistence roundtrip.

**Validation**
`xcodebuild test -scheme CodeForge -destination 'platform=macOS' -only-testing CodeForgeTests/AIAgentTests -only-testing CodeForgeTests/PromptBuilderTests 2>&1 | tail -20`

---

### Task 5: App Shell, Settings, Accessibility & Distribution

**Role:** Expert macOS Application Engineer specializing in SwiftUI app architecture, Metal shaders, and Apple distribution
**Goal:** Assemble three-panel app shell with settings, accessibility, Metal effects, and signed .dmg distribution

**Context**
Build the three-panel ContentView layout (editor center, AI sidebar right, terminal bottom), apply NSWindow material customization, implement customizable key bindings from SwiftData, build Settings scene (theme, font, sync, scrollback, key bindings), add Metal shaders for gutter glow and selection effects, implement VoiceOver accessibility, build full menu bar, track recent files, and package as signed/notarized .dmg.

**Files to Create**
- CodeForge/Views/ContentView.swift
- CodeForge/Views/SettingsView.swift
- CodeForge/Services/KeyBindingService.swift
- CodeForge/Shaders/GutterGlow.metal
- CodeForge/Shaders/SelectionEffect.metal
- CodeForge/Scripts/notarize.sh

**Files to Modify**
- CodeForge/App/CodeForgeApp.swift
- CodeForge/Views/EditorView.swift
- CodeForge/Views/AIAgentView.swift
- CodeForge/Views/TerminalView.swift

**Steps**
1. Build ContentView with HSplitView (editor + AI sidebar) inside VSplitView (top + terminal). Panels collapsible via AppModel.isAIPanelVisible/isTerminalVisible. Apply NSWindow customization: .ultraThinMaterial toolbar, .regularMaterial AI sidebar, inline titlebar, window position/size persistence. Build main menu bar: File, Edit, View, AI menus with all actions wired.
2. Implement KeyBindingService: load KeyBinding entries from SwiftData, parse 'cmd+shift+p' strings into EventModifiers+KeyEquivalent, route to actions (openFile, saveFile, toggleAIPanel, toggleTerminal, undo, redo, explain, suggestEdit, askQuestion). Build SettingsView: theme picker, font name/size, CloudKit toggle, scrollback slider, key bindings editor with conflict detection.
3. Create Metal shader files: GutterGlow.metal for subtle active line glow, SelectionEffect.metal for soft-edge selection highlight. Precompile at build time. Apply via .colorEffect/.layerEffect or NSView layer. Implement recent files: RecentFile tracking, File > Open Recent submenu, cursor position restore, security-scoped bookmark validation.
4. Add VoiceOver accessibility to all interactive elements: editor (line-by-line reading), AI chat (role-prefixed messages), terminal, toolbar buttons, Settings controls. Ensure logical focus order: toolbar -> editor -> AI sidebar -> terminal. Write XCUITests: E2E open file + highlight + AI explain + save; terminal interaction; performance benchmarks (launch <100ms, file open <50ms, first token <500ms).
5. Code-sign with Developer ID certificate. Notarize via notarytool. Package as .dmg with app icon background and Applications alias. Verify: .dmg mounts, app drags to Applications, launches without Gatekeeper warnings, codesign --verify and spctl --assess pass. Run VoiceOver accessibility audit as final XCUITest.

**Validation**
`xcodebuild build -scheme CodeForge -destination 'platform=macOS' -configuration Release 2>&1 | tail -10 && xcodebuild test -scheme CodeForge -destination 'platform=macOS' -only-testing CodeForgeUITests 2>&1 | tail -20`