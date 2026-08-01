import { NavLink, Route, Routes } from 'react-router'
import { OverviewPage } from './pages/OverviewPage.tsx'
import { ProjectsPage } from './pages/ProjectsPage.tsx'
import { AgentsPage } from './pages/AgentsPage.tsx'
import { EndpointsPage } from './pages/EndpointsPage.tsx'
import { TasksPage } from './pages/TasksPage.tsx'
import { TaskDetailPage } from './pages/TaskDetailPage.tsx'
import { HandoffsPage } from './pages/HandoffsPage.tsx'
import { LedgerPage } from './pages/LedgerPage.tsx'

const NAV = [
  { to: '/', label: 'Overview', end: true },
  { to: '/agents', label: 'Agents', end: false },
  { to: '/projects', label: 'Projects', end: false },
] as const

function navClass(isActive: boolean): string {
  return [
    'block rounded-md border px-3 py-2 text-sm transition-colors',
    isActive
      ? 'border-violet-500/30 bg-violet-500/15 font-semibold text-violet-200'
      : 'border-transparent text-zinc-300 hover:bg-zinc-800/70 hover:text-white',
  ].join(' ')
}

export default function App() {
  return (
    <div className="mu-app-shell flex h-screen bg-zinc-950 text-zinc-100">
      {/* Sidebar */}
      <aside className="flex w-56 shrink-0 flex-col border-r border-zinc-800 bg-zinc-900/80 px-2">
        <div className="flex items-center gap-3 px-3 pb-5 pt-5">
          <div className="mu-brand-mark">μ</div>
          <div className="min-w-0">
            <div className="font-semibold tracking-wide text-zinc-100">Mu</div>
            <div className="truncate text-[11px] text-zinc-500">Runtime control plane</div>
          </div>
        </div>
        <nav className="flex-1 space-y-1">
          {NAV.map((item) => (
            <NavLink key={item.to} to={item.to} end={item.end} className={({ isActive }) => navClass(isActive)}>
              <span className="mr-2 inline-block h-1.5 w-1.5 rounded-full bg-current align-middle opacity-70" />
              {item.label}
            </NavLink>
          ))}
        </nav>
        <div className="border-t border-zinc-800 px-4 py-3">
          <div className="flex items-center gap-2 text-xs font-medium text-zinc-400"><span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />Local control plane</div>
          <div className="mt-1 text-[11px] text-zinc-600">SQLite + CAS · no hosted relay</div>
          <div className="mt-1 text-[11px] text-zinc-600">State saves continuously</div>
        </div>
      </aside>

      {/* Main content */}
      <main className="flex-1 overflow-y-auto">
        <Routes>
          <Route path="/" element={<OverviewPage />} />
          <Route path="/overview" element={<OverviewPage />} />
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
