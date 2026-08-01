import { useState } from 'react'
import { api } from '../api.ts'
import { useQuery } from '../hooks.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

const ROLES = ['orchestrator', 'builder', 'researcher', 'reviewer'] as const

export function AgentsPage() {
  const { data, error, reload } = useQuery(() => api.listAgents())
  const [displayName, setDisplayName] = useState('')
  const [shortName, setShortName] = useState('')
  const [role, setRole] = useState<string>('builder')
  const [summary, setSummary] = useState('')

  async function create(): Promise<void> {
    if (displayName.trim() === '') return
    try {
      await api.createAgent({
        displayName: displayName.trim(),
        shortName: shortName.trim() || displayName.trim().toLowerCase(),
        role,
        summary: summary.trim(),
      })
      setDisplayName('')
      setSummary('')
      reload()
    } catch (reason) {
      console.error(reason)
    }
  }

  return (
    <Page title="Agents">
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-6 grid grid-cols-4 gap-2">
        <input value={displayName} onChange={(e) => setDisplayName(e.target.value)} placeholder="Display name" className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm" />
        <input value={shortName} onChange={(e) => setShortName(e.target.value)} placeholder="Short name" className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm" />
        <select value={role} onChange={(e) => setRole(e.target.value)} className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm">
          {ROLES.map((r) => (
            <option key={r} value={r}>{r}</option>
          ))}
        </select>
        <button onClick={() => void create()} disabled={displayName.trim() === ''} className="rounded-md bg-blue-600 px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40">
          Create
        </button>
        <input value={summary} onChange={(e) => setSummary(e.target.value)} placeholder="Summary" className="col-span-4 rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm" />
      </div>
      <div className="space-y-2">
        {data?.agents.map((agent) => (
          <div key={agent.id} className="flex items-center gap-3 rounded-lg border border-zinc-800 bg-zinc-900 p-4">
            <span className="h-3 w-3 rounded-full" style={{ backgroundColor: agent.accentHex }} />
            <div>
              <div className="font-medium">{agent.displayName}</div>
              <div className="text-xs text-zinc-500">{agent.role} · {agent.shortName}</div>
            </div>
            <span className="ml-auto text-xs text-zinc-400">{agent.availability}</span>
          </div>
        ))}
        {data?.agents.length === 0 && <Empty message="No agents yet." />}
      </div>
    </Page>
  )
}
