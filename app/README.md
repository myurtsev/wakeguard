# WakeGuard 1.3.3

Standalone macOS menu bar app for Apple Silicon, macOS 13 or later. Built independently, with no external libraries, accounts or advertising. Core monitoring runs locally; the remote plugin catalog and enabled integrations can make network requests.

## Install

1. Open **WakeGuard.dmg**.
2. Drag **WakeGuard.app** to **Applications**.
3. Open WakeGuard from Applications and click **Install system helper**.
4. Approve the native macOS administrator prompt. There is no Installer wizard.

For an update, quit the existing WakeGuard app before replacing it. Open the new app and, if prompted, click **Update system helper**. Updating preserves settings and activity history for the same account. A session never starts automatically.

The embedded package installs only the system helper and its launch daemon. It does not replace the app. The helper serves the account logged in during installation. Its commands and installation paths are fixed; no sudoers rule or password storage is used.

This local build is ad-hoc signed and is not notarized by Apple. The embedded helper package is unsigned. Do not disable Gatekeeper system-wide.

## Controls

- **Start / Stop:** explicitly start or end a keep-awake session.
- **Manual / Until agents finish:** choose manual stopping or completion detection for local agents.
- **Power adapter / Battery:** choose which power sources allow sleep prevention. Only the power adapter is enabled by default.
- **Battery limit:** stop on battery at or below 20%, 30% or 40%.
- **Time limit:** 30, 60 or 120 minutes, or no time limit. The default is 60 minutes. This remains a maximum in agent mode.
- **Turn off displays when lid closes:** request display sleep, including connected displays. Disable it to keep an external display on.
- **Launch at login:** open the app without starting a session.
- **Activity:** view recent status changes, sleep measurements and closed-lid summaries.

The menu bar panel shows working agents separately from agents waiting for input. Unavailable status remains visible and prevents automatic completion.

Open **More options → Plugins…** for the offline catalog, remote refresh, package import, permission review and per-plugin settings. Plugins are disabled after installation or update until you enable them. Read the [plugin guide](../docs/plugins.md) for the JavaScript API, examples and distribution instructions.

Lock the Mac with **Control–Command–Q** before closing the lid. Display sleep does not explicitly lock the screen. Keep the Mac on a ventilated surface.

## Activity and summaries

WakeGuard records changes in session state, power source, thermal state, lid state and measured sleep. Battery percentage is included as context for these events; a percentage change alone does not create a log entry. A sleep request is recorded separately from actual sleep. Prompts, responses, commands, agent titles and conversation contents are not recorded.

Activity is removed after seven days, with additional caps of 512 events, 64 summaries and 256 KiB. Only changes trigger logging; an ongoing closed-lid session is checkpointed at most every 30 seconds unless its state changes. Background log writes do not run on the helper's lease and safety loop.

The helper keeps a root-only canonical log and publishes a private snapshot readable by the enrolled account. It never uses the snapshot for privileged decisions. Re-enrolling a different account removes the earlier account's history. Removing the helper also removes its history.

After a detected closed-to-open lid transition, **Session summary** opens once only if WakeGuard kept the Mac awake during that closed-lid period. It shows closed-lid duration, confirmed sleep prevention, inactive time, actual system sleep and any unobserved time. Summaries remain available in Activity. The window does not pause the app heartbeat.

System sleep is measured from the difference between macOS clocks that include and exclude sleep. Scheduling gaps, helper restarts and unknown lid state are not treated as confirmed keep-awake time. A restart gap may use a wall-clock estimate marked unobserved. If the helper starts with the lid already closed, the summary is marked incomplete. A crash can lose up to 30 seconds since the last checkpoint; time before the first observation cannot be reconstructed reliably.

## Until agents finish

Start a local agent task, select **Until agents finish**, then click **Start**. All known tasks must finish; new work resets the completion wait. After 30 seconds of confirmed inactivity, WakeGuard stops sleep prevention. With the lid closed, it requests system sleep. With the lid open, it only stops sleep prevention. Battery, thermal and time limits always apply.

Codex is monitored using lifecycle metadata under `~/.codex/sessions`, without changing Codex configuration. This is an internal, version-dependent format. Only persisted local turns with recognized writers are covered. Custom `CODEX_HOME` profiles, ephemeral runs, cloud tasks and future scheduled work are outside detection. A disappeared active writer without a proven matching completion remains unknown. Large logs are read in bounded chunks after startup; status remains unavailable until the lifecycle is verified.

Use **More options → Connect Claude Code** to add WakeGuard's status hooks to `~/.claude/settings.json`. Existing settings and hooks are preserved, and replaced settings receive a backup. Restart Claude Code sessions after connecting or disconnecting. A concurrent settings change reports its backup path.

Claude's Stop event is a completion candidate. An idle confirmation and empty background/cron registries are required; completion typically takes about 90 seconds after the last work. Permission requests and other input requests remain active. Native Claude Code, including local sessions in the Claude desktop app, and connected node installations are supported. Unconnected node installations, disabled hooks, ordinary Claude chat and Cowork are not fully detectable. WakeGuard does not approve agent permissions.

Lost events, uncertain state or missing tasks prevent automatic completion. The time limit and safety stops remain the fallback. Reconnecting Claude Code resets only WakeGuard's stored agent metadata.

## Safety and removal

The helper independently checks power, battery and macOS thermal state. Serious or critical thermal state stops the session. Unknown values prevent sleep prevention. Thermal state is not a temperature reading. Safety stops do not resume automatically.

The app renews a lease every two seconds on its main run loop. If renewals stop, the helper releases its sleep override after approximately ten seconds, plus bounded system-command response time. The lease clock includes system sleep. A paused, expired session cannot resume after waking.

On helper restart or reboot, the helper restores its own recorded sleep override before accepting a new session. A pre-existing sleep override from another app is refused. WakeGuard uses a global macOS setting; do not run another app that changes that same setting simultaneously.

**Remove system helper** restores normal sleep, then removes only WakeGuard's helper, daemon and helper data. The app and preferences remain. Disconnect Claude Code before deleting the app in Finder.

## Build and verification

Building requires Apple's Command Line Tools and Python 3 for installer fixtures. The app requires neither Python nor an external runtime.

```sh
./build.sh /path/to/output
```

The script runs policy, session, IPC, helper, activity, agent, hook and installer checks, then builds an Apple Silicon app and drag-to-Applications DMG. It installs nothing. Package verification confirms the embedded payload contains no application files and preserves shared directory permissions.

Native panel, activity and summary views are checked in light and dark appearance. Automated tests cover clocks, unknown lid state, restarts, log retention, asynchronous write acknowledgements, parallel agents, missing events, hook preservation and protected filesystem boundaries.

Physical lid closure, battery/thermal cutoffs, display sleep and macOS login approval still require checks on the target Mac. Simulated checks cannot establish behavior of a stalled kernel or all hardware configurations.
