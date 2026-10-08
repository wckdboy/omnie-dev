# Omnie-dev

A native, offline-first IDE for agent-assisted coding. On iPad it's the full IDE; on iPhone it's an agent-first vibecoding app. See [docs/PLAN.md](docs/PLAN.md).

Bundle ID: `ai.wckd.omniedev` · iPadOS / iOS 26+

## Layout

| Path | What |
|---|---|
| `App/Sources` | The app target. `IDE/` is the iPad shell, `Vibe/` the iPhone shell, `Shell/` is shared |
| `Packages/OmnieKit` | Swift packages: `DesignKit` (theme, density, metrics), `CommandKit` (command registry + palette search), `WorkspaceKit` (file tree, text files) |
| `design/tokens.json` | Design tokens. `DesignKit/Tokens+Generated.swift` is generated from it |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and not committed |

## Build

```sh
brew install xcodegen          # once
xcodegen generate              # after adding files or editing project.yml
open OmnieDev.xcodeproj

swift scripts/gen-theme.swift  # after editing design/tokens.json
cd Packages/OmnieKit && swift test
```

Debug builds accept `-OmnieOpenFolder /path` to open a folder at launch, which is handy in the simulator.
