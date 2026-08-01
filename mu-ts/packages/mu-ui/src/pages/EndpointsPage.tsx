import { useMemo, useState } from 'react'
import { api, type Endpoint } from '../api.ts'
import { useQuery } from '../hooks.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

export function EndpointsPage() {
  const { data, error, reload } = useQuery(() => api.listEndpoints())
  const [showOther, setShowOther] = useState(false)

  const primaryEndpoints = useMemo(() => {
    const useful = (data?.endpoints ?? []).filter((endpoint) => endpoint.status !== 'discovered' || endpoint.instanceIdentity !== undefined || endpoint.nativeConfiguration !== undefined)
    const groups = new Map<string, Endpoint[]>()
    for (const endpoint of useful) {
      const identity = endpoint.instanceIdentity
      const key = identity?.stableInstanceKey !== undefined
        ? `identity:${identity.provider?.rawValue ?? endpoint.runtimeTypeID}:${identity.stableInstanceKey}`
        : `unidentified:${endpoint.runtimeTypeID}:${endpoint.displayName}`
      groups.set(key, [...(groups.get(key) ?? []), endpoint])
    }
    return [...groups.values()]
      .flatMap((items) => {
        const selected = [...items].sort((left, right) => Number(right.status === 'active') - Number(left.status === 'active') || right.lastProbedAt.localeCompare(left.lastProbedAt))[0]
        return selected === undefined ? [] : [selected]
      })
      .sort((left, right) => left.displayName.localeCompare(right.displayName))
  }, [data?.endpoints])

  const otherEndpoints = useMemo(() => {
    const primaryIDs = new Set(primaryEndpoints.map((endpoint) => endpoint.id))
    return (data?.endpoints ?? []).filter((endpoint) => !primaryIDs.has(endpoint.id))
  }, [data?.endpoints, primaryEndpoints])

  async function probe(): Promise<void> {
    try {
      await api.probeEndpoints()
      reload()
    } catch (reason) {
      console.error(reason)
    }
  }

  return (
    <Page title="Runtime registry" subtitle="Scheduling uses capabilities and policy—not vendor names.">
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-4">
        <button onClick={() => void probe()} className="rounded-md bg-zinc-800 px-4 py-1.5 text-sm font-medium text-zinc-200 hover:bg-zinc-700">
          Probe all
        </button>
      </div>
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {primaryEndpoints.map((endpoint) => <EndpointCard key={endpoint.id} endpoint={endpoint} onProbe={() => void probe()} />)}
        {primaryEndpoints.length === 0 && <Empty message="No verified runtimes yet." />}
        {data?.endpoints.length === 0 && <Empty message="No runtimes registered." />}
      </div>
      {otherEndpoints.length > 0 && (
        <div className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950/40 p-3">
          <button type="button" onClick={() => setShowOther((current) => !current)} className="flex w-full items-center justify-between text-left text-sm font-medium text-zinc-300">
            <span>Other discovered runtimes · {otherEndpoints.length}</span>
            <span className="text-xs text-zinc-600">{showOther ? 'Hide' : 'Show'}</span>
          </button>
          {showOther && <div className="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-3">{otherEndpoints.map((endpoint) => <EndpointCard key={endpoint.id} endpoint={endpoint} onProbe={() => void probe()} />)}</div>}
        </div>
      )}
    </Page>
  )
}

function EndpointCard({ endpoint, onProbe }: { endpoint: Endpoint; onProbe: () => void }) {
  return <div className="flex min-h-[326px] flex-col rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
    <div className="flex items-start gap-3"><StatusDot status={endpoint.status} /><div className="min-w-0 flex-1"><div className="truncate font-medium text-zinc-100">{endpoint.displayName}</div><div className="mt-1 truncate font-mono text-[11px] text-zinc-500">{endpoint.runtimeTypeID}</div></div><span className={`rounded-full px-2 py-0.5 text-[10px] ${endpoint.status === 'active' ? 'bg-emerald-950 text-emerald-200' : 'bg-amber-950 text-amber-200'}`}>{endpoint.status}</span></div>
    <div className="mt-5 grid grid-cols-2 gap-x-3 gap-y-3 text-[10px]"><Field label="Version" value={endpoint.runtimeVersion} /><Field label="Provenance" value={endpoint.provenance ?? '—'} /><Field label="Surface" value={surfaceLabel(endpoint.instanceIdentity?.surfaceKind)} /><Field label="Instance basis" value={endpoint.instanceIdentity?.identityBasis ?? '—'} /><Field label="Connection" value={endpoint.instanceIdentity?.surfaceKind === 'desktop_app' ? 'Connected Agent' : 'Managed Runtime'} /><Field label="Location" value={endpoint.location} /></div>
    <div className="mt-5 flex flex-wrap gap-1">{(endpoint.capabilities ?? []).slice(0, 5).map((capability) => <span key={capability} className="rounded-full bg-zinc-800 px-2 py-1 text-[10px] text-zinc-400">{capability}</span>)}</div>
    <p className="mt-4 line-clamp-4 text-xs leading-5 text-zinc-500">{endpoint.guaranteeNote ?? 'Registered by the control plane.'}</p>
    <div className="mt-auto flex items-center justify-between border-t border-zinc-800 pt-3"><span className="max-w-[14rem] truncate font-mono text-[10px] text-zinc-600" title={endpoint.instanceIdentity?.stableInstanceKey}>{endpoint.instanceIdentity?.instanceLabel ?? endpoint.instanceIdentity?.terminalIdentifier ?? endpoint.id}</span><button type="button" onClick={onProbe} className="rounded-md bg-zinc-800 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-zinc-700">Probe</button></div>
  </div>
}

function surfaceLabel(surfaceKind?: string): string {
  if (surfaceKind === 'desktop_app' || surfaceKind === 'desktop_application') return 'Desktop'
  if (surfaceKind === 'terminal_cli') return 'Terminal'
  return 'Runtime'
}

function StatusDot({ status }: { status: string }) {
  const color = status === 'active' ? 'bg-green-500' : status === 'offline' ? 'bg-red-500' : 'bg-amber-500'
  return <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${color}`} title={status} />
}

function Field({ label, value }: { label: string; value: string }) {
  return <div><div className="uppercase tracking-[0.12em] text-zinc-600">{label}</div><div className="mt-1 truncate text-zinc-300">{value}</div></div>
}
