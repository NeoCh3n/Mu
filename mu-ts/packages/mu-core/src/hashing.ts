import { createHash } from 'node:crypto'

/** SHA-256 hex digest, byte-identical to Swift's `Data.muSHA256`. */
export function sha256Hex(data: string | Uint8Array): string {
  return createHash('sha256').update(data).digest('hex')
}

/** Thrown when a value cannot be canonically encoded. Mirrors Swift errors. */
export class CanonicalEncodingError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'CanonicalEncodingError'
  }
}

// ---------------------------------------------------------------------------
// Number formatting. Swift uses TWO different writers:
//   - JSONEncoder (fingerprints, MuCoding)   -> shortest round-trip ("0.1", "1e-07")
//   - JSONSerialization (canonicalData)      -> %.17g full precision   ("0.10000000000000001", "9.9999999999999995e-08")
// Both are verified against generated Swift vectors.
// ---------------------------------------------------------------------------

/**
 * JSONEncoder-style number formatting: shortest round-trip representation.
 * JS `String(n)` already produces shortest round-trip; the only difference
 * is Swift pads exponents to >= 2 digits ("1e-07") and writes -0 as "-0".
 */
export function formatEncoderNumber(n: number): string {
  if (!Number.isFinite(n)) {
    throw new CanonicalEncodingError('Cannot encode NaN or infinity.')
  }
  if (Object.is(n, -0)) return '-0'
  let s = String(n)
  const m = /^(-?\d(?:\.\d+)?)[eE]([+-]\d+)$/.exec(s)
  if (m) {
    const exp = m[2]!
    const sign = exp[0]!
    const digits = exp.slice(1).padStart(2, '0')
    s = `${m[1]}e${sign}${digits}`
  }
  return s
}

/**
 * JSONSerialization-style number formatting: %.17g semantics.
 *   - 17 significant digits (JS toPrecision(17) rounds to the exact binary value)
 *   - trailing zeros stripped
 *   - exponent form when decimal exponent < -4 or >= 17
 *   - exponent printed with sign and >= 2 digits ("e-08", "e+21")
 *
 * The decimal exponent is derived from the toPrecision(17) string, never from
 * floating-point log10, to avoid off-by-one at precision boundaries.
 */
export function formatSerializationNumber(n: number): string {
  if (!Number.isFinite(n)) {
    throw new CanonicalEncodingError('Cannot encode NaN or infinity.')
  }
  if (Object.is(n, -0)) return '-0'
  if (n === 0) return '0'

  const s17 = n.toPrecision(17)

  // Decimal exponent E, derived from the string (never Math.log10):
  //   E = dotIndex - firstSignificantIndex - (firstSignificant < dot ? 1 : 0)
  // e.g. "123456789.12345679" -> 9 - 0 - 1 = 8;  "0.1…" -> 1 - 2 = -1.
  let digits: string
  let exponent: number
  const expMatch = /^([+-]?\d(?:\.\d+)?)[eE]([+-]\d+)$/.exec(s17)
  if (expMatch) {
    exponent = Number.parseInt(expMatch[2]!, 10)
    digits = expMatch[1]!.replace('.', '')
  } else {
    const dot = s17.indexOf('.')
    if (dot === -1) {
      digits = s17
      exponent = s17.length - 1
    } else {
      digits = s17.replace('.', '')
      const firstSig = s17.search(/[1-9]/)
      exponent = dot - firstSig - (firstSig < dot ? 1 : 0)
    }
  }

  const significant = digits.replace(/^0+/, '')
  const mantissaDigits = significant.replace(/0+$/, '')

  if (exponent < -4 || exponent >= 17) {
    const mantissa =
      mantissaDigits.length === 1
        ? mantissaDigits
        : `${mantissaDigits[0]}.${mantissaDigits.slice(1)}`
    const expStr = `${exponent < 0 ? '-' : '+'}${String(Math.abs(exponent)).padStart(2, '0')}`
    return `${mantissa}e${expStr}`
  }

  // Fixed form: point placed after (exponent + 1) significant digits.
  const whole = (significant.slice(0, exponent + 1) || '0').padStart(1, '0')
  const fraction = significant.slice(exponent + 1).replace(/0+$/, '')
  return fraction === '' ? whole : `${whole}.${fraction}`
}

