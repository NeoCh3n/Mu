// Typed client for the Mu HTTP API. Same-origin fetch; the Vite dev server
// proxies route prefixes to the Mu server.

export interface Project {
  readonly id: string
  readonly displayName: string
  readonly repositoryPath?: string
  readonly status: string
  readonly createdAt: string
  readonly updatedAt?: string
}

export interface Agent {
  readonly id: string
  readonly displayName: string
  readonly shortName: string
  readonly role: string
  readonly summary: string
  readonly accentHex: string
  readonly availability: string
  readonly preferredEndpointID?: string
  readonly capabilityTags?: readonly string[]
  readonly createdAt?: string
}

export interface EndpointInstanceIdentity {
  readonly provider?: { readonly rawValue: string }
  readonly surfaceKind?: string
  readonly identityBasis?: string
  readonly stableInstanceKey?: string
  readonly instanceLabel?: string
  readonly executablePath?: string
  readonly terminalIdentifier?: string
}

export interface Endpoint {
  readonly id: string
  readonly runtimeTypeID: string
  readonly displayName: string
  readonly runtimeVersion: string
  readonly location: string
  readonly status: string
  readonly lastProbedAt: string
  readonly adapterVersion?: string
  readonly provenance?: string
  readonly permissionModel?: string
  readonly capabilities?: readonly string[]
  readonly guaranteeNote?: string
  readonly nativeConfiguration?: Readonly<Record<string, string>>
  readonly instanceIdentity?: EndpointInstanceIdentity
}

export interface Task {
  readonly id: string
  readonly projectID?: string
  readonly workspaceID?: string
  readonly title: string
  readonly objective: string
  readonly repositoryPath: string
  readonly status: string
  readonly assignedAgentIdentityID?: string
  readonly currentEndpointID?: string
  readonly currentRunID?: string
  readonly constraints?: readonly string[]
  readonly successCriteria?: readonly string[]
  readonly updatedAt: string
}

export interface ChatEntry {
  readonly id: string
  readonly authorKind: 'user' | 'agent' | 'system'
  readonly authorName: string
  readonly text: string
  readonly createdAt: string
  readonly deliveryState?: string
  readonly targetEndpointID?: string
}

export interface RunRecord {
  readonly id: string
  readonly taskID: string
  readonly projectID?: string
  readonly workspaceID?: string
  readonly endpointID: string
  readonly actorName: string
  readonly purpose: string
  readonly state: string
  readonly nativeOutput?: string
  readonly contextPackID?: string
  readonly nativeThreadID?: string
  readonly nativeTurnID?: string
  readonly reasoningEffort?: string
  readonly agentIdentityID?: string
  readonly createdAt: string
  readonly updatedAt?: string
}

export interface ContextRecord {
  readonly id: string
  readonly projectID: string
  readonly sourceID: string
  readonly externalID?: string
  readonly kind: string
  readonly subject?: string
  readonly value: { readonly type?: string; readonly value?: unknown }
  readonly contentSHA256: string
  readonly status: string
  readonly scope: { readonly taskID?: string }
  readonly confidence?: number
  readonly createdAt: string
  readonly statusUpdatedAt?: string
}

export interface ExternalConversationMessage {
  readonly nativeItemID: string
  readonly ordinal: number
  readonly role: 'user' | 'assistant'
  readonly text: string
  readonly phase?: string
  readonly createdAt?: string
}

export interface ExternalConversationCandidate {
  readonly provider: { readonly rawValue: string }
  readonly providerInstanceKey: string
  readonly nativeSessionID: string
  readonly title: string
  readonly canonicalWorkspacePath: string
  readonly createdAt?: string
  readonly updatedAt?: string
  readonly isArchived: boolean
  readonly model?: string
  readonly agentLabel?: string
  readonly accessKind: string
  readonly resumability: string
  readonly sourceLocation?: string
  readonly warnings: readonly string[]
  readonly discoveredMessageCount?: number
  readonly messages: readonly ExternalConversationMessage[]
  readonly runtimeInstanceIdentity?: EndpointInstanceIdentity
}

export interface RuntimeArtifact {
  readonly id: string
  readonly name: string
  readonly relativePath: string
  readonly kind: string
  readonly byteCount: number
  readonly modifiedAt: string
}

export interface Handoff {
  readonly id: string
  readonly taskID: string
  readonly sourceEndpointID: string
  readonly receiverEndpointID: string
  readonly status: string
  readonly validationMessage: string
  readonly createdAt: string
}

export interface LedgerEvent {
  readonly sequence: number
  readonly id: string
  readonly type: string
  readonly summary: string
  readonly taskID?: string
  readonly runID?: string
  readonly occurredAt: string
  readonly payload?: Readonly<Record<string, string>>
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    headers: { 'content-type': 'application/json' },
    ...init,
  })
  const body = (await response.json()) as T & { error?: string; message?: string }
  if (!response.ok || body.error !== undefined) {
    throw new Error(body.message ?? body.error ?? `HTTP ${response.status}`)
  }
  return body
}

