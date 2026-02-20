# CodeForge User Guide

## What is CodeForge?

CodeForge is a native macOS code editor built for Apple Silicon Macs. It features TreeSitter syntax highlighting, an integrated terminal, and a local AI assistant powered by MLX — all running entirely on your device with zero cloud dependencies.

## Getting Started

Launch **CodeForge** from your Applications folder or Spotlight. You'll see the main editor window with a toolbar at the top.

### Opening a File

- Click **Open** in the toolbar (or press `Cmd+O`)
- Select a `.swift` or `.py` file
- The file opens with syntax highlighting applied automatically

### Saving

- Click **Save** in the toolbar (or press `Cmd+S`)
- If the file is new, a Save dialog appears for you to choose a location
- CodeForge also autosaves to a temporary file every 5 seconds

## The Three Panels

CodeForge has three collapsible panels:

```
┌──────────────────────────────────┬──────────┐
│                                  │          │
│         Code Editor              │    AI    │
│                                  │  Sidebar │
│                                  │          │
├──────────────────────────────────┴──────────┤
│              Terminal                       │
└─────────────────────────────────────────────┘
```

### Code Editor (center)

The main editing area. Features:
- Monospace font with line numbers
- TreeSitter syntax highlighting for Swift and Python
- Undo/Redo (`Cmd+Z` / `Cmd+Shift+Z`)
- Incremental re-parse as you type (50ms debounce)

### AI Sidebar (right)

Toggle with the sidebar button in the toolbar (or `Cmd+Shift+A`).

The AI assistant runs a 7B parameter language model locally on your Mac using MLX. On first use, it downloads the model (~4GB) — this only happens once.

**Three ways to use the AI:**

1. **Ask a Question** — Type in the text field and press Enter. The AI sees your current file as context.
2. **Explain** — Select code in the editor, then click "Explain". The AI explains what the selected code does.
3. **Suggest Edit** — Type an instruction (or leave blank for general improvement), then click "Suggest Edit". The AI proposes changes shown as inline diffs you can Accept or Reject.

The status dot in the header shows model state:
- Gray = not loaded
- Progress bar = downloading
- Spinning = loading into memory
- Green = ready
- Red = error

Click **Stop** to cancel a generation in progress.

### Terminal (bottom)

Toggle with the terminal button in the toolbar (or `Cmd+Shift+T`).

A full terminal emulator with:
- Your default shell (zsh/bash/fish)
- 256-color support
- Scrollback buffer (10,000 lines default)
- Arrow keys, Tab completion, Ctrl+C — all work normally

## Settings

Open via **CodeForge > Settings** (or `Cmd+,`).

### Appearance
- **Theme**: Dark or Light

### Editor
- **Font Name**: Any installed monospace font (default: SF Mono)
- **Font Size**: 9–36pt
- **Scrollback Lines**: Terminal scrollback buffer size

### AI
- **iCloud Sync**: Opt-in sync for preferences and key bindings
- Shows the current AI model and storage location

### Key Bindings
- View and customize all keyboard shortcuts
- Conflict detection warns when two actions share the same key combo

## Default Keyboard Shortcuts

| Action           | Shortcut         |
|------------------|------------------|
| Open File        | `Cmd+O`          |
| Save File        | `Cmd+S`          |
| Undo             | `Cmd+Z`          |
| Redo             | `Cmd+Shift+Z`    |
| Toggle AI Panel  | `Cmd+Shift+A`    |
| Toggle Terminal  | `Cmd+Shift+T`    |
| Explain Selection| `Cmd+Shift+E`    |
| Ask Question     | `Cmd+Shift+Q`    |

## Menu Bar

- **File**: Open, Save
- **Edit**: Standard Undo/Redo/Cut/Copy/Paste
- **View**: Toggle AI Panel, Toggle Terminal
- **AI**: Explain Selection, Suggest Edit, Ask Question

## Data Storage

All data is stored locally:

| Data | Location |
|------|----------|
| Preferences | `~/Library/Application Support/CodeForge/CodeForge.sqlite` |
| AI Models | `~/Library/Application Support/CodeForge/Models/` |
| Autosave | System temp directory |

AI conversation history is encrypted with AES-256-GCM. The encryption key is stored in your macOS Keychain and never leaves your device.

## Supported File Types

- **Swift** (`.swift`) — full TreeSitter syntax highlighting
- **Python** (`.py`) — full TreeSitter syntax highlighting

Files must be:
- UTF-8 encoded
- Under 50,000 lines
- Regular files (no symlinks or directories)

## System Requirements

- macOS 15 Sequoia or later
- Apple Silicon (M1/M2/M3/M4)
- ~4GB free disk space for AI model (first download)
- ~200MB RAM for the editor; AI model uses additional shared GPU memory

## Troubleshooting

**AI model won't load**: Check that you have internet for the initial download and ~4GB free space. The model is cached after first download.

**Syntax highlighting missing**: Only `.swift` and `.py` files are highlighted. Other file types open as plain text.

**Terminal not responding**: Try toggling the terminal panel off and on. If the shell process crashed, a new one spawns when you reopen.

**File won't open**: Ensure it's a regular `.swift` or `.py` file, UTF-8 encoded, under 50K lines.
