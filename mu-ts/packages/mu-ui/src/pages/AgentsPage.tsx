import { useMemo, useState } from 'react'
import { api, type Agent, type Endpoint } from '../api.ts'
import { useQuery } from '../hooks.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

const ROLES = ['orchestrator', 'builder', 'researcher', 'reviewer'] as const

export function AgentsPage() {
  const { data, error, reload } = useQuery(() => api.listAgents())
  const { data: endpointData } = useQuery(() => api.listEndpoints())
  const [displayName, setDisplayName] = useState('')
  const [shortName, setShortName] = useState('')
  const [role, setRole] = useState<string>('builder')
  const [summary, setSummary] = useState('')
  const [preferredEndpointID, setPreferredEndpointID] = useState('')
  const [creating, setCreating] = useState(false)
  const [showOther, setShowOther] = useState(false)
  const [showOtherRuntimes, setShowOtherRuntimes] = useState(false)
  const agents = data?.agents ?? []
  const primaryAgents = useMemo(() => agents.filter((agent) => !isPlaceholderAgent(agent)), [agents])
  const otherAgents = useMemo(() => agents.filter(isPlaceholderAgent), [agents])
  const primaryEndpoints = useMemo(() => {
    const useful = (endpointData?.endpoints ?? []).filter(isUsefulEndpoint)
    const groups = new Map<string, Endpoint[]>()
    for (const endpoint of useful) {
      const key = endpoint.instanceIdentity?.stableInstanceKey !== undefined
        ? `identity:${endpoint.instanceIdentity.provider?.rawValue ?? endpoint.runtimeTypeID}:${endpoint.instanceIdentity.stableInstanceKey}`
        : `unidentified:${endpoint.runtimeTypeID}:${endpoint.displayName}`
      groups.set(key, [...(groups.get(key) ?? []), endpoint])
    }
    return [...groups.values()]
      .map((items) => [...items].sort((left, right) => Number(right.status === 'active') - Number(left.status === 'active') || right.lastProbedAt.localeCompare(left.lastProbedAt))[0])
      .filter((endpoint): endpoint is Endpoint => endpoint !== undefined)
      .sort((left, right) => left.displayName.localeCompare(right.displayName))
  }, [endpointData?.endpoints])
  const otherEndpoints = useMemo(() => {
    const primaryIDs = new Set(primaryEndpoints.map((endpoint) => endpoint.id))
    return (endpointData?.endpoints ?? []).filter((endpoint) => !primaryIDs.has(endpoint.id))
  }, [endpointData?.endpoints, primaryEndpoints])

  async function create(): Promise<void> {
    if (displayName.trim() === '') return
    setCreating(true)
    try {
      await api.createAgent({
        displayName: displayName.trim(),
        shortName: shortName.trim() || displayName.trim().toLowerCase(),
        role,
        summary: summary.trim(),
        preferredEndpointID: preferredEndpointID || undefined,
      })
      setDisplayName('')
      setShortName('')
      setSummary('')
      setPreferredEndpointID('')
      reload()
    } catch (reason) {
      console.error(reason)
    } finally {
      setCreating(false)
    }
  }

  return (
    <Page title="Agent identities" subtitle="Choose how work is framed; bind the runtime separately.">
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-6 rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
        <div className="mb-3 text-xs font-semibold uppercase tracking-[0.16em] text-zinc-500">Identity is not runtime · {primaryAgents.length} shown{otherAgents.length === 0 ? '' : ` · ${otherAgents.length} placeholders hidden`}</div>
        <div className="grid gap-2 md:grid-cols-5">
          <input value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder="Display name" className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm" />
          <input value={shortName} onChange={(event) => setShortName(event.target.value)} placeholder="Mention name" className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm" />
          <select value={role} onChange={(event) => setRole(event.target.value)} className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm">
            {ROLES.map((item) => <option key={item} value={item}>{item}</option>)}
          </select>
          <select value={preferredEndpointID} onChange={(event) => setPreferredEndpointID(event.target.value)} className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm">
            <option value="">Preferred endpoint…</option>
            {(endpointData?.endpoints ?? []).map((endpoint) => <option key={endpoint.id} value={endpoint.id}>{endpointLabel(endpoint)}</option>)}
          </select>
          <button onClick={() => void create()} disabled={creating || displayName.trim() === ''} className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-500 disabled:opacity-40">{creating ? 'Registering…' : 'Register agent'}</button>
          <input value={summary} onChange={(event) => setSummary(event.target.value)} placeholder="What this agent is for" className="md:col-span-5 rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm" />
        </div>
      </div>

      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        {primaryAgents.map((agent) => {
          const endpoint = endpointData?.endpoints.find((candidate) => candidate.id === agent.preferredEndpointID)
          return <AgentCard key={agent.id} agent={agent} endpoint={endpoint} />
        })}
      </div>
      {otherAgents.length > 0 && <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950/40 p-3"><button type="button" onClick={() => setShowOther((current) => !current)} className="flex w-full items-center justify-between text-left text-sm font-medium text-zinc-300"><span>Other identities · {otherAgents.length}</span><span className="text-xs text-zinc-600">{showOther ? 'Hide' : 'Show'}</span></button>{showOther && <div className="mt-3 space-y-2">{otherAgents.map((agent) => <div key={agent.id} className="flex items-center gap-3 rounded-lg border border-zinc-800/80 px-3 py-2"><span className="h-2 w-2 rounded-full" style={{ backgroundColor: agent.accentHex }} /><span className="text-sm text-zinc-300">{agent.displayName}</span><span className="font-mono text-[10px] text-zinc-600">{agent.id}</span></div>)}</div>}</div>}
      {agents.length === 0 && <Empty message="No agents yet." />}

      <section className="mt-8">
        <div className="mb-3 flex items-end justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold text-zinc-200">Runtime endpoints</h2>
            <p className="mt-1 text-xs text-zinc-500">Agents are framed here; endpoint identity decides where work actually runs.</p>
          </div>
          <span className="text-xs text-zinc-600">{primaryEndpoints.length} useful · {otherEndpoints.length} discovered</span>
        </div>
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {primaryEndpoints.map((endpoint) => <RuntimeCompactCard key={endpoint.id} endpoint={endpoint} />)}
          {primaryEndpoints.length === 0 && <Empty message="No useful runtime endpoints yet." />}
        </div>
        {otherEndpoints.length > 0 && <div className="mt-3 rounded-xl border border-zinc-800 bg-zinc-950/40 p-3"><button type="button" onClick={() => setShowOtherRuntimes((current) => !current)} className="flex w-full items-center justify-between text-left text-sm font-medium text-zinc-300"><span>Other discovered runtimes · {otherEndpoints.length}</span><span className="text-xs text-zinc-600">{showOtherRuntimes ? 'Hide' : 'Show'}</span></button>{showOtherRuntimes && <div className="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-3">{otherEndpoints.map((endpoint) => <RuntimeCompactCard key={endpoint.id} endpoint={endpoint} />)}</div>}</div>}
      </section>
    </Page>
  )
}

function isUsefulEndpoint(endpoint: Endpoint): boolean {
  return endpoint.status !== 'discovered' || endpoint.instanceIdentity !== undefined || endpoint.nativeConfiguration !== undefined
}

function RuntimeCompactCard({ endpoint }: { endpoint: Endpoint }) {
  const identity = endpoint.instanceIdentity
  const surface = identity?.surfaceKind === 'desktop_app' || identity?.surfaceKind === 'desktop_application' ? 'Desktop' : identity?.surfaceKind === 'terminal_cli' ? 'Terminal' : 'Runtime'
  return <article className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4"><div className="flex items-start gap-3"><span className={`mt-1 h-2.5 w-2.5 shrink-0 rounded-full ${endpoint.status === 'active' ? 'bg-emerald-400' : 'bg-amber-400'}`} /><div className="min-w-0 flex-1"><h3 className="truncate text-sm font-medium text-zinc-100">{endpoint.displayName}</h3><p className="mt-1 truncate font-mono text-[10px] text-zinc-600">{endpoint.runtimeTypeID}</p></div><span className="rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] text-zinc-400">{surface}</span></div><div className="mt-4 flex items-center justify-between gap-3 border-t border-zinc-800 pt-3 text-[11px] text-zinc-500"><span className="truncate">{identity?.instanceLabel ?? identity?.terminalIdentifier ?? 'Endpoint identity pending'}</span><span className="shrink-0 capitalize">{endpoint.status}</span></div></article>
}

