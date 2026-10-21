# WakeGuard

A native macOS menu bar app that keeps your Mac awake with the lid closed, follows local agent activity, and allows sleep when the work finishes.

[Website](https://myurtsev.github.io/wakeguard/) · [Download beta](https://github.com/myurtsev/wakeguard/releases/tag/v1.3.2-beta.1) · [Report a bug](https://github.com/myurtsev/wakeguard/issues)

Requires Apple Silicon and macOS 13 or later. No accounts, advertising or telemetry. Core sleep and agent monitoring runs locally; browsing the remote plugin catalog and enabled integrations can make network requests.

## Features

- Manual sessions or **Until agents finish** for supported local Codex and Claude Code sessions.
- Separate policies for power adapter and battery, with battery, thermal, and time limits.
- Automatic release of WakeGuard's sleep override if the app stops renewing its lease.
- Closed-lid session summaries and local activity history, automatically removed after seven days.
- Drag-to-Applications installation with a separate system helper.
- Optional plugins, with an in-app catalog, package import and permission review. See the [plugin guide](docs/plugins.md) for installation and authoring.

## Installation

**Beta:** the app is ad-hoc signed, the helper package is unsigned, and the download is not notarized by Apple. It has been tested on one Mac; compatibility across Macs and macOS versions is not yet established.

1. Download **WakeGuard.dmg** from [Releases](https://github.com/myurtsev/wakeguard/releases/tag/v1.3.2-beta.1).
2. Open the DMG and drag **WakeGuard.app** into **Applications**.
3. Open WakeGuard from Applications. macOS may block this beta; review [Apple's guidance for apps from unidentified developers](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac) before allowing it. Do not disable Gatekeeper system-wide.
4. Click **Install system helper** and approve the macOS administrator prompt.
5. Choose a mode and click **Start**. A session never starts automatically.

The helper changes a system-wide sleep setting and restores its own override when the session ends. Its commands and paths are fixed. It stores no passwords and installs no sudoers rule. Avoid running another app that changes the same sleep setting concurrently.

For an update, stop the current session and quit WakeGuard before replacing the app. Update the helper when prompted. Settings and activity history are preserved for the same account.

## Agent detection

Codex detection uses local lifecycle metadata in `~/.codex/sessions`. This format is version-dependent. Custom profiles, ephemeral runs, cloud tasks, and future scheduled work are outside detection.

Claude Code needs **More options → Connect Claude Code** and restarted Claude Code sessions. Existing hooks are preserved. Ordinary Claude chat and Cowork are not supported. Tasks waiting for input and uncertain agent states prevent automatic completion; safety limits still apply. WakeGuard does not approve agent permissions.

Read the [app documentation](app/README.md) for completion timing, safety, logs, and removal.

## Build

The React landing page is in `src/`; the native app, installer, and tests are in `app/`.

For the website, use Node.js 24:

```sh
npm ci
npm run build
npm run preview
```

The page is pre-rendered to static HTML in `dist/`. GitHub Actions builds and deploys it to GitHub Pages on pushes to `main`.

For the app, use an Apple Silicon Mac with Apple's Command Line Tools and Python 3:

```sh
./app/build.sh
```

This runs the app and installer checks, then creates an ad-hoc signed app and DMG in `WakeGuard-build/`. It installs nothing. Physical lid, battery, thermal, and display behavior still require hardware checks.

GitHub Actions runs the native build, Swift checks, and installer checks on Apple Silicon for pull requests and pushes to `main`. The workflow can also be run manually.

## License

[MIT](LICENSE).