export const api = {
  health: () => request<{ ok: boolean; mode: string }>('/health'),
  listProjects: () => request<{ projects: Project[] }>('/projects'),
  createProject: (displayName: string, repositoryPath?: string) =>
    request<{ project: Project }>('/projects', { method: 'POST', body: JSON.stringify({ displayName, repositoryPath }) }),
  renameProject: (projectID: string, displayName: string) =>
    request<{ project: Project }>(`/projects/${projectID}`, { method: 'PATCH', body: JSON.stringify({ displayName }) }),
  removeProject: (projectID: string) =>
    request<{ project: Project }>(`/projects/${projectID}`, { method: 'DELETE' }),
  listAgents: () => request<{ agents: Agent[] }>('/agents'),
  createAgent: (params: { displayName: string; shortName: string; role: string; summary: string; preferredEndpointID?: string }) =>
    request<{ agent: Agent }>('/agents', { method: 'POST', body: JSON.stringify(params) }),
  listEndpoints: () => request<{ endpoints: Endpoint[] }>('/endpoints'),
  removeEndpoint: (endpointID: string) =>
    request<{ endpoint: Endpoint }>(`/endpoints/${endpointID}`, { method: 'DELETE' }),
  removeDuplicateDiscoveredEndpoints: () =>
    request<{ removedEndpointIDs: string[] }>('/endpoints/cleanup-duplicates', { method: 'POST' }),
  createEndpoint: (params: { runtimeTypeID: string; displayName: string; runtimeVersion: string; location: string; executablePath?: string; surfaceKind?: string; instanceLabel?: string }) =>
    request<{ endpoint: Endpoint }>('/endpoints', { method: 'POST', body: JSON.stringify(params) }),
  probeEndpoints: () => request<{ outcomes: Array<{ endpointID: string; ok: boolean; message: string }> }>(
    '/endpoints/probe',
    { method: 'POST' },
  ),
  listTasks: (projectID?: string) => request<{ tasks: Task[] }>(
    projectID === undefined ? '/tasks' : `/tasks?projectID=${encodeURIComponent(projectID)}`,
  ),
  createTask: (params: { projectID?: string; title: string; objective: string; repositoryPath: string; assignedAgentIdentityID?: string }) =>
    request<{ task: Task }>('/tasks', { method: 'POST', body: JSON.stringify(params) }),
  fetchTask: (id: string) => request<{ task: Task }>(`/tasks/${id}`),
  listChat: (taskID: string) => request<{ entries: ChatEntry[] }>(`/tasks/${taskID}/chat`),
  listRuns: (taskID: string) => request<{ runs: RunRecord[] }>(`/tasks/${taskID}/runs`),
  listArtifacts: (taskID: string) => request<{ artifacts: RuntimeArtifact[] }>(`/tasks/${taskID}/artifacts`),
  listContext: (taskID: string) => request<{ records: ContextRecord[] }>(`/tasks/${taskID}/context`),
  listHandoffs: (taskID?: string) =>
    request<{ handoffs: Handoff[] }>(taskID === undefined ? '/handoffs' : `/tasks/${taskID}/handoffs`),
  listLedger: (taskID?: string) =>
    request<{ events: LedgerEvent[] }>(taskID === undefined ? '/ledger' : `/tasks/${taskID}/ledger`),
  startTurn: (
    taskID: string,
    text: string,
    params: { endpointID?: string; contextPackID?: string; contextRecordIDs?: readonly string[]; reasoningEffort?: string } = {},
  ) => request<{ runID: string; taskID: string; state: string }>(`/tasks/${taskID}/turns`, {
    method: 'POST',
    body: JSON.stringify({ text, ...params }),
  }),
  interruptRun: (taskID: string, runID: string) =>
    request<{ ok: boolean }>(`/tasks/${taskID}/interrupt`, {
      method: 'POST',
      body: JSON.stringify({ runID }),
    }),
  importContext: (params: { projectID: string; taskID?: string; kind: string; subject: string; text: string; externalRef?: string; runtimeEndpointID?: string; runtimeSessionID?: string }) =>
    request<{ record: ContextRecord }>('/context/import', {
      method: 'POST',
      body: JSON.stringify(params),
    }),
  reviewContext: (recordID: string, decision: string) =>
    request<{ record: ContextRecord }>(`/context/${recordID}/review`, {
      method: 'POST',
      body: JSON.stringify({ decision }),
    }),
  discoverHistory: (endpointID: string, workspacePath: string) =>
    request<{ conversations: ExternalConversationCandidate[] }>(`/endpoints/${endpointID}/history?workspacePath=${encodeURIComponent(workspacePath)}`),
  hydrateHistory: (endpointID: string, candidate: ExternalConversationCandidate) =>
    request<{ conversation: ExternalConversationCandidate }>(`/endpoints/${endpointID}/history/hydrate`, {
      method: 'POST',
      body: JSON.stringify({ candidate }),
    }),
}
