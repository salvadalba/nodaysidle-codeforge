# Tasks Plan — CodeForge

## 📌 Global Assumptions
- Solo developer with access to Apple Developer Program account for code signing and notarization
- Development machine is M4 Mac with macOS 15+ Sequoia and 16GB+ unified memory
- swift-tree-sitter SPM package includes pre-built grammars for Swift and Python or grammars are compiled from source during build
- mlx-swift SPM package provides stable API for 4-bit quantized model loading and inference on M4
- Target MLX model (CodeLlama-7B, DeepSeek-Coder-7B, or Qwen2.5-Coder-7B) is available in 4-bit quantized format compatible with mlx-swift
- Xcode 16+ available with Swift 6 language mode and strict concurrency support
- No App Store submission required for v1—direct .dmg distribution only
- CloudKit entitlement available via Developer Program for optional preference sync
- forkpty() is permitted in a notarized non-sandboxed app distributed outside the Mac App Store

## ⚠️ Risks
- TreeSitter Swift grammar may not cover all Swift 6 syntax (macros, result builders) leading to incomplete or incorrect highlighting
- MLX model inference quality for code understanding is unvalidated—chosen model may produce poor explanations or malformed EditSuggestion output requiring significant prompt engineering iteration
- 4GB MLX model in unified memory may cause memory pressure on 8GB M4 Macs, limiting target audience to 16GB+ configurations
- NSTextView TextKit 1 bridge may have performance regressions or compatibility issues with macOS 15 Sequoia compared to TextKit 2
- forkpty() in a notarized app outside Mac App Store may require special entitlements or encounter Apple notarization rejection
- ANSI escape sequence parser complexity is high—incomplete parsing may cause terminal rendering artifacts for complex TUI applications
- EditSuggestion range mapping from model output to document positions is fragile—model hallucination of line numbers or character offsets will produce invalid edits
- Swift 6 strict concurrency mode may surface actor isolation issues in third-party dependencies (swift-tree-sitter, mlx-swift) requiring workarounds
- 10-week timeline is aggressive for a solo developer building a code editor with AI and terminal from scratch

## 🧩 Epics
## Project Foundation & Persistence
**Goal:** Initialize the Xcode project with Swift 6 strict concurrency, configure SwiftData persistence with all model types, and establish the encryption layer for at-rest data protection.

### User Stories
_None_

### Acceptance Criteria
_None_

### ✅ Scaffold Xcode project with Swift 6 strict concurrency (half-day)

Create a new macOS app target (arm64-only, macOS 15+ deployment) with Swift 6 language mode and -strict-concurrency=complete. Add SPM dependencies: swift-tree-sitter, mlx-swift. Configure OSLog with subsystem 'com.codeforge.app' and four categories: editor, parsing, inference, terminal. Create empty actor stubs for MainActor, ParsingActor, InferenceActor, TerminalActor.

**Acceptance Criteria**
- Project builds with zero warnings under Swift 6 strict concurrency
- SPM resolves swift-tree-sitter and mlx-swift successfully
- OSLog subsystem and all four categories are configured and emit test log messages
- Four actor stub files exist with correct isolation annotations
- Deployment target is macOS 15.0, architecture is arm64 only

**Dependencies**
_None_

### ✅ Define SwiftData VersionedSchema and all @Model types (1 day)

Create SchemaV1 with all @Model types: UserPreferences (singleton), RecentFile, AIConversation, AIMessage (Codable struct, not @Model), KeyBinding. Use UUID primary keys. Configure UserPreferences and KeyBinding with cloudKitContainerIdentifier for optional sync. AIConversation and RecentFile are local-only. Set up SchemaMigrationPlan baseline.

**Acceptance Criteria**
- All five data types defined matching TRD data model spec exactly
- UserPreferences fetches as singleton with FetchDescriptor(fetchLimit: 1)
- AIMessage is a Codable Sendable struct, not a @Model
- SchemaV1 and SchemaMigrationPlan are configured
- In-memory ModelContainer unit test passes for CRUD on all types

**Dependencies**
- Scaffold Xcode project with Swift 6 strict concurrency

### ✅ Implement PersistenceService with ModelContainer and CRUD operations (1 day)

Build PersistenceService as @MainActor class with shared ModelContainer (SQLite backing store at ~/Library/Application Support/CodeForge/). Implement save(), fetch<T:PersistentModel>(_:predicate:sortBy:), delete(_:). Implement RecentFile LRU eviction at 20 entries on insert. Create default UserPreferences on first launch.

**Acceptance Criteria**
- PersistenceService CRUD operations work for all @Model types
- RecentFile collection never exceeds 20 entries; oldest evicted on insert
- Default UserPreferences created on first launch if none exists
- SQLite store located at correct Application Support path
- Unit tests pass using in-memory ModelContainer

**Dependencies**
- Define SwiftData VersionedSchema and all @Model types

### ✅ Implement EncryptionService with Keychain-backed AES-256-GCM (1 day)

Build EncryptionService as final class Sendable. Generate AES-256-GCM key on first launch, store in macOS Keychain with kSecAttrAccessibleWhenUnlockedThisDeviceOnly. Implement encrypt(data:) -> Data (12-byte random IV prepended + ciphertext + auth tag) and decrypt(data:) -> Data. Build KeychainHelper struct for save/load/delete. Cache key in-memory for session lifetime.

