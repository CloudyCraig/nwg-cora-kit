import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Single-page app served by nginx in production. Runtime config (Splunk RUM
// realm/token, gateway URL) is injected via /config.js, generated from a
// ConfigMap by the chart, so the same image works in every environment.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    sourcemap: true,
    target: "es2022",
  },
  server: {
    port: 5173,
  },
});
