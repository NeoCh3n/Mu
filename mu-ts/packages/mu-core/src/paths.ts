import { realpathSync } from 'node:fs'
import path from 'node:path'

/**
 * Canonical path mirroring Swift's
 * `URL(fileURLWithPath:).standardizedFileURL.resolvingSymlinksInPath().path`.
 *
 * Standardizes the path and resolves symlinks for the deepest existing
 * ancestor, tolerating a non-existent tail (like `resolvingSymlinksInPath`).
 */
export function canonicalPath(input: string): string {
  const resolved = path.resolve(input)
  try {
    return realpathSync(resolved)
  } catch {
    // Walk up to the deepest existing ancestor, resolve its symlinks,
    // and re-append the non-existent remainder.
    const segments = resolved.split(path.sep).filter((s) => s !== '')
    for (let i = segments.length; i > 0; i--) {
      const candidate = path.join(path.sep, ...segments.slice(0, i))
      try {
        const real = realpathSync(candidate)
        const remainder = segments.slice(i).join(path.sep)
        return remainder === '' ? real : path.join(real, remainder)
      } catch {
        // keep walking up
      }
    }
    return resolved
  }
}