**Acceptance Criteria**
- encrypt/decrypt roundtrip produces identical plaintext
- Tampered ciphertext produces authenticationFailed error
- Key is generated and stored in Keychain on first call
- Subsequent calls retrieve cached key without Keychain access
- 12-byte IV is unique per encryption operation (verify with 1000 encryptions)

**Dependencies**
- Scaffold Xcode project with Swift 6 strict concurrency

### ✅ Wire AIConversation encrypted persistence roundtrip (half-day)

Implement the flow: encode [AIMessage] array via JSONEncoder -> encrypt via EncryptionService -> store as AIConversation.encryptedMessages Data blob in SwiftData. Reverse on read: fetch -> decrypt -> JSONDecode. Unit test the full roundtrip.

**Acceptance Criteria**
- AIMessage array survives encode-encrypt-persist-fetch-decrypt-decode roundtrip
- Stored encryptedMessages blob is not readable as plaintext JSON
- Conversation with 100 messages persists and loads correctly
- Error handling covers keychainAccessDenied and decryptionFailed cases

**Dependencies**
- Implement PersistenceService with ModelContainer and CRUD operations
- Implement EncryptionService with Keychain-backed AES-256-GCM

### ✅ Implement CloudKit sync opt-in for UserPreferences and KeyBinding (half-day)

Configure CloudKit container identifier on UserPreferences and KeyBinding models only. Sync is disabled by default; toggled via UserPreferences.cloudKitSyncEnabled. Conflict resolution is last-write-wins. AIConversation and RecentFile remain local-only.

**Acceptance Criteria**
- CloudKit sync is off by default
- Toggling cloudKitSyncEnabled on triggers sync for UserPreferences and KeyBinding only
- AIConversation and RecentFile never sync to CloudKit
- Last-write-wins conflict resolution confirmed in code

**Dependencies**
- Implement PersistenceService with ModelContainer and CRUD operations

## Editor Core
**Goal:** Build the single-file code editor with NSTextView bridged to SwiftUI, TreeSitter-based syntax highlighting for Swift and Python, undo/redo, autosave, and file open/save with validation.

### User Stories
_None_

### Acceptance Criteria
_None_

### ✅ Bridge NSTextView into SwiftUI via NSViewRepresentable (1.5 days)

Create EditorView as an NSViewRepresentable wrapping NSTextView. Configure NSTextView with monospace font, line wrapping off, and editable. Set up Coordinator to relay text changes to EditorModel. Ensure NSTextView respects SwiftUI layout and resizes correctly in the parent container.

**Acceptance Criteria**
- NSTextView renders inside SwiftUI view hierarchy
- Text input flows from NSTextView to EditorModel.content
- EditorModel.content changes propagate back to NSTextView without infinite loops
- View resizes correctly when parent container changes size
- Monospace font renders at configurable size from UserPreferences

**Dependencies**
- Implement PersistenceService with ModelContainer and CRUD operations

### ✅ Implement EditorModel as @Observable with cursor and selection tracking (1 day)

Build EditorModel with @Observable: content: String, cursorPosition: Int, selection: Range<String.Index>?, language: Language (.swift | .python), isDirty: Bool, highlightRanges: [HighlightRange]. Track cursor position and selection range from NSTextView delegate callbacks. Mark isDirty on any content change; clear on save.

**Acceptance Criteria**
- EditorModel publishes changes to SwiftUI views correctly
- cursorPosition updates on every cursor movement in NSTextView
- selection range tracks selected text range accurately
- isDirty is true after any edit, false after save
- Language is set based on file extension on open

**Dependencies**
- Bridge NSTextView into SwiftUI via NSViewRepresentable

### ✅ Implement EditorService for file open with validation (1 day)

Build EditorService.open(url:) -> FileDocument. Validate: file exists, is regular file (not symlink to sensitive path), is readable, is under 50,000 lines, has .swift or .py extension, is valid UTF-8. Use NSOpenPanel for file selection. Store security-scoped bookmarks for recent file access across launches. Trigger ParsingActor.parse() on successful open.

**Acceptance Criteria**
- Opens valid .swift and .py files and populates EditorModel
- Rejects symlinks, non-UTF-8, files over 50K lines, and non-.swift/.py extensions with specific errors
- NSOpenPanel filters to .swift and .py files only
- Security-scoped bookmark stored for opened file
- RecentFile entry created in SwiftData on successful open
- ParsingActor.parse() called after file content loaded

**Dependencies**
- Implement EditorModel as @Observable with cursor and selection tracking

### ✅ Implement EditorService for file save with atomic write (half-day)

Build EditorService.save(document:to:). Write atomically via Data.write(to:options:[.atomic]). Update RecentFile entry in SwiftData. Use NSSavePanel for save-as. Handle errors: writePermissionDenied, diskFull, atomicWriteFailed. Clear isDirty on successful save.

**Acceptance Criteria**
- File saves atomically—no partial writes on simulated crash
- RecentFile.lastOpened updated on save
- isDirty cleared after successful save
- NSSavePanel allows choosing save location
- Errors display user-actionable alert via SwiftUI .alert()

**Dependencies**
- Implement EditorService for file open with validation

### ✅ Implement line number gutter in editor (1 day)

Add a line number gutter to the left of the NSTextView. Render line numbers in a slightly dimmed color. Gutter width adjusts based on line count digit width. Line numbers scroll in sync with the text view. Highlight the current line number.

**Acceptance Criteria**
- Line numbers display correctly for files up to 50,000 lines
- Current line number is visually highlighted
- Gutter scrolls in sync with text content
- Gutter width adjusts for 1-digit, 2-digit, up to 5-digit line numbers
- Line numbers use monospace font matching editor

