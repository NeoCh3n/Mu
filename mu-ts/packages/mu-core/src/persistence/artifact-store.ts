import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { MuError } from '../errors.ts'

/**
 * Content-addressed artifact storage. Byte-identical layout to the Swift
 * ArtifactStore: `<dataDirectory>/cas/sha256/<sha256>`.
 */
export class ArtifactStore {
  private readonly rootURL: string

  constructor(options: { dataDirectory: string }) {
    this.rootURL = path.join(options.dataDirectory, 'cas')
  }

  /** Writes data keyed by SHA-256; returns the CAS URI and digest. */
  put(data: Buffer): { uri: string; sha256: string } {
    const sha256 = createHash('sha256').update(data).digest('hex')
    const filePath = path.join(this.rootURL, 'sha256', sha256)
    fs.mkdirSync(path.dirname(filePath), { recursive: true })
    try {
      const existing = fs.readFileSync(filePath)
      const existingHash = createHash('sha256').update(existing).digest('hex')
      if (existingHash !== sha256) {
        throw MuError.artifactWriteFailed('Existing CAS object hash mismatch')
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
        fs.writeFileSync(filePath, data, { mode: 0o444 })
      } else {
        throw error
      }
    }
    return { uri: `local-cas://sha256/${sha256}`, sha256 }
  }

  /** Reads CAS content by URI; returns undefined when missing. */
  get(uri: string): Buffer | undefined {
    if (!uri.startsWith('local-cas://')) return undefined
    const hash = uri.slice('local-cas://sha256/'.length)
    if (!/^[0-9a-f]{64}$/.test(hash)) return undefined
    try {
      return fs.readFileSync(path.join(this.rootURL, 'sha256', hash))
    } catch {
      return undefined
    }
  }

  /** Verifies content integrity against an expected digest. */
  verify(uri: string, expectedSHA256: string): boolean {
    const data = this.get(uri)
    if (data === undefined) return false
    return createHash('sha256').update(data).digest('hex') === expectedSHA256
  }

  /** Absolute file path for a CAS URI (may not exist). */
  pathFor(uri: string): string | undefined {
    if (!uri.startsWith('local-cas://sha256/')) return undefined
    const hash = uri.slice('local-cas://sha256/'.length)
    if (!/^[0-9a-f]{64}$/.test(hash)) return undefined
    return path.join(this.rootURL, 'sha256', hash)
  }
}
