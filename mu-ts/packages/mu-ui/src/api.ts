// Typed client for the Mu HTTP API (Phase 6). Same-origin fetch; the Vite
// dev server proxies /api and the other route prefixes to the Mu server.

export interface Project {
  readonly id: string
  readonly displayName: string
  readonly repositoryPath?: string
  readonly status: string
  readonly createdAt: string
}

export interface Agent {
  readonly id: string
  readonly displayName: string
  readonly shortName: string
  readonly role: string
  readonly summary: string
  readonly accentHex: string
  readonly availability: string
}

export interface Endpoint {
  readonly id: string
  readonly runtimeTypeID: string
  readonly displayName: string
  readonly runtimeVersion: string
  readonly location: string
  readonly status: string
  readonly lastProbedAt: string
}

export interface Task {
  readonly id: string
  readonly projectID?: string
  readonly title: string
  readonly objective: string
  readonly repositoryPath: string
  readonly status: string
  readonly assignedAgentIdentityID?: string
  readonly updatedAt: string
}

export interface ChatEntry {
  readonly id: string
  readonly authorKind: 'user' | 'agent' | 'system'
  readonly authorName: string
  readonly text: string
  readonly createdAt: string
  readonly deliveryState?: string
}

export interface RunRecord {
  readonly id: string
  readonly taskID: string
  readonly endpointID: string
  readonly actorName: string
  readonly purpose: string
  readonly state: string
  readonly nativeOutput?: string
  readonly createdAt: string
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
  createProject: (displayName: string) =>
    request<{ project: Project }>('/projects', { method: 'POST', body: JSON.stringify({ displayName }) }),
  listAgents: () => request<{ agents: Agent[] }>('/agents'),
  createAgent: (params: { displayName: string; shortName: string; role: string; summary: string }) =>
    request<{ agent: Agent }>('/agents', { method: 'POST', body: JSON.stringify(params) }),
  listEndpoints: () => request<{ endpoints: Endpoint[] }>('/endpoints'),
  createEndpoint: (params: { runtimeTypeID: string; displayName: string; runtimeVersion: string; location: string }) =>
    request<{ endpoint: Endpoint }>('/endpoints', { method: 'POST', body: JSON.stringify(params) }),
  probeEndpoints: () => request<{ outcomes: Array<{ endpointID: string; ok: boolean; message: string }> }>(
    '/endpoints/probe',
    { method: 'POST' },
  ),
  listTasks: () => request<{ tasks: Task[] }>('/tasks'),
  createTask: (params: { projectID?: string; title: string; objective: string; repositoryPath: string; assignedAgentIdentityID?: string }) =>
    request<{ task: Task }>('/tasks', { method: 'POST', body: JSON.stringify(params) }),
  fetchTask: (id: string) => request<{ task: Task }>(`/tasks/${id}`),
  listChat: (taskID: string) => request<{ entries: ChatEntry[] }>(`/tasks/${taskID}/chat`),
  listRuns: (taskID: string) => request<{ runs: RunRecord[] }>(`/tasks/${taskID}/runs`),
  listArtifacts: (taskID: string) => request<{ artifacts: RuntimeArtifact[] }>(`/tasks/${taskID}/artifacts`),
  listHandoffs: (taskID?: string) =>
    request<{ handoffs: Handoff[] }>(taskID === undefined ? '/handoffs' : `/tasks/${taskID}/handoffs`),
  listLedger: (taskID?: string) =>
    request<{ events: LedgerEvent[] }>(taskID === undefined ? '/ledger' : `/tasks/${taskID}/ledger`),
  startTurn: (taskID: string, text: string) =>
    request<{ runID: string; taskID: string; state: string }>(`/tasks/${taskID}/turns`, {
      method: 'POST',
      body: JSON.stringify({ text }),
    }),
  interruptRun: (taskID: string, runID: string) =>
    request<{ ok: boolean }>(`/tasks/${taskID}/interrupt`, {
      method: 'POST',
      body: JSON.stringify({ runID }),
    }),
  importContext: (params: { projectID: string; taskID: string; kind: string; subject: string; text: string }) =>
    request<{ record: { id: string; status: string } }>('/context/import', {
      method: 'POST',
      body: JSON.stringify(params),
    }),
  reviewContext: (recordID: string, decision: string) =>
    request<{ record: { id: string; status: string } }>(`/context/${recordID}/review`, {
      method: 'POST',
      body: JSON.stringify({ decision }),
    }),
}