**Dependencies**
- Bridge NSTextView into SwiftUI via NSViewRepresentable

### ✅ Implement undo/redo with coalesced text edits (1 day)

Wire UndoManager to NSTextView for undo/redo. Coalesce rapid sequential character insertions into single undo groups (e.g., typing a word = one undo action). Register undo actions for all text mutations including AI-applied edits. Expose undo/redo via menu and keyboard shortcuts (Cmd+Z, Cmd+Shift+Z).

**Acceptance Criteria**
- Typing 'hello' then Cmd+Z removes the entire word, not one character
- Undo after AI edit suggestion revert restores original text
- Redo replays undone edits correctly
- Undo stack clears on file close/open
- Menu items Edit > Undo and Edit > Redo work correctly

**Dependencies**
- Implement EditorModel as @Observable with cursor and selection tracking

### ✅ Implement autosave with 5-second debounce (1 day)

Add autosave to EditorService that writes to a temporary file every 5 seconds if the document is dirty. Use a debounced timer—reset on each edit. Execute write on a background context to avoid blocking the editor. Delete temp file on explicit save or clean close. Recover from temp file on next launch if crash detected.

**Acceptance Criteria**
- Autosave triggers 5 seconds after last keystroke, not on every keystroke
- Autosave writes to a temp file, not the original file
- Autosave does not block the main thread during write
- Temp file cleaned up on normal save or app exit
- Crash recovery detects temp file and offers to restore

**Dependencies**
- Implement EditorService for file save with atomic write

### ✅ Implement ParsingActor with TreeSitter full parse for Swift and Python (1.5 days)

Build ParsingActor as an actor. Load bundled TreeSitter grammars (.dylib) for Swift and Python. Create TSParser, perform full parse on file content, return SyntaxTree wrapping TSTree. Load highlight query .scm files for both languages. Convert TSTree nodes to [HighlightRange] using tree-sitter highlight queries. Define TokenType enum: keyword, string, comment, function, type, number, operator, punctuation, variable, plain.

**Acceptance Criteria**
- Full parse of a 1000-line Swift file produces correct HighlightRange array
- Full parse of a 1000-line Python file produces correct HighlightRange array
- TokenType enum covers all 10 specified types
- Full parse of 50K line file completes within 100ms
- grammarNotFound error raised if .dylib missing

**Dependencies**
- Scaffold Xcode project with Swift 6 strict concurrency

### ✅ Implement TreeSitter incremental re-parse on text edits (1.5 days)

Build ParsingActor.applyEdit(edit:) that uses TSTree.edit() + ts_parser_parse() for incremental re-parse. Emit only changed HighlightRange values. Wire EditorModel text changes to emit TextEdit structs to ParsingActor via AsyncStream on every keystroke. Fall back to full re-parse if incremental parse fails.

**Acceptance Criteria**
- Single-character edit re-parse completes within 8ms for 50K line files
- Only changed highlight ranges are emitted, not full document ranges
- Rapid typing (10 chars/sec) does not drop edits or produce stale highlights
- Invalid edit range triggers fallback to full re-parse, not crash
- Benchmark test verifies 8ms p99 for incremental parse

**Dependencies**
- Implement ParsingActor with TreeSitter full parse for Swift and Python

### ✅ Apply TreeSitter highlight ranges to NSTextView via NSTextStorage (1 day)

Subscribe EditorView to ParsingActor.highlightStream. On each [HighlightRange] emission, apply NSAttributedString attributes (foreground color per TokenType) to NSTextStorage. Lazily apply attributes only for visible line range + 100-line buffer above and below viewport. Define a default dark theme color mapping for all 10 TokenType values.

**Acceptance Criteria**
- Keywords, strings, comments, functions etc. render in distinct colors
- Scrolling a 50K line file does not trigger full-document re-coloring
- Only visible + 100-line buffer range gets attributes applied
- Color mapping is correct for both Swift and Python token types
- Highlight updates are visually immediate on typing (no flicker)

**Dependencies**
- Implement TreeSitter incremental re-parse on text edits
- Bridge NSTextView into SwiftUI via NSViewRepresentable

## Terminal Integration
**Goal:** Spawn a shell subprocess via forkpty(), parse ANSI escape sequences, render terminal output in a SwiftUI view, and handle keyboard input forwarding and terminal resizing.

### User Stories
_None_

### Acceptance Criteria
_None_

### ✅ Implement TerminalActor with forkpty() shell spawning (1.5 days)

Build TerminalActor as an actor. Spawn user's default shell ($SHELL or /bin/zsh) via forkpty(). Set TERM=xterm-256color, COLUMNS=80, LINES=24. Inherit only PATH, HOME, SHELL, USER, LANG, TERM environment variables. Bridge master fd to Swift async: outputStream as AsyncStream<Data> reading from fd, write(data:) writing to fd.

**Acceptance Criteria**
- Shell spawns successfully and outputStream yields shell prompt
- write('echo hello\n') results in 'hello' appearing in outputStream
- Only the 6 specified environment variables are inherited
- forkFailed error raised if forkpty() returns -1
- shellNotFound error raised if $SHELL path is invalid

**Dependencies**
- Scaffold Xcode project with Swift 6 strict concurrency

### ✅ Implement ANSI escape sequence parser (2 days)