function isPlaceholderAgent(agent: Agent): boolean {
  if (agent.preferredEndpointID !== undefined || (agent.capabilityTags?.length ?? 0) > 0) return false
  if (agent.shortName.toLowerCase() !== agent.displayName.toLowerCase()) return false
  const summaries: Record<string, string> = {
    builder: 'Implements task work in the workspace.',
    reviewer: 'Reviews work and approves changes.',
    researcher: 'Discovers and verifies context facts.',
    orchestrator: 'Plans and routes tasks across agents.',
  }
  return summaries[agent.displayName.toLowerCase()]?.toLowerCase() === agent.summary.toLowerCase()
}

function endpointLabel(endpoint: Endpoint): string {
  const identity = endpoint.instanceIdentity
  const suffix = identity?.instanceLabel ?? identity?.terminalIdentifier
  return suffix === undefined ? endpoint.displayName : `${endpoint.displayName} · ${suffix}`
}

function AgentCard({ agent, endpoint }: { agent: { id: string; displayName: string; shortName: string; role: string; summary: string; accentHex: string; availability: string }; endpoint?: Endpoint }) {
  const identity = endpoint?.instanceIdentity
  const surface = identity?.surfaceKind === 'desktop_app' || identity?.surfaceKind === 'desktop_application' ? 'Desktop' : identity?.surfaceKind === 'terminal_cli' ? 'Terminal' : 'Runtime'
  const terminal = identity?.terminalIdentifier ?? identity?.instanceLabel ?? identity?.stableInstanceKey
  return (
    <article className="flex h-[326px] min-h-[326px] flex-col justify-between rounded-xl border border-zinc-800 bg-zinc-900/70 p-4 transition hover:border-zinc-700">
      <div className="flex items-start gap-3">
        <span className="mt-1 h-3 w-3 shrink-0 rounded-full" style={{ backgroundColor: agent.accentHex }} />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h2 className="truncate font-medium text-zinc-100">{agent.displayName}</h2>
            <span className="shrink-0 rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] uppercase tracking-wider text-zinc-400">{agent.availability}</span>
          </div>
          <div className="mt-1 text-xs text-zinc-500">{agent.role} · @{agent.shortName}</div>
          <p className="mt-2 line-clamp-2 text-sm leading-5 text-zinc-400">{agent.summary || 'No description yet.'}</p>
        </div>
      </div>
      <div className="border-t border-zinc-800 pt-2">
        {endpoint === undefined ? (
          <span className="text-xs text-zinc-600">No endpoint linked</span>
        ) : (
          <div className="flex items-center gap-2 text-xs">
            <span className={`h-2 w-2 rounded-full ${endpoint.status === 'active' ? 'bg-emerald-400' : 'bg-amber-400'}`} />
            <span className="truncate text-zinc-300">{endpoint.displayName}</span>
            <span className="rounded bg-blue-950 px-1.5 py-0.5 text-[10px] text-blue-200">{surface}</span>
            {terminal !== undefined && <span className="ml-auto max-w-[10rem] truncate font-mono text-[10px] text-zinc-600" title={terminal}>{terminal}</span>}
          </div>
        )}
      </div>
    </article>
  )
}
