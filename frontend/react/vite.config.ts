import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import path from "node:path";

// RoonSage React microfrontend.
//
// Production: build emits `frontend/react/dist/assets/main.js` (deterministic name,
// no content-hash) plus `assets/main.css`. The FastAPI static mount serves them
// at `/static/react/...`. The vanilla SPA dynamically imports the bundle on the
// first navigation to a React-backed view; the bundle attaches a global
// `window.RoonSageReact = { mount, unmount }` for the host router.
//
// Dev: `pnpm dev` (or `npm run dev`) on :5174 with `/api` proxied to FastAPI on :5765.
// Run side-by-side with the Docker container during React development.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "src"),
    },
  },
  server: {
    port: 5174,
    strictPort: true,
    proxy: {
      "/api": {
        target: "http://localhost:5765",
        changeOrigin: true,
        ws: true,
      },
      "/ws": {
        target: "ws://localhost:5765",
        ws: true,
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: true,
    cssCodeSplit: false,
    rollupOptions: {
      input: path.resolve(__dirname, "src/main.tsx"),
      output: {
        entryFileNames: "assets/main.js",
        chunkFileNames: "assets/[name]-[hash].js",
        assetFileNames: (asset) => {
          if (asset.name?.endsWith(".css")) return "assets/main.css";
          return "assets/[name]-[hash][extname]";
        },
      },
    },
  },
});
