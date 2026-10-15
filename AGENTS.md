# Eclipse

Notes for coding agents and contributors. Read `README.md` and `CONTRIBUTING.md` first.

Eclipse is a macOS notch app written in Swift with SwiftUI and AppKit. Internal identifiers keep the old name Notch Lab: the Xcode project, the module and the bundle ID `ro.andrei.NotchLab`. Do not rename them; settings and the Keychain service names follow the bundle ID. Never sign with a designated requirement that names only the bundle ID; `scripts/build.sh` refuses it.

## Scope

- Eclipse owns what the notch shows: media, system indicators, calendar, timer, shelf, lock screen.
- Sotto, a separate dictation app, owns microphone capture and speech. Eclipse only shows Sotto's state through the local socket (`docs/socket.md`). Never import Sotto code or require it to run.
- Integrations with other apps (Sotto, T3 Code, Spotify) stay opt-in and off by default.
- Keep GPL and third-party notices (`NOTICE.md`, file headers of adapted code).

## Code

- Simple, typed Swift. Event-driven updates, no polling where macOS offers a notification.
- No continuously repainting animation while idle.
- Private APIs (MediaRemote, SkyLight, DisplayServices) are looked up at runtime and must fail quietly: the feature turns off, the app keeps running.
- Keep tests focused. Pure logic goes into types the checks in `scripts/notch/` can drive without the UI.

## Checks

- `scripts/check.sh` runs the logic checks. Run it for any change to state, geometry or settings.
- `scripts/build.sh` builds the app. Run it for any app change.
- `scripts/render.sh` renders the views from demo data. Use it to show a visual change.
- A passing build does not prove media, lock screen or desktop behaviour. Say what you tested on a real Mac and what you did not.

## Design

Dark, black background, white primary text, dense, minimal copy. No decorative card chrome. No em dashes in UI text. For a visible change, show renders or screenshots before and after.
