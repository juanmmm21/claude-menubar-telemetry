# Claude Menubar Telemetry 📊

A native macOS menu bar utility that provides real-time token usage, prompt caching efficiency, and cost telemetry for your **Claude Code** CLI sessions. 

The interface is styled with a developer-centric, dark-mode **JetBrains Mono IDE** aesthetic, featuring custom monospaced typography, clean console tables, and terminal-like indicators.

<div align="center">
  <img src="src/AppIcon.png" width="128" height="128" alt="Claude Telemetry Icon" />
</div>

---

## Key Features

- 🚀 **100% Native Swift/SwiftUI**: Compiled directly to a lightweight macOS app bundle (no heavy Electron wrappers). Launches instantly and consumes **< 20MB of RAM**.
- 📥 **Zero Setup Log Aggregator**: Automatically watches and parses your local Claude Code sessions stored in `~/.claude/projects/` line-by-line. No Anthropic API keys or proxies are required.
- 💵 **Live Cost Estimator**: Calculates dollar spent in real-time, mapping input/output tokens to current Anthropic developer pricing tiers. It fully supports standard models as well as the new autonomous reasoning **Claude Fable 5** model.
- ⚡ **Prompt Caching Efficiency**: Displays your caching hit ratios using a retro, ASCII-style command-line progress bar. It lets you monitor caching optimization (which offers a **90% discount** on cache-read tokens).
- 📂 **Multi-Project Breakdown**: Automatically groups, cleans, and lists token usage and costs across all directories where you use Claude Code.
- 🎨 **JetBrains Mono UI**: Designed to blend into a developer's workspace with dark slate backgrounds (`#1E1F22`), grid borders (`#43454A`), and terminal indicators.
- 🛠️ **Demo Mode**: Includes a simulated mock telemetry toggle in the footer to showcase the user interface immediately.

---

## Design Showcase

The app uses the following JetBrains IDE color palette:
- **Background**: Deep Slate `#1E1F22`
- **Fields/Panels**: Lighter Slate `#2B2D30`
- **Grid Lines**: Muted Gray `#43454A`
- **Success Accent**: Emerald Green `#59A869`
- **Focus Accent**: Royal Blue `#3574F0`

The UI is structured as follows when you click the Menu Bar icon (`terminal` system icon):
1. **Header**: Shows active state (`● LOGS_ACTIVE` or `● DEMO_MODE`).
2. **Dashboard Grid**: Prominent metrics displaying **Total Cost (USD)**, **Request Count**, **Input Tokens**, and **Output Tokens**.
3. **ASCII Caching Bar**: Prompts Cache hit ratio bar `[#####----------------] 24.5%` highlighting read vs write performance.
4. **Projects Breakdown**: Monospaced table breaking down total requests, cost, and token volume per workspace directory.
5. **Recent Sessions**: Feed of the last 5 session histories, including timestamps and model details.
6. **Footer Controls**: Options to toggle Demo mode, manually refresh statistics, see the last scan timestamp, or quit.

---

## Privacy & Safety

- **Private & Local-Only**: The application runs completely offline and locally. It does not send any statistics, telemetry, logs, or keys to third-party endpoints.
- **Read-Only**: The utility reads logs purely to accumulate numerical token values. It does not write to, delete, or modify any of your project or Claude session files.

---

## How to Build & Run

### Prerequisites
- A Mac running **macOS 12.0** or newer.
- **Xcode Command Line Tools** installed (provides the `swiftc` compiler). You can install it by running `xcode-select --install` in your terminal.

### Step 1: Clone the Repository
```bash
git clone https://github.com/juanmmm21/claude-menubar-telemetry.git
cd claude-menubar-telemetry
```

### Step 2: Build the Application
We provide an automated compilation script `build.sh` that cleans, transcodes the source image to a native macOS `.icns` format, compiles the binary, and packages the bundle structure:
```bash
chmod +x build.sh
./build.sh
```

### Step 3: Run and Install
Once the build is complete, you can launch the app directly:
```bash
open build/ClaudeTelemetry.app
```
To install it permanently, simply drag the compiled app inside the `build/` folder into your macOS `/Applications` directory.

---

## File Structure

```
├── build.sh                 # Standard macOS build script
├── .gitignore               # Excludes intermediate compiler targets
├── README.md                # Project documentation
└── src/
    ├── main.swift           # Application entry point
    ├── AppDelegate.swift    # Status bar button and NSPopover controllers
    ├── DashboardView.swift  # SwiftUI monospaced interface
    ├── TelemetryManager.swift# Log parsing logic, cache system & rates
    ├── Theme.swift          # Color palette & JetBrains Mono typography tokens
    └── AppIcon.png          # High-resolution source icon (1024x1024)
```

---

## Supported Model Rates (USD per Million)

| Model Name | Input Rate | Output Rate | Cache Write | Cache Read |
| :--- | :--- | :--- | :--- | :--- |
| **Claude Fable 5** | $10.00 | $50.00 | $12.50 | $1.00 |
| **Claude 3.5 Sonnet** | $3.00 | $15.00 | $3.75 | $0.30 |
| **Claude 3.5 Haiku** | $0.80 | $4.00 | $1.00 | $0.08 |
| **Claude 3 Opus** | $15.00 | $75.00 | $18.75 | $1.50 |
| **Claude 3 Haiku** | $0.25 | $1.25 | $0.31 | $0.03 |

---

## Author

Desarrollado por **juanmmm21** (https://github.com/juanmmm21). 
*Senior Developer & Observability enthusiast.*
