# AI Stack Native v6

A native macOS AI infrastructure control center.

## UI
- Overview
- Services
- Providers
- Models
- Routing
- Diagnostics
- Activity
- Logs
- Settings
- Menu Bar quick control

## Architecture
- 9Router is treated as managed infrastructure/router, not as the only provider.
- Providers are configuration-driven and support OpenAI Compatible, Anthropic, Gemini, Local and Custom types.
- A model may be associated with multiple providers.
- Routing UI supports Priority, Round Robin, Lowest Latency, Lowest Cost, Failover and Smart strategies.
- Provider configuration is stored in `~/Library/Application Support/AI Stack/providers.json`.
- No personal API key is embedded in the app bundle.

## Runtime
- AI Stack manages 9Router on `127.0.0.1:20128`.
- The current local AgentRouter proxy is managed on `127.0.0.1:8318`.
- Auto-healing checks services periodically.
- Closing the main window leaves the menu-bar app alive.
- Quit AI Stack stops managed services.

## Build
Run `Install-AI-Stack.command` on macOS. The installer builds a fresh app and copies it to `/Applications`.


### Window lifecycle
AI Stack is a normal macOS application with a Dock icon and a main WindowGroup. Launching the app opens the main dashboard. Closing the window leaves the app running in the menu bar; use Quit AI Stack to stop managed services and exit completely.
