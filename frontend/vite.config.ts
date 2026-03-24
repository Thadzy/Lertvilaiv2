/// <reference types="vitest" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react-swc'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    tailwindcss()
  ],
  server: {
    proxy: {
      '/api/vrp': {
        target: 'http://127.0.0.1:7779',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api\/vrp/, ''),
      },
      // Fallback for C++ server if needed
      '/api/cpp-vrp': {
        target: 'http://127.0.0.1:18080',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/api\/cpp-vrp/, ''),
      },
      '/api/fleet': {
        target: 'http://127.0.0.1:8080',
        changeOrigin: true,
        ws: true,
        rewrite: (path) => path.replace(/^\/api\/fleet/, ''),
      },
    }
  },
  // @ts-expect-error - vitest types are not automatically detected in some environments
  test: {
    environment: 'jsdom',
    globals: true,
  },
})