import { createHash } from 'node:crypto'
import type { RuntimeEndpoint } from '../models.ts'
import { canonicalPath } from '../paths.ts'
import {
  AgentRuntimeIdentityBasis,
  AgentRuntimeSurfaceKind,
  codexRuntimeTypeID,
  claudeCodeRuntimeTypeID,
  openWorkerRuntimeTypeID,
  provider,
  providerDisplayName,
  RuntimeIdentityConfigurationKey,
  type AgentRuntimeInstanceIdentity,
  type ConversationProvider,
} from '../types.ts'
import { trimWhitespace } from '../hashing.ts'

/**
 * Byte-identical to Swift `AgentRuntimeInstanceIdentity.resolving(endpoint:)`.
 * Explicit identity metadata wins; without a terminal identifier, two CLI
 * endpoints remain distinct by their persistent endpoint UUID.
 */
export function resolveEndpointInstanceIdentity(
  endpoint: RuntimeEndpoint,
): AgentRuntimeInstanceIdentity {
  const configuration = endpoint.nativeConfiguration ?? {}
  const providerValue = configuredProvider(configuration[RuntimeIdentityConfigurationKey.provider])
    ?? inferredProvider(endpoint.runtimeTypeID)
  const executablePath = canonicalExecutablePath(configuration['executable'])
  const terminalIdentifier = nonempty(
    configuration[RuntimeIdentityConfigurationKey.terminalIdentifier]
    ?? configuration['terminal_id']
    ?? configuration['tty'],
  )
  const explicitSurfaceRaw = configuration[RuntimeIdentityConfigurationKey.surfaceKind]
  const explicitSurface = explicitSurfaceRaw !== undefined
    ? (Object.values(AgentRuntimeSurfaceKind).includes(explicitSurfaceRaw as AgentRuntimeSurfaceKind)
        ? explicitSurfaceRaw as AgentRuntimeSurfaceKind
        : undefined)
    : undefined
  const surfaceKind = explicitSurface ?? inferredSurface(
    providerValue,
    executablePath,
    configuration['application_path'],
    endpoint.location,
    endpoint.provenance,
  )

  let basis: AgentRuntimeIdentityBasis
  let stableInstanceKey: string
  if (surfaceKind === 'desktop_application' && providerValue.rawValue === 'codex') {
    basis = 'desktop_singleton'
    stableInstanceKey = 'codex:desktop'
  } else if (terminalIdentifier !== undefined) {
    basis = 'terminal_identifier'
    stableInstanceKey = stableKey(providerValue, 'terminal', [terminalIdentifier])
  } else {
    basis = 'endpoint_fallback'
    stableInstanceKey = stableKey(providerValue, surfaceKind, [endpoint.id])
  }

  const explicitLabel = nonempty(configuration[RuntimeIdentityConfigurationKey.instanceLabel])
  const label = explicitLabel ?? defaultLabel(
    providerValue,
    surfaceKind,
    basis,
    terminalIdentifier,
    undefined,
    endpoint.id.slice(0, 8),
  )

  const workspacePathValue = nonempty(configuration[RuntimeIdentityConfigurationKey.workspacePath])
  return {
    provider: providerValue,
    surfaceKind,
    identityBasis: basis,
    stableInstanceKey,
    instanceLabel: label,
    terminalIdentifier,
    executablePath,
    workspacePath: workspacePathValue === undefined ? undefined : canonicalPath(workspacePathValue),
    nativeSource: nonempty(configuration[RuntimeIdentityConfigurationKey.nativeSource]),
  }
}

export function resolvedInstanceIdentity(endpoint: RuntimeEndpoint): AgentRuntimeInstanceIdentity {
  return endpoint.instanceIdentity ?? resolveEndpointInstanceIdentity(endpoint)
}

// ---------------------------------------------------------------------------
// Helpers (mirror the Swift private statics)
// ---------------------------------------------------------------------------

function configuredProvider(rawValue: string | undefined): ConversationProvider | undefined {
  return nonempty(rawValue) === undefined ? undefined : provider(nonempty(rawValue)!)
}

