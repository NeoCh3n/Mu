import { NavLink, Route, Routes } from 'react-router'
import { ProjectsPage } from './pages/ProjectsPage.tsx'
import { AgentsPage } from './pages/AgentsPage.tsx'
import { EndpointsPage } from './pages/EndpointsPage.tsx'
import { TasksPage } from './pages/TasksPage.tsx'
import { TaskDetailPage } from './pages/TaskDetailPage.tsx'
import { HandoffsPage } from './pages/HandoffsPage.tsx'
import { LedgerPage } from './pages/LedgerPage.tsx'
import { useSSE } from './hooks.ts'

const NAV = [
  { to: '/projects', label: 'Projects' },
  { to: '/agents', label: 'Agents' },
  { to: '/endpoints', label: 'Runtimes' },
  { to: '/tasks', label: 'Tasks' },
  { to: '/handoffs', label: 'Handoffs' },
  { to: '/ledger', label: 'Ledger' },
] as const

function navClass(isActive: boolean): string {
  return [
    'block rounded-md px-3 py-1.5 text-sm transition-colors',
    isActive ? 'bg-blue-600 text-white' : 'text-zinc-300 hover:bg-zinc-800 hover:text-white',
  ].join(' ')
}

export default function App() {
  const sse = useSSE(50)
  return (
    <div className="flex h-screen bg-zinc-950 text-zinc-100">
      {/* Sidebar */}
      <aside className="flex w-56 shrink-0 flex-col border-r border-zinc-800 bg-zinc-900">
        <div className="px-4 py-4 text-lg font-semibold tracking-wide">Mu</div>
        <nav className="flex-1 space-y-0.5 px-2">
          {NAV.map((item) => (
            <NavLink key={item.to} to={item.to} end={item.to === '/projects'} className={({ isActive }) => navClass(isActive)}>
              {item.label}
            </NavLink>
          ))}
        </nav>
        <div className="border-t border-zinc-800 px-4 py-3">
          <div className="text-xs font-medium uppercase tracking-wider text-zinc-500">Live events</div>
          <div className="mt-1 max-h-32 overflow-y-auto text-[11px] leading-4 text-zinc-400">
            {sse.length === 0 && <div>Waiting for events…</div>}
            {sse.slice(-10).map((envelope, index) => (
              <div key={`${envelope.event}-${index}`}>
                <span className="text-blue-400">{envelope.event}</span>{' '}
                <span className="text-zinc-500">{eventSummary(envelope)}</span>
              </div>
            ))}
          </div>
        </div>
      </aside>

      {/* Main content */}
      <main className="flex-1 overflow-y-auto">
        <Routes>
          <Route path="/" element={<ProjectsPage />} />
          <Route path="/projects" element={<ProjectsPage />} />
          <Route path="/agents" element={<AgentsPage />} />
          <Route path="/endpoints" element={<EndpointsPage />} />
          <Route path="/tasks" element={<TasksPage />} />
          <Route path="/tasks/:id" element={<TaskDetailPage />} />
          <Route path="/handoffs" element={<HandoffsPage />} />
          <Route path="/ledger" element={<LedgerPage />} />
        </Routes>
      </main>
    </div>
  )
}

function eventSummary(envelope: { event: string; data: unknown }): string {
  const data = envelope.data as { summary?: string; kind?: string; state?: string } | null
  if (envelope.event === 'turn_event' && data?.kind !== undefined) return data.kind
  return data?.summary ?? data?.kind ?? ''
}
