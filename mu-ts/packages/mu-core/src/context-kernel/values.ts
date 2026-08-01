import { ContextKernelValidationError } from '../errors.ts'
import { encodeMuJSON, sha256Hex } from '../hashing.ts'

/**
 * A provider-neutral JSON value used by the Context Kernel. It deliberately
 * excludes executable objects and preserves deterministic, sorted-key
 * encoding for checksums, conflicts, and immutable Pack receipts.
 */
export type ProjectContextValue =
  | { type: 'string'; value: string }
  | { type: 'number'; value: number }
  | { type: 'bool'; value: boolean }
  | { type: 'object'; value: Readonly<Record<string, ProjectContextValue>> }
  | { type: 'array'; value: readonly ProjectContextValue[] }
  | { type: 'null' }

export function pcvString(value: string): ProjectContextValue {
  return { type: 'string', value }
}
export function pcvNumber(value: number): ProjectContextValue {
  return { type: 'number', value }
}
export function pcvBool(value: boolean): ProjectContextValue {
  return { type: 'bool', value }
}
export function pcvObject(value: Readonly<Record<string, ProjectContextValue>>): ProjectContextValue {
  return { type: 'object', value }
}
export function pcvArray(value: readonly ProjectContextValue[]): ProjectContextValue {
  return { type: 'array', value }
}
export const PCV_NULL: ProjectContextValue = { type: 'null' }
export const pcvNull: ProjectContextValue = PCV_NULL

export const CONTEXT_CANONICALIZATION_VERSION = 'mu-json-v1'

/**
 * Converts to the plain JSON object used by the canonical writer.
 * Non-finite numbers are rejected before they can enter the Kernel.
 */
export function canonicalJSONObject(
  value: ProjectContextValue,
): unknown {
  switch (value.type) {
    case 'string':
      return value.value
    case 'number':
      if (!Number.isFinite(value.value)) {
        throw ContextKernelValidationError.nonFiniteNumber()
      }
      // Swift: value == 0 ? 0 : value (normalizes -0 to 0)
      return value.value === 0 ? 0 : value.value
    case 'bool':
      return value.value
    case 'object': {
      const out: Record<string, unknown> = {}
      for (const [key, nested] of Object.entries(value.value)) {
        out[key] = canonicalJSONObject(nested)
      }
      return out
    }
    case 'array':
      return value.value.map((nested) => canonicalJSONObject(nested))
    case 'null':
      return null
  }
}

/**
 * Versioned, sorted-key JSON used for receipts and immutable fingerprints.
 * Uses JSONSerialization-style (%.17g) number formatting, byte-identical to
 * Swift `ProjectContextValue.canonicalData()`.
 */
export function canonicalData(value: ProjectContextValue): string {
  return encodeMuJSON(canonicalJSONObject(value), { serializationNumbers: true })
}

export function contentSHA256(value: ProjectContextValue): string {
  return sha256Hex(canonicalData(value))
}

/** Swift `renderedText()`: strings render as-is; everything else as canonical JSON. */
export function renderedText(value: ProjectContextValue): string {
  if (value.type === 'string') return value.value
  return canonicalData(value)
}

/**
 * Swift `containsText(_:)`: case- and diacritic-insensitive search using
 * en_US_POSIX folding. JS approximation: NFD-decompose + lowercase.
 */
export function containsText(value: ProjectContextValue, normalizedNeedle: string): boolean {
  return foldDiacritics(renderedText(value)).includes(foldDiacritics(normalizedNeedle))
}

function foldDiacritics(s: string): string {
  // Strip combining diacritical marks (U+0300..U+036F) after NFD decomposition.
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}
