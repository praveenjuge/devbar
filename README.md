# Devbar

A native macOS menu-bar app for developers: remaining AI quota for Codex, Claude, and Muse, the dev servers running on your Mac, a Worktrees window for cleaning up git worktrees, a Caffeinate toggle, and a Camera menu for revoking apps' camera access. Icon-only in the menu bar; click for a native menu.

**[Website and docs](https://devbar.praveenjuge.com)** · **[Download](https://github.com/praveenjuge/devbar/releases/latest)**

## Features

| Feature | Docs |
|---|---|
| AI quota for Codex, Claude, and Muse | [AI quota](https://devbar.praveenjuge.com/features/ai-quota) |
| Dev servers listening on your Mac | [Dev servers](https://devbar.praveenjuge.com/features/dev-servers) |
| Worktrees window for cleaning up git worktrees | [Worktrees](https://devbar.praveenjuge.com/features/worktrees) |
| Camera menu for revoking camera access | [Camera](https://devbar.praveenjuge.com/features/camera) |
| Caffeinate toggle | [Caffeinate](https://devbar.praveenjuge.com/features/caffeinate) |
| Settings, updates, and privacy | [Settings](https://devbar.praveenjuge.com/settings) · [Updates](https://devbar.praveenjuge.com/updates) · [Privacy](https://devbar.praveenjuge.com/privacy) |

## Requirements

- Apple Silicon Mac with macOS 14+
- Existing logins: Codex CLI (`~/.codex/auth.json`), Claude Code (Keychain), Muse (`~/.config/muse/auth.json` or Keychain)

## Build & run

```sh
swift build                                    # debug build
.build/debug/Devbar --dump-usage              # headless JSON check
.build/debug/Devbar --dump-ports              # detected dev servers as JSON
.build/debug/Devbar --dump-worktrees          # git worktrees found in your home folder
.build/debug/Devbar --dump-camera             # camera permissions (needs Full Disk Access)
./build-app.sh                                 # signed release bundle -> dist/Devbar.app
open dist/Devbar.app
```

Set `CODESIGN_IDENTITY` to override the Developer ID signing identity used by `build-app.sh`. Release bundles require a valid signing identity.

## How it works

- Swift/SwiftUI + AppKit, with Sparkle for updates. `LSUIElement` accessory app.
- Reuses CLI logins read-only; tokens are never refreshed or written back.
  - Codex: `~/.codex/auth.json` → `GET chatgpt.com/backend-api/wham/usage`
  - Claude: newest valid Keychain `Claude Code-credentials` item, including the `-<hash>` items Claude Code keeps per config folder (such as the Claude desktop app's), then `~/.claude/.credentials.json` → `GET api.anthropic.com/api/oauth/usage`. Tokens are never refreshed, so Claude Code's own logins are never rotated out from under it.
  - Muse: `~/.config/muse/auth.json` or Keychain `ai.meta.dev.credentials/meta` → `POST api.meta.ai/muse-code/key` (minted key is discarded)
- Keychain is read via the `/usr/bin/security` subprocess (stable attribution, so one Always Allow sticks), blobs are cached in memory, and background refreshes never prompt.
- Refreshes every 10 minutes and whenever the menu opens. Transient failures (network, 429, 5xx) keep last-good data; durable ones (logout, expired) replace it.
- Menu rows are stock `NSMenuItem`s: section headers per provider (plan and masked sign-in email, or **Idle** when no quota is in use), quota rows with the remaining percentage and reset time as one badge. Each quota bar is a native `NSLevelIndicator` inside a resizing menu view, inset to align with the menu text; AppKit colors it (yellow under 25%, red under 10%).
- **Dev servers** come from `lsof -nP -iTCP -sTCP:LISTEN` each time the menu opens. A listener counts when its process was started from a project folder; launchd starts system services and apps in `/` or inside their bundle, so they're left out. Stop sends `SIGTERM`, Force Stop (⌥) sends `SIGKILL`.
- **Camera** reads `~/Library/Application Support/com.apple.TCC/TCC.db` read-only (needs Full Disk Access) and revokes with `tccutil reset Camera <bundle id>`. macOS has no public API to grant access. Apps seen once are remembered in `camera.knownApps` so they still show after a reset.
- **Worktrees** scan only while the window is open: walk the home folder for repositories (skipping `~/Library`, hidden folders, and build/dependency folders; Spotlight doesn't index `.git`), then `git worktree list --porcelain` per repository. Last used is the newest of the folder and git's `HEAD`, `index`, and `logs/HEAD` for it; `git status` runs with optional locks off so the scan never counts as use. A branch is merged when `git merge-tree --write-tree` against the default branch (the main checkout's branch and `origin/HEAD`) gives the default branch's own tree, which covers regular, rebase, and squash merges. Delete runs `git worktree remove --force --force`, then `git branch -D` for merged branches when `worktrees.deleteMergedBranches` is on.
- **Caffeinate** holds a `PreventUserIdleDisplaySleep` power assertion, like `caffeinate -d`.
- Preferences live in `UserDefaults`: `provider.<id>.enabled`, `devServers.enabled`, `devServers.hidden`, `keychainApproved`, `camera.knownApps`, `worktrees.sort`, `worktrees.collapsedRepositories`, `worktrees.deleteMergedBranches`.

## Releases

Every push to `main` (except changes only under `website/`) builds on Apple Silicon runners, bumps the patch version tag (`v0.1.0`, `v0.1.1`, …), and publishes `.zip`, `.dmg`, and `.pkg` artifacts. The app and DMG are signed and notarized. The PKG is signed and notarized only when a Developer ID Installer certificate is configured; otherwise it contains the notarized app but is unsigned and does not pass Gatekeeper's installer assessment. The tag is created only after successful packaging.

CI needs these repository secrets (`gh secret set NAME --repo praveenjuge/devbar`):

| Secret | Value |
|---|---|
| `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64` | Base64 of the Developer ID Application `.p12` (Keychain Access → My Certificates → right-click → Export) |
| `APPLE_DEVELOPER_CERTIFICATE_PASSWORD` | Password set when exporting the `.p12` |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password from appleid.apple.com |
| `APPLE_INSTALLER_CERTIFICATE_P12_BASE64` | (Optional) Base64 of a Developer ID Installer `.p12` — without it the PKG ships unsigned |
| `APPLE_INSTALLER_CERTIFICATE_PASSWORD` | (Optional) Its export password — defaults to the app cert password |
| `SPARKLE_PRIVATE_KEY` | Sparkle update signing key (see [Automatic updates](#automatic-updates)) |

```sh
base64 -i /path/to/dev-id-app.p12 | gh secret set APPLE_DEVELOPER_CERTIFICATE_P12_BASE64
gh secret set APPLE_DEVELOPER_CERTIFICATE_PASSWORD   # paste .p12 password
gh secret set APPLE_ID                               # paste Apple ID email
gh secret set APPLE_APP_SPECIFIC_PASSWORD            # paste app-specific password
```

## Automatic updates

Release `.app` bundles use Sparkle 2.10.0. They check at startup and every six
hours and download verified updates in the background. Check for updates is in
Settings; once an update is ready, the menu shows **Restart and update** below
Settings. Choose it, or quit normally to install for the next
launch. Debug builds and `--dump-usage` do not start the updater. No credentials or
system profile are sent to the update feed.

Only the stable GitHub release marked **Latest** is offered. Each release includes
a signed `appcast.xml` and a signed, notarized ARM64 ZIP; equal or older versions
are ignored. Existing installations without Sparkle need one manual upgrade.

`bash build-app.sh 0.1.3` sets both bundle version fields. Omit the argument to use
the nearest release tag. Builds require the Developer ID signing identity and a
fresh output path; set `APP_OUTPUT` to retain an existing bundle. Local and CI
bundles use the same assembler, including Sparkle framework/helper signing.

The update key is stored in the login Keychain under the `ai-quota` account.
CI also requires `SPARKLE_PRIVATE_KEY`. Its public key is in `Resources/Info.plist`.
Never commit or log the private key. To restore CI access from this Mac:

```sh
security find-generic-password -a ai-quota -s https://sparkle-project.org -w \
  | gh secret set SPARKLE_PRIVATE_KEY --repo praveenjuge/devbar
```

CI generates and signs the feed after notarization, uploads all four assets to a
draft release, verifies the asset list, then publishes it as Latest. The app
requires a signed feed and verifies archive signatures before extraction.

### Verify updates locally

```sh
APP_OUTPUT=dist/e2e-source/Devbar.app bash build-app.sh 0.1.3
python3 scripts/verify-updates.py dist/e2e-source/Devbar.app
```

This requires Interceptor with Accessibility permission and the Keychain update
key. It prepares signed app copies with unique test identities, uses a localhost
signed feed, and checks clicked restart, normal Quit, preference preservation,
and rejection of invalid feeds/archives. Results are saved in
`dist/verification/update-e2e.json`; each result links retained menu trees and
app logs. Production apps and preferences are untouched.

Refresh is a stock menu item, so clicking it closes the menu like any system
menu. Reopen it to see **Refreshing…**. Check for updates shows its result in Settings.

To verify menu tracking with the canonical menu implementation:

```sh
bash scripts/verify-menu-feedback.sh dist/e2e-source/Devbar.app
```

The signed test host opens the menu, asserts it stays open while the refresh
rebuilds it, then checks for updates and asserts an up-to-date result leaves the
menu unchanged. Results are retained.

## Website

[devbar.praveenjuge.com](https://devbar.praveenjuge.com) is a [Blume](https://useblume.dev) docs site in `website/`, served as a static-assets Cloudflare Worker (`devbar`). Pages are MDX in `website/docs/`; screenshots live in `website/public/screenshots/`.

```sh
cd website
bun install
bun run dev      # local preview
bun run deploy   # blume build && cf deploy (manual deploy)
```

Cloudflare Workers Builds deploys it on every push to `main` that touches `website/`: root directory `/website`, build command `bun run build`, deploy command `bunx cf deploy`, and the `BUN_VERSION` build variable set to match `bun.lock`. `cloudflare.config.ts` sets the Worker name and custom domain; `wrangler.config.ts` points `cf` at Blume's `dist/`.
