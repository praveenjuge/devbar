import { defineConfig } from "blume";

export default defineConfig({
  title: "Devbar",
  description:
    "A native macOS menu-bar app for developers: AI quota for Codex, Claude, and Muse, your running dev servers, git worktree cleanup, and more.",
  logo: { image: "/logo.svg", text: "Devbar" },
  theme: {
    accent: { light: "#1d4fd8", dark: "#6aa8ff" },
    radius: "lg",
    backgroundImage: { light: "/bg-light.svg", dark: "/bg-dark.svg" },
    fonts: { body: "inter", mono: "jetbrains-mono" },
  },
  navigation: {
    cta: { href: "https://github.com/praveenjuge/devbar/releases/latest", label: "Download" },
  },
  github: { owner: "praveenjuge", repo: "devbar", dir: "website" },
  footer: {
    copyright: `© ${new Date().getFullYear()} Praveen Juge`,
    links: [
      { label: "Download", href: "https://github.com/praveenjuge/devbar/releases/latest" },
      { label: "Releases", href: "https://github.com/praveenjuge/devbar/releases" },
    ],
    socials: { website: "https://praveenjuge.com" },
  },
  deployment: { site: "https://devbar.praveenjuge.com" },
});