// ---------------------------------------------------------------------------
// Date formatting: Swift ISO8601DateFormatter (.withInternetDateTime) with
// the GMT default timezone and no fractional seconds: "2026-08-01T03:36:47Z".
// ---------------------------------------------------------------------------

const ISO8601_DATE_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.\d+Z$/

/**
 * Formats a Date the way Swift JSONEncoder `.iso8601` does:
 * UTC, whole seconds, "Z" suffix. Inputs with milliseconds are truncated,
 * matching the Swift formatter (verified by generated vectors).
 */
export function formatIso8601Date(date: Date): string {
  const iso = date.toISOString()
  const m = ISO8601_DATE_RE.exec(iso)
  if (m) {
    return `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z`
  }
  return iso
}

// ---------------------------------------------------------------------------
// Canonical JSON writer, byte-identical to Swift's
// JSONEncoder with [.sortedKeys, .withoutEscapingSlashes] + .iso8601 dates.
//   - object keys sorted recursively (ASCII keys: identical order to Swift)
//   - undefined / nil values omitted (Swift encodeIfPresent)
//   - numbers via formatEncoderNumber (JSONEncoder path) or
//     formatSerializationNumber (JSONSerialization path)
//   - slashes not escaped; control chars escaped like JSON.stringify
// ---------------------------------------------------------------------------

export interface MuJSONEncodeOptions {
  /** Use JSONSerialization %.17g number formatting (canonicalData path). */
  serializationNumbers?: boolean
}

function escapeString(s: string): string {
  return JSON.stringify(s)
}

export function encodeMuJSON(value: unknown, options: MuJSONEncodeOptions = {}): string {
  const formatNumber = options.serializationNumbers
    ? formatSerializationNumber
    : formatEncoderNumber
  const out: string[] = []
  writeValue(value, formatNumber, out)
  return out.join('')
}

type NumberWriter = (n: number) => string

function writeValue(value: unknown, fmt: NumberWriter, out: string[]): void {
  if (value === null) {
    out.push('null')
  } else if (value === undefined) {
    out.push('null')
  } else if (typeof value === 'boolean') {
    out.push(value ? 'true' : 'false')
  } else if (typeof value === 'number') {
    out.push(fmt(value))
  } else if (typeof value === 'bigint') {
    out.push(value.toString())
  } else if (typeof value === 'string') {
    out.push(escapeString(value))
  } else if (value instanceof Date) {
    out.push(escapeString(formatIso8601Date(value)))
  } else if (Array.isArray(value)) {
    out.push('[')
    for (let i = 0; i < value.length; i++) {
      if (i > 0) out.push(',')
      writeValue(value[i], fmt, out)
    }
    out.push(']')
  } else if (typeof value === 'object') {
    out.push('{')
    const keys = Object.keys(value as Record<string, unknown>).sort()
    let first = true
    for (const key of keys) {
      const nested = (value as Record<string, unknown>)[key]
      if (nested === undefined) continue
      if (!first) out.push(',')
      first = false
      out.push(escapeString(key), ':')
      writeValue(nested, fmt, out)
    }
    out.push('}')
  } else {
    throw new CanonicalEncodingError(`Unsupported value: ${String(value)}`)
  }
}

/** Swift-style `String.trimmingCharacters(in: .whitespacesAndNewlines)`. */
export function trimWhitespace(value: string): string {
  return value.replace(/^[\s\u{2028}\u{2029}]+|[\s\u{2028}\u{2029}]+$/gu, '')
}

/** Swift-style `.lowercased()` with empty->undefined normalization (nilIfEmpty). */
export function trimmedLowercasedOrUndefined(value: string | undefined): string | undefined {
  const trimmed = value === undefined ? undefined : trimWhitespace(value)
  return trimmed === undefined || trimmed === '' ? undefined : trimmed.toLowerCase()
}

/** Swift-style `.nilIfEmpty`. */
export function nilIfEmpty(value: string | undefined): string | undefined {
  return value === undefined || trimWhitespace(value) === '' ? undefined : value
}
