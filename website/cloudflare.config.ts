import { defineConfig } from "cf/config";

// Static assets only: Blume builds the site to dist/ (see wrangler.config.ts).
export default defineConfig({
  worker: {
    name: "devbar",
    compatibilityDate: "2026-10-06",
    observability: { enabled: true },
    assets: {
      // Blume writes <route>/index.html and links without a trailing slash.
      htmlHandling: "drop-trailing-slash",
      notFoundHandling: "404-page",
    },
    domains: ["devbar.praveenjuge.com"],
  },
});
