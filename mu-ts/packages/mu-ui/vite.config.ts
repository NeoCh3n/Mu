import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Dev server proxies API + SSE to the local Mu server (default port 4000).
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: {
      '/api': 'http://127.0.0.1:4000',
      '/health': 'http://127.0.0.1:4000',
      '/projects': 'http://127.0.0.1:4000',
      '/agents': 'http://127.0.0.1:4000',
      '/endpoints': 'http://127.0.0.1:4000',
      '/tasks': 'http://127.0.0.1:4000',
      '/context': 'http://127.0.0.1:4000',
      '/approvals': 'http://127.0.0.1:4000',
      '/handoffs': 'http://127.0.0.1:4000',
      '/ledger': 'http://127.0.0.1:4000',
      '/spaces': 'http://127.0.0.1:4000',
    },
  },
  test: {
    environment: 'jsdom',
    include: ['test/**/*.test.{ts,tsx}'],
  },
})
