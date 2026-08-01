import { createHash } from 'node:crypto'

/** Opaque brand for type-safe UUID strings. Always lowercase canonical form. */
declare const Brand: unique symbol
export type UUID = string & { [Brand]: 'UUID' }

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/**
 * Returns a lowercase UUID string, validating format when an input is given.
 * Mirrors Swift `UUID()` / `UUID(uuidString:)` usage in MuCore.
 */
export function uuid(input?: string): UUID {
  const value = input?.trim().toLowerCase() ?? randomUUID()
  if (!UUID_RE.test(value)) {
    throw new TypeError(`Invalid UUID: ${input}`)
  }
  return value as UUID
}

export function isUUID(value: string): value is UUID {
  return UUID_RE.test(value.toLowerCase())
}

function randomUUID(): string {
  return crypto.randomUUID().toLowerCase()
}

/**
 * Deterministic UUID v5-style derivation, byte-identical to
 * `MuStableIdentity.uuid(namespace:components:)`:
 *
 *   material = (namespace + components).joined("\u{1F}")
 *   hex = sha256(material).hex.prefix(32)
 *   hex[12] = '5';  hex[16] = (hex[16] & 0x3) | 0x8
 *   format 8-4-4-4-12
 */
export function stableId(namespace: string, components: readonly string[]): UUID {
  const material = [namespace, ...components].join('\u{1F}')
  const hex = createHash('sha256').update(material, 'utf8').digest('hex').slice(0, 32)
  const chars = hex.split('')
  chars[12] = '5'
  const variant = parseInt(chars[16]!, 16) & 0x3 | 0x8
  chars[16] = variant.toString(16)
  const value = [
    chars.slice(0, 8).join(''),
    chars.slice(8, 12).join(''),
    chars.slice(12, 16).join(''),
    chars.slice(16, 20).join(''),
    chars.slice(20, 32).join(''),
  ].join('-')
  return value as UUID
}

