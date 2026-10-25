# Claude Menubar Telemetry

A native macOS menu bar utility that shows, at a glance, how much of your **Claude** and **Gemini** plan limits you've used — the real account-wide figures, with when each limit resets.

The interface is a translucent, frosted-glass popover with a terminal aesthetic: monospaced typography, `SNAKE_CASE` labels, segmented meters and terminal-like indicators.

<div align="center">
  <img src="docs/screenshot.png" width="380" alt="AI Telemetry popover showing Claude and Gemini session and weekly usage" />
</div>

---

## Key Features

- **100% Native Swift/SwiftUI**: Compiled directly to a lightweight macOS app bundle (no heavy Electron wrappers). Launches instantly and consumes **< 20MB of RAM**.
- **Zero Setup Log Aggregator**: Automatically watches and parses your local Claude Code sessions stored in `~/.claude/projects/` line-by-line. No Anthropic API keys or proxies are required.
- **Real account-wide quota (optional)**: If you're signed in to Claude Code on this Mac, the app reuses that existing session to read your *actual* rate-limit usage across Desktop, web and CLI combined — not just an estimate from local CLI logs. See [Privacy & Safety](#privacy--safety) for exactly what that involves.
- **Usage credits**: Models billed against credits rather than the weekly plan quota (Fable, most notably) are tracked where they actually live — your monthly credit limit, how much of it you've spent, what's left, and any prepaid balance on the account.
- **Gemini too**: Right below Claude, the popover shows how much of your Google account's Gemini allowance you've used — the current 5-hour allowance and the weekly limit, the same figures as `gemini.google.com/usage`, covering the web, mobile and every other Gemini app. Sign in to Google once from the popover and it stays connected. Gemini CLI users also get its per-model quota and local activity.
- **Per-model weekly windows**: When Anthropic publishes a separate weekly window for a model, it gets its own progress bar instead of a made-up percentage.
- **Live Reset Countdown**: Shows exactly when your current 5-hour session window resets, ticking down in real time.
- **Multi-Model Breakdown**: Groups prompts and tokens per model (Claude Fable, Sonnet, Opus…, and Gemini models if you use Gemini CLI) in a folding table.
- **No Keychain password prompts**: The Claude Code session is read through `/usr/bin/security`, the same tool Claude Code uses to store it, so macOS hands it over without asking — not once a day, not after every token refresh.
- **Frosted-glass, terminal-style UI**: Translucent popover over the system blur, monospaced typography (JetBrains Mono when installed) and terminal indicators. It sizes itself to its content: no empty space, and it grows when a drawer opens.

---

## Design Showcase

The popover is a sheet of frosted glass: the system blur (`NSVisualEffectView`, HUD material), translucent panels with hairline borders, and the terminal look of its title bar everywhere — `SNAKE_CASE` labels, `>` section prompts, `// comments` for context and segmented meters. Accent colors:
- **Claude**: Clay `#D97757`
- **Gemini**: Violet `#A87FFB`
- **OK / warning / limit**: `#59A869` / `#EDA200` / `#DB5860` (meters turn amber at 70% and red at 90%)

