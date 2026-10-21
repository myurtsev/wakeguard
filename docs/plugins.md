# WakeGuard plugins

Plugins add status displays, notifications and opt-in HTTPS integrations to WakeGuard. They cannot start or stop a keep-awake session, change safety limits, read conversations, run shell commands or call the system helper.

Plugins require WakeGuard 1.3.0 or later.

## Install and manage

Open **Plugins** from WakeGuard's menu to browse the available plugins. The app includes an offline catalog. **Refresh** fetches the current catalog from `https://myurtsev.github.io/wakeguard/plugins/catalog.json`.

Choose a plugin, review its author, source and requested permissions, then install it. You can also import a `.wakeguardplugin` file or install from an HTTPS package URL. Installing or updating leaves the plugin disabled. Configure any required settings, then explicitly enable it. Use the same window to run its commands, disable it or remove it.

The included examples are:

- **Session notifications:** sends a macOS notification when an observed session starts or stops. Enabling it during an existing session does not announce a new start. macOS notification settings still apply.
- **Agent status:** shows working, waiting and unavailable counts, with a command that opens the agent detection documentation.

Plugins see WakeGuard's observations. They do not expand Codex or Claude Code detection coverage. An unavailable agent is not a completed agent.

## Trust and permissions

Only install code from an author you trust. A catalog checksum checks that the downloaded bytes match the listed package; it is not a publisher signature or a guarantee that the code is safe. Imported files and direct URLs have no catalog checksum to establish that match. Plugin identity and author names are self-declared.

Every enabled plugin receives session state and aggregate agent counts. Optional permissions are:

| Permission | Access |
| --- | --- |
| `notifications` | Show macOS notifications. |
| `network` | Send HTTPS requests to the exact listed hosts. Subdomains need their own entries. Redirects are refused. |
| `openURLs` | Open an HTTPS link only in response to a plugin command that you run. |

Network access can send the state and settings supplied to a plugin to an external service. Review the script and the service before providing credentials. Secret settings are stored in macOS Keychain and passed to that plugin while it runs; the plugin can use or transmit them within its granted capabilities. Never put credentials in a manifest, script, repository or catalog.

WakeGuard uses the login keychain so secret settings also work in its ad-hoc signed build. A rebuilt or updated app can have a different signing identity; Keychain may refuse access to an earlier build's items. WakeGuard fails closed without displaying an authentication prompt or falling back to a plaintext file. If a saved secret becomes unavailable, review the app update and manage that WakeGuard item in Keychain Access before configuring it again. Ordinary text and toggle settings are saved locally without Keychain protection; use the `secret` type for credentials.

JavaScript runs in a separate, bounded process with no exposed filesystem, shell, Node.js, browser or native bridge APIs. This is not an operating-system sandbox or a claim that untrusted code is harmless. Plugins do not run in the privileged helper. Slow or broken plugins report an error instead of blocking the helper's lease renewal.

## Create a plugin

No npm packages, compiler or JavaScript build step is required. Copy the template, change its manifest and implement its handler:

```sh
cp -R plugins/template /tmp/my-wakeguard-plugin
```

The folder contains `manifest.json` and `plugin.js`. Give the plugin an id you control, such as `com.example.my-plugin`. Build one self-contained package with Python 3:

```sh
python3 plugins/pack.py pack /tmp/my-wakeguard-plugin /tmp/my-plugin.wakeguardplugin
```

Import the output in WakeGuard, review it, then enable it. After a source change, increase the version, rebuild and import the new file. A package contains the manifest fields and its JavaScript source as the `script` string. It is UTF-8 JSON, not an archive or executable.

Minimal `manifest.json`:

```json
{
  "apiVersion": 1,
  "id": "com.example.my-plugin",
  "name": "My plugin",
  "version": "1.0.0",
  "author": "Your name",
  "description": "Shows the current WakeGuard session state.",
  "permissions": { "notifications": false, "network": [], "openURLs": false },
  "settings": [],
  "commands": []
}
```

`homepage` is an optional HTTPS URL. Versions have exactly three numeric parts without leading zeroes, such as `1.2.0`; prerelease suffixes are not supported. Ids use lowercase reverse-DNS components. Names, authors and descriptions must be nonempty plain text, at most 60, 100 and 300 characters respectively.

