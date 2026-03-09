# 🤖 Godot AI Agent

AI sidebar plugin for **Godot 4** — like VS Code Copilot, but for game development.  
Powered by **qwen/qwen3-coder-480b-a35b-instruct** via **NVIDIA API**.

> **No Python backend needed!** Everything runs directly inside Godot.

---

## ✨ Features

| Feature             | Description                                      |
| ------------------- | ------------------------------------------------ |
| 💬 **Chat**         | Natural language conversation about your project |
| � **Ghost Auto**    | AI-powered code autocomplete directly in editor  |
| 👀 **Diff Preview** | Unified visual diff before accepting AI changes  |
| �📝 **Generate**    | AI writes GDScript from your description         |
| 🔧 **Fix Error**    | AI finds and fixes bugs in your code             |
| 💡 **Explain**      | AI explains scripts in detail                    |
| 🧩 **Create Node**  | AI helps design node structures                  |
| 📂 **Scan Project** | View your project's file tree                    |

---

## 📁 Structure (now only 6 files!)

```
addons/godot_ai_agent/
├── plugin.cfg               ← Plugin manifest
├── plugin.gd                ← Entry point (registers dock & hooks)
├── dock.gd                  ← UI + chat controller + Diff Viewer
├── ghost_autocomplete.gd    ← Editor code completion engine
├── kimi_client.gd           ← NVIDIA API client (HTTPRequest)
└── project_scanner.gd       ← Project file scanner (DirAccess)
```

---

## 🚀 Setup (3 steps)

### 1. Copy to your Godot project

Copy the `addons/godot_ai_agent/` folder into your project's `addons/` folder.

### 2. Enable the plugin

In Godot: **Project → Project Settings → Plugins → Enable "Godot AI Agent"**

### 3. Set your API key

Click the **⚙️** button in the AI panel and paste your NVIDIA API key.

> Get a free key at [build.nvidia.com](https://build.nvidia.com)

**That's it! Start chatting.**

---

## 💬 Example Prompts

```
Create an enemy that patrols left and right
Fix this error: "Invalid operands 'int' and 'String'"
Create a health bar UI component
Explain what CharacterBody2D._physics_process does
Generate a save/load system using JSON
```

---

## 🔧 How It Works

```
Godot Editor
    │
    ▼
AI Agent Dock (sidebar)
    │  HTTPRequest (HTTPS)
    ▼
NVIDIA API
  model: qwen/qwen3-coder-480b-a35b-instruct
  endpoint: /v1/chat/completions
```

No Python. No server. No terminal. Just Godot.

---

## 📄 License

MIT — Use freely.