Everything fits in one view, so both providers can be read at a glance when you click the Menu Bar icon (`terminal` system icon):
1. **Header**: `>_ AI_TELEMETRY` with the worst state of the two providers. Each section also has its own badge: `● LIVE` (real account data), `● HIGH_USAGE` (90%+), `● RATE_LIMITED` (limit reached), `● LOGS_ONLY` (Claude without a live session, local estimate), `● LOGIN` (Gemini waiting for you to connect your Google account) or `● NO_DATA`.
2. **`> CLAUDE`**: One line per limit — 5-hour session, all-models week and every model-scoped weekly window the account has — each with its meter, percentage and reset (a countdown under a day, weekday and time beyond). Below them, usage credits spent against the monthly limit and the prepaid balance when there is one. Without a live session it degrades to a plain Fable requests/tokens counter rather than inventing a percentage.
3. **`> GEMINI`**: Your Google account's Gemini app usage, exactly as `gemini.google.com/usage` shows it — `SESION_5H` (the current allowance, refreshed every 5 hours) and `SEMANA` (the weekly limit), each with its reset — plus your plan in the comment line. Until you connect your Google account it shows a `CUENTA_GOOGLE · conectar →` row instead. If you also use Gemini CLI, its per-model quota (`CLI_…`) and last-24h activity appear underneath.
4. **`[+] MODELOS`**: Folded by default; prompts and tokens for the 6 most-used models of Claude Code (all history) and, if you use it, Gemini CLI (7 days).
5. **`[+] CONFIG`**: Start with macOS, `DESCONECTAR_GOOGLE` (forget the app's Google session) and the fallback limits used when there's no live Claude data. Only one drawer is open at a time, so the popover always fits on screen.
6. **Footer Controls**: Manually refresh statistics, see the last sync time, or quit.

---

## Privacy & Safety

- **Local-first, with optional read-only network calls**: by default the app reads your local Claude Code session logs (`~/.claude/projects/**/*.jsonl`) and Gemini CLI conversation logs (`~/.gemini/tmp/*/chats/`) entirely offline. If you're signed in to Claude Code on this Mac, it additionally reuses that existing OAuth session to issue a `GET` to `api.anthropic.com` at most once a minute. That request consumes no quota and no tokens; it's the same endpoint the CLI's own `/usage` command reads. This is the only way to show the *exact* quota used across Desktop, web and CLI combined; a local log parser alone cannot see usage that happened outside the CLI.
- **How the Claude Code session is read, and why there's no password prompt any more**: Claude Code keeps its session in the macOS Keychain under the item `Claude Code-credentials`, but it doesn't use the Keychain API to do it: it shells out to `/usr/bin/security`. That makes `/usr/bin/security` the only trusted application on the item, which is why earlier versions of this app (which read it through the Keychain API) got a password dialog every time Claude Code renewed its token. The app now reads the item with that very same command (`security find-generic-password -s "Claude Code-credentials" -w`), so macOS returns it without asking, exactly as it does for the CLI. If Claude Code stores its session in `~/.claude/.credentials.json` instead, that file is used.
- **The app never writes Claude Code's credentials and never sends your token anywhere except Anthropic's own API**: it only *reads* them, keeps the access token in memory, and deliberately ignores the refresh token — renewing the session on our own could rotate the CLI's token and log you out of your own terminal. When the token expires, the next time you use Claude Code renews it and the app picks it up.
- **Gemini app usage**: Google publishes no API for it; the only source is the `gemini.google.com/usage` page, which needs a signed-in Google session. The app does **not** read your browser's cookies (Chrome encrypts them with a Keychain key, which would bring the password prompts back). Instead, the `CUENTA_GOOGLE · conectar →` row opens a Google sign-in window inside the app; the session is stored in the app's own WebKit storage. When you open the popover, the app loads that page in a hidden web view at most once a minute and reads the two percentages and reset times from its text — nothing is sent anywhere else. `[+] CONFIG → DESCONECTAR_GOOGLE` deletes that session. Because it reads a web page rather than an API, a redesign of that page by Google can break it; the section then says so and the rest of the app keeps working.
- **Gemini CLI**: if you signed in to Gemini CLI with Google, the app reads `~/.gemini/oauth_creds.json` and asks Google's Code Assist API (`cloudcode-pa.googleapis.com`) for your plan and remaining quota, the same calls Gemini CLI makes for `/stats`. Neither consumes quota. Google access tokens only last an hour, so when the one in that file has expired the app renews it with Gemini CLI's public OAuth client; Google doesn't rotate the refresh token when doing so, so this can't log the CLI out. The renewed token lives only in memory — the app never writes to `~/.gemini`. Gemini CLI setups using an API key, Vertex AI or encrypted credential storage have no such session, so only the local log figures are shown.
- **Upgrading from an earlier version**: older versions kept a copy of the Claude token in a Keychain item of their own named `com.juanmmm21.ClaudeTelemetry.session`. It's no longer used; you can delete it from Keychain Access if you want.
- **Fails closed, not open**: if you aren't logged into Claude Code, Google or Gemini CLI, a session has expired, Google changes its usage page, or you're offline, each section says why in its `//` comment and falls back to what it can still show (for Claude, the local log-only approximation described below) — the app never crashes or blocks waiting on the network.
- **Read-only on your session logs**: local log parsing only accumulates numeric token values; it never writes to, deletes, or modifies your project or Claude session files.

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
To install it permanently, simply drag the compiled app inside the `build/` folder into your macOS `/Applications` directory. When updating, quit the running copy first (`QUIT` in the popover, or `killall ClaudeTelemetry`).

### Step 4: Connect your accounts
- **Claude**: nothing to do — if you're signed in to Claude Code on this Mac, the `> CLAUDE` section shows `● LIVE` straight away. If it says the session expired, open Claude Code once and it renews it.
- **Gemini**: click `CUENTA_GOOGLE · conectar →` in the `> GEMINI` section and sign in to Google in the window that opens. It closes by itself when you're done and the section switches to `● LIVE`. You only do this once.

---

## File Structure

```
├── build.sh                 # Standard macOS build script
├── .gitignore               # Excludes intermediate compiler targets
├── README.md                # Project documentation
├── docs/
│   └── screenshot.png       # Popover screenshot used above
└── src/
    ├── main.swift                # Application entry point
    ├── AppDelegate.swift         # Status bar button and NSPopover controllers
    ├── DashboardView.swift       # SwiftUI interface (glass panels, meters, drawers)
    ├── TelemetryManager.swift    # Log parsing logic, cache system & rates
    ├── AccountUsageService.swift # Optional live account-quota & usage-credits lookup
    ├── ClaudeSessionStore.swift  # Prompt-free read of the Claude Code session
    ├── GeminiUsageService.swift  # Gemini CLI session & per-model daily quota
    ├── GeminiLogScanner.swift    # Gemini CLI conversation logs (prompts & tokens)
    ├── GeminiWebUsageService.swift # Gemini app usage from gemini.google.com/usage
    ├── LaunchAtLoginService.swift # "Start with macOS" registration (SMAppService)
    ├── Theme.swift               # Translucent palette, provider colors & typography
    └── AppIcon.png               # High-resolution source icon (1024x1024)
```

---

## How Quota Tracking Works

- **Claude Pro/Max limits are a continuous utilization score, not a request counter.** Anthropic tracks a rolling 5-hour window and a rolling 7-day window, each as a single percentage of the account's total allowance — there's no per-request "slot" that individually expires. There is exactly one reset time per window, not one per request.
- **Some models are billed against credits instead of that quota.** Fable is the current example: once the plan's allowance is used up, its consumption is paid from *usage credits*, which carry their own monthly limit, their own spend counter and their own reset — not a percentage of the weekly window. The app reads that state directly (limit, spent, remaining, prepaid balance) rather than trying to express it as a share of a quota it doesn't belong to.
- **With a live session (see [Privacy & Safety](#privacy--safety))**: the app reads real percentages, real reset times, per-model weekly windows and credit state directly from the account, so what you see matches it exactly.
- **The Gemini app uses compute-based limits.** Google measures app usage (web, mobile, Workspace side panels…) as an allowance that refreshes every 5 hours, capped weekly, consumed faster by heavier models and features; it shows only percentages, never a prompt count. The app shows those same two percentages.
- **Gemini CLI quotas are daily and per model.** Google's Code Assist backend reports, for each model, the fraction of today's requests still available and when it resets; the app shows the used share of each one. Free "Login with Google" accounts, Google AI Pro/Ultra and Code Assist Standard/Enterprise each have different limits, and the backend reports whichever applies to your account.
- **Without a live session**: the app falls back to a local approximation — it counts your own typed prompts in `~/.claude/projects/**/*.jsonl` within the last 5 hours / 7 days and divides by a configurable limit (see the settings drawer in the app). This is a rough proxy, not a real measurement: it only sees Claude Code CLI activity, ignores Desktop/web/mobile usage, and doesn't account for how much a given request actually costs against the real utilization score.

---

## Author

Built by **juanmmm21** (https://github.com/juanmmm21).
*Senior Developer & Observability enthusiast.*