Minimal `plugin.js`:

```js
function onEvent(event, api) {
    api.setStatus(event.session.active ? "Session active" : "Off");
}
```

## Events and lifecycle

WakeGuard calls `onEvent(event, api)` synchronously in a fresh JavaScript process for each event. Globals do not persist between events. Do not rely on promises, timers, background work or module imports. Enqueue actions through the supplied API during the handler call, then return no value. An `async` handler or another returned value is rejected.

| Event type | When it is delivered |
| --- | --- |
| `snapshot` | An enabled plugin first receives the current known state. This does not establish that a session has just started. |
| `stateChanged` | Published session state or agent counts change. `previousSession` and `previousAgents` hold the preceding observation. |
| `command` | You run one of the plugin's declared commands. `command` holds its id. |

Example event:

```json
{
  "type": "stateChanged",
  "timestamp": 1792497600,
  "session": {
    "active": true,
    "mode": "awake",
    "reason": "Session active",
    "onAC": true,
    "battery": 82,
    "thermal": "nominal",
    "lidClosed": false
  },
  "agents": { "working": 2, "waiting": 1, "unknown": 0 },
  "previousSession": {
    "active": false,
    "mode": "off",
    "reason": "Off",
    "onAC": true,
    "battery": 82,
    "thermal": "nominal",
    "lidClosed": false
  },
  "previousAgents": { "working": 2, "waiting": 1, "unknown": 0 }
}
```

`timestamp` is Unix time in seconds. `session.active` identifies an active WakeGuard session; it is not proof that sleep prevention is currently applied. Treat `mode`, `reason` and `thermal` as status values, not stable commands or authorization. `onAC`, `battery` and `lidClosed` may be absent or `null` when unknown. Battery is a percentage when known. Agents are counts, with no titles, prompts, responses, paths or conversation contents.

Check the event type and previous state before producing one-time effects. A battery change can produce `stateChanged` without starting or stopping a session. See [Session notifications](../plugins/session-notifications/plugin.js) for transition handling.

Events and outgoing requests are best effort. A crash, quit, sleep or connection failure can prevent delivery; no final shutdown event or completion notification is guaranteed. Plugins cannot delay a safety stop or guarantee an external status reset.

## API

All API methods enqueue actions; they do not provide a delivery response. An invocation can return at most 16 actions and has a two-second execution limit. Invalid or unauthorized actions stop the plugin; enable it again to retry after correcting the cause.

### `api.settings`

A dictionary of configured string values. Toggle values are the strings `"true"` and `"false"`, not booleans. Declare settings in the manifest:

```json
[
  { "key": "label", "label": "Display label", "type": "text", "required": false, "defaultValue": "My Mac" },
  { "key": "token", "label": "API token", "type": "secret", "required": true },
  { "key": "notify", "label": "Show notifications", "type": "toggle", "required": false, "defaultValue": "true" }
]
```

Up to 12 unique settings are allowed. Keys start with a lowercase letter and contain at most 40 ASCII letters, digits or underscores. Labels contain at most 60 characters. Defaults contain at most 2048 UTF-8 bytes. Secret settings cannot have defaults. Required settings must be configured before enabling the plugin.

### `api.setStatus(text)`

Shows up to 120 characters of plain text in the plugin's row. An empty string clears it. No extra permission is needed.

```js
api.setStatus(event.agents.working + " working");
```

### `api.notify(title, body)`

Requires `notifications: true`. The title and body must be nonempty plain text, at most 100 and 500 characters respectively. macOS may suppress notifications according to the user's notification settings.

```js
api.notify("WakeGuard started", "Your keep-awake session is active.");
```

### `api.http({ url, method, headers, body })`

Requires an exact hostname in `permissions.network`. URLs must use HTTPS, with no URL credentials or custom port. Redirects are refused. Supported methods are `GET`, `POST`, `PUT`, `PATCH` and `DELETE`; the default is `POST`. This API sends a request without exposing its response to JavaScript. Use a service's idempotent endpoint where possible.

```js
if (event.type === "stateChanged" && event.previousSession &&
    event.session.active !== event.previousSession.active) {
    api.http({
        url: "https://example.com/wakeguard",
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ active: event.session.active })
    });
}
```

