# Agent notes

Devbar is a Swift/AppKit menu-bar app (`Sources/Devbar/`). Its website and docs live in `website/` and are published to https://devbar.praveenjuge.com. See `README.md` for building, releases, and the website deploy.

## Keep the docs in step with the app

When a change adds, removes, or changes something a user can see or do (a menu item, window, setting, shortcut, permission, label, or behavior), update the docs in the same change:

- **Website docs** in `website/docs/`: the feature's page in `features/`, plus `(start)/install.mdx`, `(reference)/settings.mdx`, `(reference)/updates.mdx`, or `(reference)/privacy.mdx` when they're affected. A new feature gets its own page in `website/docs/features/` (add it to `features/meta.ts`) and a card on the home page, `website/docs/index.mdx`. If it has its own window, add a tab for it in the home page's screenshot `<Tabs>`.
- **README.md**: the Features table and the "How it works" notes for implementation details (commands, file paths, `UserDefaults` keys).
- **Labels**: copy UI text into the docs exactly as the app shows it (for example **Check for updates…**), and check it against the source.
- **Privacy**: if Devbar reads a new file, Keychain item, or permission, or sends a new network request, update `(reference)/privacy.mdx`.

Write docs plainly and briefly, for someone using the app rather than reading the code. Prefer Blume's built-in components (`Card`, `Steps`, `Tabs`, `Accordion`, `Frame`, `Callout`, `Badge`) over custom HTML; see https://useblume.dev/docs/content/components.

## Screenshots

Screenshots live in `website/public/screenshots/` as light and dark pairs (`menu-light.png` / `menu-dark.png`, `worktrees-…`, `settings-…`). Update them when the UI they show changes, and add a pair when a new feature has its own window or menu.

- Use sample data only: `example.com` emails and demo projects like `acme-web`. Never capture real accounts, repositories, ports, or apps from this Mac.
- Capture the real app UI, not mockups: a throwaway harness that runs the real `StatusMenu` and windows with injected sample data, the same way `scripts/MenuFeedbackE2E.swift` hosts the menu. Don't commit the harness or change app code for it.
- Save 2x PNGs with a transparent background and the native window shadow, and keep each under about 400 KB.
- In MDX, show both images in a `<Frame>` with `className="dark:hidden"` on the light one and `className="hidden dark:block"` on the dark one. Set `width` to half the pixel width.

## Check the site

```sh
cd website
bun install
bun run build   # must finish with no warnings
```

Pushing to `main` deploys the site through Cloudflare Workers Builds when `website/` changes. Pushes that only touch `website/` don't cut an app release.
