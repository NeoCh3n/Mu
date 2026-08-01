import { spawnSync } from 'node:child_process'
import { MuError } from '../errors.ts'

export interface ProcessCapture {
  standardOutput: Buffer
  standardError: Buffer
  terminationStatus: number
}

/** Synchronous process runner mirroring Swift ProcessCapture usage. */
export function runProcess(params: {
  executableURL: string
  arguments: readonly string[]
}): ProcessCapture {
  const result = spawnSync(params.executableURL, [...params.arguments], {
    encoding: 'buffer',
    maxBuffer: 64 * 1024 * 1024,
  })
  if (result.error !== undefined) {
    throw MuError.commandFailed(result.error.message)
  }
  return {
    standardOutput: result.stdout ?? Buffer.alloc(0),
    standardError: result.stderr ?? Buffer.alloc(0),
    terminationStatus: result.status ?? -1,
  }
}

/** Runs git with `-C <path>`, throwing MuError.commandFailed on failure. */
export function runGitData(args: readonly string[], path: string): Buffer {
  let capture: ProcessCapture
  try {
    capture = runProcess({
      executableURL: '/usr/bin/git',
      arguments: ['-C', path, ...args],
    })
  } catch (error) {
    if (error instanceof MuError) throw error
    throw MuError.commandFailed((error as Error).message)
  }
  if (capture.terminationStatus !== 0) {
    const message = capture.standardError.toString('utf8')
      .replace(/^\s+|\s+$/g, '')
    throw MuError.commandFailed(
      message === '' ? `git exited with ${capture.terminationStatus}` : message,
    )
  }
  return capture.standardOutput
}
