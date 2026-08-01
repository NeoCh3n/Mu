import { trimWhitespace } from '../hashing.ts'
import type { ContextImportIssue } from './import-job.ts'
import type { ProjectContextValue } from './values.ts'

/**
 * Secret and private-reasoning validation, mirroring ContextBundleSafety
 * from ContextKernel.swift.
 */
export const FORBIDDEN_FIELD_NAMES: ReadonlySet<string> = new Set([
  'hidden_chain_of_thought',
  'chain_of_thought',
  'raw_model_reasoning',
  'private_reasoning',
  'api_key',
  'apikey',
  'access_token',
  'refresh_token',
  'password',
  'credential',
  'credentials',
  'private_key',
])

const SECRET_PREFIXES = [
  'sk-',
  'ghp_',
  'github_pat_',
  'xoxb-',
  'xoxp-',
  'AKIA',
  'AIza',
] as const

/** Issues in raw JSON bundle bytes (parsed from text). */
export function contextBundleIssuesInRaw(rawText: string): ContextImportIssue[] {
  let parsed: unknown
  try {
    parsed = JSON.parse(rawText)
  } catch {
    return [{ code: 'invalid_json', message: 'The Context Bundle is not valid JSON.' }]
  }
  const issues: ContextImportIssue[] = []
  inspectValue(parsed, '$', issues)
  return issues
}

/** Issues in a parsed ProjectContextValue. */
export function contextBundleIssuesInValue(value: ProjectContextValue): ContextImportIssue[] {
  const issues: ContextImportIssue[] = []
  inspectContextValue(value, '$', issues)
  return issues
}

function inspectValue(value: unknown, path: string, issues: ContextImportIssue[]): void {
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
      const normalizedKey = trimWhitespace(key).toLowerCase()
      if (FORBIDDEN_FIELD_NAMES.has(normalizedKey)) {
        issues.push({
          code: 'forbidden_field',
          message: `Forbidden private or secret field at ${path}.${key}.`,
        })
      }
      inspectValue(nested, `${path}.${key}`, issues)
    }
  } else if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index++) {
      inspectValue(value[index], `${path}[${index}]`, issues)
    }
  } else if (typeof value === 'string' && looksLikeSecret(value)) {
    issues.push({
      code: 'secret_material',
      message: `Potential credential or private key at ${path}.`,
    })
  }
}

function inspectContextValue(value: ProjectContextValue, path: string, issues: ContextImportIssue[]): void {
  switch (value.type) {
    case 'object':
      for (const [key, nested] of Object.entries(value.value)) {
        const normalizedKey = key.toLowerCase()
        if (FORBIDDEN_FIELD_NAMES.has(normalizedKey)) {
          issues.push({
            code: 'forbidden_field',
            message: `Forbidden private or secret field at ${path}.${key}.`,
          })
        }
        inspectContextValue(nested, `${path}.${key}`, issues)
      }
      break
    case 'array':
      for (let index = 0; index < value.value.length; index++) {
        inspectContextValue(value.value[index]!, `${path}[${index}]`, issues)
      }
      break
    case 'string':
      if (looksLikeSecret(value.value)) {
        issues.push({
          code: 'secret_material',
          message: `Potential credential or private key at ${path}.`,
        })
      }
      break
    default:
      break
  }
}

function looksLikeSecret(rawValue: string): boolean {
  const value = trimWhitespace(rawValue)
  const upper = value.toUpperCase()
  if (upper.includes('-----BEGIN ') && upper.includes('PRIVATE KEY-----')) {
    return true
  }
  for (const prefix of SECRET_PREFIXES) {
    const matchIndex = value.indexOf(prefix)
    if (matchIndex === -1) continue
    if (value.length - matchIndex >= 20) return true
  }
  return false
}