function inferredProvider(runtimeTypeID: string): ConversationProvider {
  const normalized = runtimeTypeID.toLowerCase()
  if (normalized.includes('codex')) return provider('codex')
  if (normalized.includes('claude')) return provider('claude_code')
  if (normalized.includes('openworker')) return provider('openworker')
  const vendor = normalized.split('/')[0] ?? normalized
  return provider(vendor)
}

function inferredSurface(
  providerValue: ConversationProvider,
  executablePath: string | undefined,
  applicationPath: string | undefined,
  location: RuntimeEndpoint['location'],
  provenance: RuntimeEndpoint['provenance'],
): AgentRuntimeSurfaceKind {
  if (nonempty(applicationPath) !== undefined || executableIsInsideApplication(executablePath)) {
    return 'desktop_application'
  }
  if (location === 'remote' || location === 'hosted') return 'remote_service'
  if (provenance === 'artifact_only') return 'history_artifact'
  if (
    provenance === 'vendor_cli'
    || providerValue.rawValue === 'claude_code'
    || (providerValue.rawValue === 'codex' && executablePath !== undefined)
  ) {
    return 'terminal_cli'
  }
  if (location === 'local' && provenance === 'vendor_protocol') return 'local_service'
  return 'unknown'
}

function defaultLabel(
  providerValue: ConversationProvider,
  surfaceKind: AgentRuntimeSurfaceKind,
  basis: AgentRuntimeIdentityBasis,
  terminalIdentifier: string | undefined,
  nativeSessionID: string | undefined,
  fallbackToken: string,
): string {
  const product = providerDisplayName(providerValue)
  switch (surfaceKind) {
    case 'desktop_application':
      return `${product} Desktop`
    case 'terminal_cli':
      if (terminalIdentifier !== undefined) return `${product} CLI · ${terminalIdentifier}`
      if (nativeSessionID !== undefined) {
        return `${product} CLI · session ${shortToken(nativeSessionID)} (terminal not recorded)`
      }
      return `${product} CLI · Mu instance ${fallbackToken} (terminal not recorded)`
    case 'editor_extension':
      return `${product} VS Code · session ${shortToken(nativeSessionID ?? fallbackToken)}`
    case 'automation':
      return `${product} exec · session ${shortToken(nativeSessionID ?? fallbackToken)}`
    case 'local_service':
      if (nativeSessionID !== undefined) {
        return `${product} App Server · session ${shortToken(nativeSessionID)}`
      }
      return `${product} App Server · instance ${fallbackToken}`
    case 'remote_service':
      return `${product} Remote`
    case 'history_artifact':
      return `${product} history · session ${shortToken(nativeSessionID ?? fallbackToken)}`
    case 'unknown':
      return basis === 'installation'
        ? `${product} installation`
        : `${product} · instance ${fallbackToken}`
  }
}

function stableKey(providerValue: ConversationProvider, scope: string, components: readonly string[]): string {
  const material = components.join('\u{1F}')
  const hash = createHash('sha256').update(material, 'utf8').digest('hex').slice(0, 20)
  return `${providerValue.rawValue}:${scope}:${hash}`
}

function shortToken(value: string): string {
  const trimmed = trimWhitespace(value)
  if (trimmed === '') return 'unknown'
  const safe = [...trimmed].every((c) => /[A-Za-z0-9_-]/.test(c))
  return safe
    ? trimmed.slice(0, 12)
    : createHash('sha256').update(trimmed, 'utf8').digest('hex').slice(0, 12)
}

function canonicalExecutablePath(rawValue: string | undefined): string | undefined {
  const value = nonempty(rawValue)
  return value === undefined ? undefined : canonicalPath(value)
}

function executableIsInsideApplication(path: string | undefined): boolean {
  const value = nonempty(path)
  if (value === undefined) return false
  return value.toLowerCase().includes('.app/contents/')
}

function nonempty(value: string | undefined): string | undefined {
  const trimmed = value === undefined ? undefined : trimWhitespace(value)
  return trimmed === undefined || trimmed === '' ? undefined : trimmed
}

/** Well-known runtime type IDs (re-exported for convenience). */
export const RUNTIME_TYPE_IDS = {
  codex: codexRuntimeTypeID,
  claudeCode: claudeCodeRuntimeTypeID,
  openWorker: openWorkerRuntimeTypeID,
} as const