Parse ANSI escape sequences from shell output Data into AttributedString. Support: SGR (colors, bold, underline) for 256-color palette, cursor movement (CUP, CUU, CUD, CUF, CUB), erase (ED, EL), and screen clear. Maintain a virtual screen buffer of columns x rows cells. Run parsing on TerminalActor, not MainActor.

**Acceptance Criteria**
- 256-color ANSI SGR sequences produce correct AttributedString foreground/background colors
- Bold and underline attributes parsed correctly
- Cursor movement sequences update virtual buffer positions
- Screen clear (ESC[2J) resets virtual buffer
- Parser handles partial escape sequences across data chunk boundaries

**Dependencies**
- Implement TerminalActor with forkpty() shell spawning

### ✅ Build TerminalView with monospace rendering and keyboard forwarding (1.5 days)

Create TerminalView as SwiftUI View rendering TerminalModel.outputBuffer (AttributedString) in a monospace font. Use TimelineView for display-rate refresh (120fps on ProMotion) but only redraw if buffer changed. Forward keyboard input including control sequences (arrow keys, Ctrl+C, Tab) to TerminalActor.write(). Handle focus management so terminal captures keyboard when active.

**Acceptance Criteria**
- Terminal renders colored output correctly in monospace font
- Arrow keys send correct ANSI escape sequences to shell
- Ctrl+C sends SIGINT (0x03 byte) to shell
- Tab key sends 0x09 byte for shell completion
- View only redraws when outputBuffer has changed, not every frame
- Terminal scrolls to show latest output

**Dependencies**
- Implement ANSI escape sequence parser

### ✅ Implement terminal resize with SIGWINCH (half-day)

Build TerminalActor.resize(columns:rows:) that sends TIOCSWINSZ ioctl to the pseudoterminal. Detect TerminalView size changes in SwiftUI and recalculate columns/rows based on font metrics. Trigger resize on panel drag. Update TerminalModel.columns and TerminalModel.rows.

**Acceptance Criteria**
- Resizing terminal panel sends SIGWINCH to shell subprocess
- Shell applications (vim, htop) reflow to new dimensions
- Column/row count calculated correctly from view pixel size and font metrics
- Rapid resizing does not crash or produce ioctl errors

**Dependencies**
- Build TerminalView with monospace rendering and keyboard forwarding

### ✅ Implement terminal subprocess cleanup on close and app termination (half-day)

On terminal panel close or app termination: send SIGHUP to shell subprocess, wait 2 seconds, then SIGKILL if still running. Close master fd. Clean up TerminalSession state. Handle shell voluntary exit (non-zero or zero status) gracefully with inline message in TerminalView.

**Acceptance Criteria**
- Closing terminal panel terminates shell subprocess within 2 seconds
- App termination kills all shell subprocesses
- Shell voluntary exit (typing 'exit') shows exit status inline
- No zombie processes remain after terminal close
- Reopening terminal panel spawns a fresh shell

**Dependencies**
- Implement TerminalActor with forkpty() shell spawning

### ✅ Implement terminal scrollback buffer with 10K line cap (1 day)

Add a scrollback buffer to TerminalModel capped at 10,000 lines. When buffer exceeds cap, evict oldest lines. Allow scrolling up through history. Snap to bottom on new output. Store cap value as configurable in UserPreferences.

**Acceptance Criteria**
- Scrollback buffer stores up to 10,000 lines of terminal history
- Scrolling up shows older output without disrupting new output
- New output snaps view to bottom automatically
- Buffer evicts oldest lines when exceeding 10K cap
- Cap is configurable via UserPreferences

**Dependencies**
- Build TerminalView with monospace rendering and keyboard forwarding

## AI Agent
**Goal:** Load a 4-bit quantized 7B MLX model on-device, implement explain/answer/suggestEdit operations with streaming output, build the chat UI, and persist encrypted conversation history.

### User Stories
_None_

### Acceptance Criteria
_None_

### ✅ Implement MLX model download with SHA-256 verification and progress UI (1.5 days)

Build model download flow in InferenceActor. Download 4-bit quantized 7B model to ~/Library/Application Support/CodeForge/Models/ on first launch. Verify SHA-256 checksum against bundled expected hash. Show download progress in a SwiftUI sheet with progress bar and cancel button. Retry on checksum failure. Set ModelState.downloading(progress) during download.

**Acceptance Criteria**
- Model downloads to correct directory on first launch
- SHA-256 checksum verified; redownload triggered on mismatch
- Progress UI shows accurate percentage and supports cancellation
- ModelState transitions: notDownloaded -> downloading(progress) -> loaded or error
- Subsequent launches skip download if model file and checksum match

**Dependencies**
- Scaffold Xcode project with Swift 6 strict concurrency

### ✅ Implement InferenceActor model load/unload lifecycle (1 day)

Build InferenceActor.loadModel() to load MLX model into unified memory. Implement warm/unload strategy: keep model loaded while AI panel is visible; unload 60 seconds after panel collapse to reclaim ~4GB. Respond to memory pressure notifications. Set ModelState.loaded/unloaded accordingly. Log model load duration via os_signpost.

**Acceptance Criteria**
- loadModel() loads MLX model and sets ModelState.loaded
- unloadModel() frees unified memory and sets ModelState.unloaded
- Model unloads 60s after AI panel collapse if not re-opened
- Model unloads immediately on memory pressure notification
- Model load duration logged via os_signpost (target: <3s)
- Loading an already-loaded model is a no-op

**Dependencies**
- Implement MLX model download with SHA-256 verification and progress UI

### ✅ Implement prompt construction with sliding window context truncation (1 day)

Build prompt template system: system prompt + file context + user query. Implement sliding window truncation centered on user's cursor position or selection that fits within model context window. File content enclosed in delimiters the model treats as data (prompt injection defense). Sanitize file content by escaping prompt injection markers.

**Acceptance Criteria**
- Prompt includes system template, truncated file context, and user query
- Sliding window centers on selection/cursor position within context window
- Files larger than context window are truncated without losing selection context
- Prompt injection markers in file content are escaped
- Unit test verifies truncation produces valid prompt within context limit

**Dependencies**
- Implement InferenceActor model load/unload lifecycle

### ✅ Implement InferenceActor.explain() with streaming AsyncStream output (1 day)

Build explain(selection:fileContext:) -> AsyncStream<String>. Validate selection 1-5000 chars. Construct prompt with system template for code explanation. Stream generated tokens with 30s timeout. Support user cancellation via Task. Emit modelNotLoaded if model not ready.

**Acceptance Criteria**
- Streaming tokens appear one-by-one in consumer
- 30s timeout terminates generation with inferenceTimeout error
- Task cancellation stops generation and completes stream
- modelNotLoaded error raised if called before loadModel()
- First token latency logged via os_signpost (target: <500ms)

**Dependencies**
- Implement prompt construction with sliding window context truncation

### ✅ Implement InferenceActor.answer() with streaming output (half-day)

Build answer(question:fileContext:) -> AsyncStream<String>. Validate question 1-2000 chars. Construct prompt with system template for Q&A about code. Same streaming semantics, timeout, and cancellation as explain().

**Acceptance Criteria**
- Streaming answer tokens produced for natural language questions about code
- File context included in prompt provides grounded answers
- Same timeout and cancellation behavior as explain()
- Empty or oversized question produces descriptive error

**Dependencies**
- Implement InferenceActor.explain() with streaming AsyncStream output

### ✅ Implement InferenceActor.suggestEdit() with structured EditSuggestion output (1.5 days)

Build suggestEdit(instruction:fileContext:) -> AsyncStream<EditSuggestion>. Construct prompt instructing model to output structured edit markers. Parse model output into EditSuggestion { range, original, replacement, explanation }. Map ranges back to document positions. Emit multiple non-overlapping suggestions. Handle parseFailure when model output does not conform.

**Acceptance Criteria**
- Model output parsed into valid EditSuggestion structs
- Ranges in EditSuggestion correctly map to document positions
- Multiple non-overlapping suggestions emitted in stream
- parseFailure error emitted for malformed model output
- Unit test with mock model output verifies parsing logic

**Dependencies**
- Implement InferenceActor.answer() with streaming output

### ✅ Build AIAgentView chat interface with streaming token animation (1.5 days)

Create AIAgentView as a chat-style SwiftUI view in the trailing sidebar. Display conversation as alternating user/assistant bubbles. Stream assistant tokens using PhaseAnimator for typing animation. Show loading indicator while model generates. Add input field for questions and edit instructions. Add explain/suggest buttons that use selected text from editor.

**Acceptance Criteria**
- Chat displays conversation history with user and assistant messages
- Streaming tokens animate in real-time as model generates
- Input field submits questions to answer() or edit instructions to suggestEdit()
- Explain button sends selected text to explain()
- Loading indicator visible during generation
- Cancel button stops in-progress generation

**Dependencies**
- Implement InferenceActor.suggestEdit() with structured EditSuggestion output

### ✅ Implement EditSuggestion apply/reject UI in editor (1.5 days)

When suggestEdit emits EditSuggestions, display them inline in the editor as a diff: original text with strikethrough and replacement text in green. Show Accept/Reject buttons per suggestion. Accept applies replacement to document and registers undo action. Reject dismisses the suggestion. Handle multiple concurrent suggestions.

**Acceptance Criteria**
- Suggestions render as inline diff in editor with original and replacement visible
- Accept replaces original text with suggestion and is undoable
- Reject removes suggestion UI without modifying document
- Multiple suggestions can be accepted/rejected independently
- Accepting a suggestion triggers incremental re-parse

**Dependencies**
- Build AIAgentView chat interface with streaming token animation
- Implement undo/redo with coalesced text edits

### ✅ Wire AI conversation persistence with encrypted SwiftData storage (1 day)

After each AI interaction, append AIMessage to current conversation. Persist conversation to AIConversation.encryptedMessages via encode-encrypt-store flow. Load and display conversation history on AI panel open. Implement 50-conversation limit with oldest eviction.

**Acceptance Criteria**
- Conversation persists across app restarts
- Conversation history loads and displays in AIAgentView on panel open
- 50-conversation limit enforced with LRU eviction
- Encrypted messages are not readable in raw SwiftData store
- New conversation created per file path

**Dependencies**
- Build AIAgentView chat interface with streaming token animation
- Wire AIConversation encrypted persistence roundtrip

### ✅ Build AIAgentModel @Observable state management (1 day)

Create AIAgentModel as @Observable with: messages: [AIMessage], isGenerating: Bool, modelState: ModelState, currentStreamingText: String. Wire to InferenceActor outputs. Manage model state transitions. Surface errors to UI via modelState.error(String).

**Acceptance Criteria**
- modelState reflects actual InferenceActor state at all times
- isGenerating is true during inference, false otherwise
- currentStreamingText accumulates tokens during generation
- Error states display descriptive messages in AIAgentView
- State changes trigger SwiftUI view updates correctly

**Dependencies**
- Implement InferenceActor model load/unload lifecycle

## App Shell & Integration
**Goal:** Build the three-panel layout with toolbar, NSWindow customization, customizable key bindings, Metal visual effects, VoiceOver accessibility, and recent files.

### User Stories
_None_

### Acceptance Criteria
_None_

### ✅ Build CodeForgeApp entry point with Scene declarations (half-day)

Create @main CodeForgeApp with WindowGroup (main editor), Settings scene, and MenuBarExtra. Configure WindowGroup with default size and minimum size. Register all module dependencies. Set up app lifecycle: no heavy initialization on launch—all lazy.

**Acceptance Criteria**
- App launches and displays empty editor window
- Settings scene opens via menu Cmd+,
- MenuBarExtra appears in menu bar
- Cold launch to interactive frame under 100ms (measure with os_signpost)
- No model loading, file opening, or shell spawning on launch

**Dependencies**
- Implement EditorModel as @Observable with cursor and selection tracking

### ✅ Implement three-panel ContentView layout (1 day)

Build ContentView with center editor, trailing AI sidebar, and bottom terminal panel. AI sidebar and terminal panel are collapsible. Use HSplitView/VSplitView or NavigationSplitView. Panel visibility controlled by AppModel.isAIPanelVisible and isTerminalVisible. Panel sizes are draggable.

**Acceptance Criteria**
- Three panels render: editor center, AI sidebar right, terminal bottom
- AI sidebar toggles visibility with animation
- Terminal panel toggles visibility with animation
- Panel dividers are draggable to resize
- Editor occupies full width when both panels are collapsed

**Dependencies**
- Build CodeForgeApp entry point with Scene declarations
- Build TerminalView with monospace rendering and keyboard forwarding
- Build AIAgentView chat interface with streaming token animation

### ✅ Apply NSWindow customization for premium material effects (half-day)

Customize NSWindow: .ultraThinMaterial for toolbar area, .regularMaterial for AI sidebar. Apply via NSViewRepresentable or window delegate access. Set titlebar style with inline toolbar. Configure window to remember position and size across launches.

**Acceptance Criteria**
- Toolbar area shows ultraThinMaterial translucency
- AI sidebar shows regularMaterial translucency
- Window position and size persist across launches
- Titlebar style is inline with integrated toolbar
- Materials look correct in both light and dark mode

**Dependencies**
- Implement three-panel ContentView layout

### ✅ Implement customizable key bindings from SwiftData KeyBinding model (1 day)

Load KeyBinding entries from SwiftData on launch. Parse keyCombination strings (e.g., 'cmd+shift+p') into EventModifiers + KeyEquivalent. Route key events to corresponding actions (openFile, saveFile, toggleAIPanel, toggleTerminal, undo, redo, explain, suggestEdit, askQuestion). Add Settings UI to view and modify key bindings.

**Acceptance Criteria**
- Default key bindings work: Cmd+O open, Cmd+S save, Cmd+\ toggle AI, Cmd+` toggle terminal
- KeyBinding string format 'modifiers+key' parses correctly for all supported combos
- User can modify key bindings in Settings and changes persist
- Key binding conflicts detected and warned in Settings UI
- All editor actions enum values have default key bindings

**Dependencies**
- Implement PersistenceService with ModelContainer and CRUD operations
- Build CodeForgeApp entry point with Scene declarations

### ✅ Build Settings scene with theme, font, and sync preferences (1 day)

Create Settings scene with: theme selection (at minimum one dark theme), font name and size pickers, CloudKit sync toggle, terminal scrollback cap slider, and key bindings editor. All changes persist to UserPreferences singleton in SwiftData. Theme change triggers editor re-render with new color mapping.

**Acceptance Criteria**
- Theme picker changes editor syntax highlighting colors
- Font picker changes editor and terminal font name and size
- CloudKit toggle enables/disables sync for preferences and key bindings
- Terminal scrollback cap configurable via slider
- All preference changes persist across app restarts

**Dependencies**
- Implement customizable key bindings from SwiftData KeyBinding model
- Implement CloudKit sync opt-in for UserPreferences and KeyBinding

### ✅ Implement recent files tracking and menu (1 day)

Track opened files as RecentFile entries in SwiftData. Maintain max 20 entries with LRU eviction. Store cursor position per file for restore on reopen. Add File > Open Recent submenu listing recent files. Validate file still exists before offering in menu. Use security-scoped bookmarks for sandbox access.

**Acceptance Criteria**
- File > Open Recent submenu lists up to 20 recent files
- Opening a recent file restores cursor position
- Files that no longer exist are grayed out or removed from list
- Most recently opened file appears at top of list
- Security-scoped bookmarks allow access across launches

**Dependencies**
- Implement EditorService for file open with validation

### ✅ Add Metal shaders for gutter glow and selection effects (1 day)

Create .metal shader files for: subtle glow effect on active line number in gutter, and selection highlight with soft edges. Precompile shaders at build time—no runtime shader compilation. Apply via SwiftUI .colorEffect or .layerEffect modifiers or NSView layer composition.

**Acceptance Criteria**
- Active line number has a subtle glow effect
- Text selection has soft-edge highlight effect
- Shaders are precompiled—no runtime compilation visible in Instruments
- Effects render at display refresh rate without frame drops
- Effects look correct in both light and dark mode

**Dependencies**
- Implement line number gutter in editor
- Apply TreeSitter highlight ranges to NSTextView via NSTextStorage

### ✅ Implement VoiceOver accessibility for all interactive elements (1 day)

Add accessibility labels, traits, and values to all interactive elements: editor view, AI chat messages and input, terminal view, toolbar buttons, Settings controls. Ensure logical focus order. Test with VoiceOver enabled.

**Acceptance Criteria**
- All toolbar buttons have descriptive accessibility labels
- Editor content is accessible via VoiceOver with line-by-line reading
- AI chat messages are read aloud with role (user/assistant) prefix
- Terminal output accessible with VoiceOver
- Focus order follows logical layout: toolbar, editor, AI sidebar, terminal
- No interactive element missing an accessibility label

**Dependencies**
- Implement three-panel ContentView layout

### ✅ Implement main menu bar with all standard editor menus (half-day)

Build menu bar with: File (New, Open, Open Recent, Save, Save As, Close), Edit (Undo, Redo, Cut, Copy, Paste, Select All), View (Toggle AI Panel, Toggle Terminal), AI (Explain Selection, Suggest Edit, Ask Question). Wire all menu items to corresponding actions. Respect key bindings.

**Acceptance Criteria**
- All menu items trigger their corresponding actions
- Menu items show correct keyboard shortcuts from KeyBinding model
- Disabled states: Save disabled when not dirty, AI actions disabled when no file open
- Standard Edit menu items (Cut, Copy, Paste) work with NSTextView

**Dependencies**
- Implement customizable key bindings from SwiftData KeyBinding model

## Testing & Distribution
**Goal:** Achieve comprehensive test coverage with unit, integration, and E2E tests, benchmark performance targets, and package as a signed/notarized .dmg for distribution.

### User Stories
_None_

### Acceptance Criteria
_None_

### ✅ Write unit tests for ParsingActor (full parse and incremental edit) (1 day)

Test full parse for known Swift and Python code snippets. Assert correct HighlightRange output for each token type. Test incremental edit produces correct deltas. Benchmark incremental parse within 8ms for 50K line synthetic file. Test grammarNotFound error for missing grammar.

**Acceptance Criteria**
- Full parse tests pass for Swift with keywords, strings, comments, functions, types
- Full parse tests pass for Python with equivalent token types
- Incremental parse test confirms only changed ranges are emitted
- Performance benchmark: incremental parse < 8ms on 50K line file
- Error test: grammarNotFound raised for unsupported language

**Dependencies**
- Implement TreeSitter incremental re-parse on text edits

### ✅ Write unit tests for EncryptionService (half-day)

Test encrypt/decrypt roundtrip with known plaintext of various sizes. Test tampered ciphertext produces authenticationFailed. Test IV uniqueness across 1000 encryptions. Test key generation on first use and retrieval on subsequent use.

**Acceptance Criteria**
- Roundtrip test passes for 0-byte, 1-byte, 1MB payloads
- Tampered ciphertext test produces authenticationFailed error
- 1000 encryptions produce 1000 unique IVs
- First-use key generation and subsequent retrieval work correctly

**Dependencies**
- Implement EncryptionService with Keychain-backed AES-256-GCM

### ✅ Write unit tests for EditorService file validation (half-day)

Test open rejects: symlinks, non-UTF-8 files, files over 50K lines, files with unsupported extensions (.js, .txt), non-existent files, unreadable files. Test open succeeds for valid .swift and .py files. Test save atomic write and error cases.

**Acceptance Criteria**
- Each rejection case produces the correct specific error
- Valid .swift file opens successfully with correct language detection
- Valid .py file opens successfully with correct language detection
- Atomic save test verifies no partial writes (simulate interruption)

**Dependencies**
- Implement EditorService for file save with atomic write

### ✅ Write unit tests for AI prompt construction and EditSuggestion parsing (1 day)

Test sliding window truncation centers on selection for files exceeding context window. Test prompt template produces correctly formatted model input. Test EditSuggestion parsing from mock model output with valid and malformed responses.

**Acceptance Criteria**
- Truncation test: selection remains in context after truncation of large file
- Prompt template test: output matches expected format with delimiters
- EditSuggestion parsing: valid mock output produces correct range/original/replacement
- parseFailure error produced for malformed mock output
- Prompt injection markers in file content are escaped

**Dependencies**
- Implement InferenceActor.suggestEdit() with structured EditSuggestion output

### ✅ Write unit tests for terminal ANSI parsing (1 day)

Test 256-color SGR sequences produce correct foreground/background colors. Test cursor movement (CUP, CUU, CUD, CUF, CUB) updates virtual buffer positions. Test screen clear resets buffer. Test partial escape sequence handling across data chunk boundaries.

**Acceptance Criteria**
- 256-color test: all color codes map to correct colors
- Bold and underline attributes parsed correctly
- Cursor movement sequences update virtual buffer position
- Screen clear resets virtual buffer to empty
- Partial escape sequence spanning two data chunks parses correctly

**Dependencies**
- Implement ANSI escape sequence parser

### ✅ Write unit tests for KeyBinding parsing and PersistenceService CRUD (half-day)

Test key combination string parsing for all modifier combinations. Test PersistenceService CRUD for all @Model types. Test RecentFile LRU eviction at 20 entries. Test UserPreferences singleton behavior.

**Acceptance Criteria**
- 'cmd+shift+p' parses to correct EventModifiers and KeyEquivalent
- 'ctrl+`' parses correctly
- All CRUD operations tested for each @Model type
- Inserting 21st RecentFile evicts the oldest
- Two fetches of UserPreferences return the same singleton

**Dependencies**
- Implement customizable key bindings from SwiftData KeyBinding model

### ✅ Write integration tests for editor + parser pipeline (1 day)

Open a real .swift file, type characters via EditorModel, verify highlight ranges update via ParsingActor within 8ms. Verify undo/redo produces correct re-parse. Test rapid typing scenario with 20 edits in 2 seconds.

**Acceptance Criteria**
- File open triggers full parse with correct highlights
- Typing produces incremental parse within 8ms
- Undo triggers re-parse with previous highlight state
- Rapid typing (20 edits/2s) does not produce stale or incorrect highlights

**Dependencies**
- Apply TreeSitter highlight ranges to NSTextView via NSTextStorage

### ✅ Write integration tests for terminal spawn and I/O (half-day)

Spawn shell, send 'echo hello', verify 'hello' in outputBuffer. Test resize sends SIGWINCH and applications reflow. Test terminate cleans up subprocess (no zombie). Test shell exit is handled gracefully.

**Acceptance Criteria**
- 'echo hello' command produces 'hello' in parsed terminal output
- Resize triggers SIGWINCH verified by tput cols change
- Terminate leaves no zombie processes
- Shell exit (typing 'exit') displays exit status

**Dependencies**
- Implement terminal subprocess cleanup on close and app termination

### ✅ Write XCUITest E2E: open file, highlight, AI explain, save (1 day)

XCUITest: Launch app -> open .swift file via Open menu -> verify editor displays content with syntax highlighting (check colored text exists) -> select function body -> click Explain in AI panel -> verify streaming response appears -> save file -> reopen and verify content persisted.

**Acceptance Criteria**
- Test passes end-to-end in CI environment
- Syntax highlighting verified via accessibility attributes or screenshot comparison
- AI streaming response appears within 30s timeout
- Saved file content matches editor content on reopen

**Dependencies**
- Implement three-panel ContentView layout
- Wire AI conversation persistence with encrypted SwiftData storage

### ✅ Write XCUITest E2E: terminal interaction (half-day)

XCUITest: Launch app -> toggle terminal panel -> verify shell prompt appears -> type 'python3 -c "print(42)"' -> verify '42' appears in terminal output -> resize terminal panel -> verify output is present.

**Acceptance Criteria**
- Terminal panel appears on toggle
- Shell prompt is visible
- Python command produces expected output
- Terminal remains functional after resize

**Dependencies**
- Implement terminal resize with SIGWINCH

### ✅ Write performance XCUITest benchmarks (half-day)

XCUITest performance measurement: cold launch to interactive (measure with XCTMetric), file open to editor ready, AI first token latency. Assert p95 cold launch < 100ms, file open < 50ms, first token < 500ms.

**Acceptance Criteria**
- Cold launch p95 measured and under 100ms
- File open to editor ready under 50ms
- AI first token latency under 500ms
- Benchmarks run in CI and fail if targets exceeded

**Dependencies**
- Write XCUITest E2E: open file, highlight, AI explain, save

### ✅ Run VoiceOver accessibility audit (half-day)

XCUITest: Enable VoiceOver, navigate all interactive elements. Verify all elements have accessibility labels. Verify focus order is logical. Fix any missing labels or broken focus order discovered.

**Acceptance Criteria**
- All interactive elements have accessibility labels
- Focus order follows logical layout
- No VoiceOver traps (focus stuck in a view)
- VoiceOver reads AI assistant messages with role prefix

**Dependencies**
- Implement VoiceOver accessibility for all interactive elements

### ✅ Code-sign, notarize, and package as .dmg (1 day)

Code-sign the app with Developer ID certificate. Notarize via notarytool with Apple. Package as .dmg with app icon background image and Applications folder alias. Verify .dmg mounts, app drags to Applications, and launches without Gatekeeper warnings. Create stapled ticket.

**Acceptance Criteria**
- App is code-signed with valid Developer ID
- notarytool returns success and stapled ticket applied
- .dmg mounts and shows app + Applications alias
- App launches on a clean Mac without Gatekeeper warning
- codesign --verify and spctl --assess pass
- App is arm64 only—no x86_64 slice

**Dependencies**
- Run VoiceOver accessibility audit
- Write performance XCUITest benchmarks

## ❓ Open Questions
- Which specific 7B MLX model to use? Need to benchmark CodeLlama-7B-Instruct, DeepSeek-Coder-7B-Instruct, and Qwen2.5-Coder-7B-Instruct for code understanding quality and tokens/sec on M4
- Should the ~4GB MLX model be bundled in the .dmg or downloaded on first launch? Bundling simplifies first run but creates a very large download
- What is the exact context window size of the chosen quantized model? This determines sliding window truncation parameters
- NSTextView with TextKit 1 or TextKit 2 (NSTextLayoutManager)? TextKit 2 is modern but has known large-document issues on macOS 15
- Is the 8GB M4 Mac a supported configuration or is 16GB the minimum? The 4GB model + app overhead may not fit in 8GB
- Should AI conversation history have a retention limit? Proposed 50 conversations with LRU eviction—confirm acceptable
- What hardcoded URL should be used for model download? Need a reliable, fast CDN endpoint for the chosen model weights
- Are there any Apple notarization restrictions on forkpty() in a Developer ID signed app distributed as .dmg?