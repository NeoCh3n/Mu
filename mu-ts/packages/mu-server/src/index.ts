// mu-server: local HTTP server + API (Phase 6).
export * from './wiring.ts'
export * from './sse/events.ts'

import { buildApp } from './wiring.ts'

export interface ServerOptions {
  readonly dataDirectory: string
  readonly port?: number
  readonly host?: string
}

/** CLI entry: builds the app and listens. */
export async function startServer(options: ServerOptions): Promise<void> {
  const mu = buildApp({ dataDirectory: options.dataDirectory, filename: 'mu.sqlite' })
  await mu.app.listen({ port: options.port ?? 4000, host: options.host ?? '127.0.0.1' })
}

// Direct invocation: `node src/index.ts`.
const isMain = process.argv[1] !== undefined && process.argv[1].endsWith('index.ts')
if (isMain) {
  const home = process.env['HOME'] ?? '.'
  const dataDirectory = process.env['MU_DATA_DIRECTORY'] ?? `${home}/Library/Application Support/Mu`
  const port = Number(process.env['MU_PORT'] ?? 4000)
  void startServer({ dataDirectory, port })
    .then(() => console.log(`Mu server listening on http://127.0.0.1:${port}`))
    .catch((error) => {
      console.error('Failed to start Mu server:', error)
      process.exitCode = 1
    })
}
