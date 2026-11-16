import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Le front ne connaît que /api : le backend Python parle à AWS (ou à l'émulateur).
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { "/api": "http://127.0.0.1:8000" } },
});
