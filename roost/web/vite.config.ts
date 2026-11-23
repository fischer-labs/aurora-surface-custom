import { defineConfig } from 'vitest/config';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';

// Relative base: the server injects <base href="/your/unlisted/path/"> into
// index.html, so one build works at any path (docs/DEPLOY.md).
export default defineConfig({
  base: './',
  plugins: [react()],
  resolve: { alias: { '@shared': fileURLToPath(new URL('../shared', import.meta.url)) } },
  server: {
    fs: { allow: ['..'] },
    proxy: { '/api': { target: process.env.ROOST_API ?? 'http://127.0.0.1:8090', changeOrigin: true } },
  },
  build: { target: 'es2022', sourcemap: false, chunkSizeWarningLimit: 900 },
  test: { include: ['tests/**/*.test.ts'] },
});