Declare `"network": ["example.com"]` for this example. A manifest can list up to eight distinct hosts. Request bodies are limited to 16 KiB, responses to 64 KiB, and each plugin can have up to four pending requests. Up to 12 headers are allowed; header names contain at most 80 letters, digits or hyphens, values at most 2048 UTF-8 bytes without line breaks. `Host`, `Cookie`, `Connection`, `Content-Length` and `Proxy-Authorization` cannot be supplied. A network error stops the plugin and appears in its row. Do not repeatedly send a request on every snapshot or battery change.

### `api.openURL(url)`

Requires `openURLs: true` and a `command` event. Only HTTPS URLs without embedded credentials or custom ports are accepted. Declare commands in the manifest:

```json
[{ "id": "help", "title": "Open help" }]
```

```js
if (event.type === "command" && event.command === "help") {
    api.openURL("https://example.com/help");
}
```

Up to eight commands are allowed. Ids start with a lowercase letter and contain at most 40 ASCII letters, digits, underscores or hyphens. Titles contain at most 60 characters. Plugins cannot open links automatically during state changes.

## Distribute a plugin

Share the `.wakeguardplugin` file or host it at a stable HTTPS URL. Publish its source, requested permissions and license with it. Use a new version and URL when the package changes; do not silently replace released bytes. Ask users to import or install the package and review its permissions. An update requires installation review and explicit re-enabling.

To propose a plugin for WakeGuard's catalog, open a pull request with its source and a reproducible package. Explain the permissions and how to test its behavior. Maintainers review catalog additions; adding a self-declared author name does not verify a publisher.

Changes to plugin sources, catalog packages, review policy and publishing code require approval from [@myurtsev](https://github.com/myurtsev). New reviewable commits dismiss earlier approvals. Pull requests must pass the `native` check against an up-to-date `main` before merging. Direct pushes, force pushes and deletion of `main` are blocked; no actors can bypass these rules.

Approval does not publish a plugin. The catalog updates after the approved pull request is merged into `main` and GitHub Pages deploys it. GitHub does not let authors approve their own pull requests, including changes made by an agent using the author's account.

For the repository's examples, generate packages at these paths:

```sh
python3 plugins/pack.py pack plugins/agent-status public/plugins/io.github.myurtsev.agent-status/1.0.0.wakeguardplugin
python3 plugins/pack.py pack plugins/session-notifications public/plugins/io.github.myurtsev.session-notifications/1.0.0.wakeguardplugin
python3 plugins/pack.py catalog public/plugins/catalog.json public/plugins/io.github.myurtsev.agent-status/1.0.0.wakeguardplugin public/plugins/io.github.myurtsev.session-notifications/1.0.0.wakeguardplugin
python3 plugins/pack.py verify public/plugins/catalog.json
python3 -B -m unittest discover -s plugins -p 'test_*.py'
```

The catalog uses `schemaVersion: 1` and entries with `id`, `name`, `version`, `author`, `description`, `url` and lowercase hexadecimal `sha256`. Catalog identity fields must match the package. `pack.py catalog` calculates hashes from the exact package bytes. `pack.py verify` checks the local packages, metadata and hashes. These checks do not execute or certify the JavaScript.

The existing Vite build copies `public/plugins/` unchanged into the static site. The native app bundles the same catalog and packages for offline browsing. GitHub Pages hosts the remote catalog without an application server. Running `pack.py` does not publish anything; publication follows the repository's normal review and deployment process.

## Limits and verification

Packages are limited to 128 KiB and scripts to 96 KiB. At most 32 plugins can be installed. Each invocation has a two-second execution limit and up to 16 actions whose encoded output must fit in 64 KiB. The runner also checks its memory use. A plugin may queue up to eight events and produce up to 30 non-status actions per minute; status text does not consume that rate limit.

The host validates package metadata, permissions and returned actions. A timeout, runtime error, delivery error or exceeded limit disables the plugin and reports an error. Correct the cause, then enable it again to retry. Test startup, state transitions, unknown agent state, required settings, disabled permissions and repeated events before publishing.

Use the regular [native build](../app/README.md#build-and-verification) to check the packaged examples against the actual JavaScript runner. Hardware sleep behavior, macOS notification authorization and delivery to an external service need checks on a target Mac. A successful pack or catalog checksum alone does not prove a plugin works.
