import { useEffect, useRef, useState } from 'react'
import { Navigate, NavLink, Route, Routes } from 'react-router'
import { OverviewPage } from './pages/OverviewPage.tsx'
import { ProjectsPage } from './pages/ProjectsPage.tsx'
import { AgentsPage } from './pages/AgentsPage.tsx'
import { TasksPage } from './pages/TasksPage.tsx'
import { TaskDetailPage } from './pages/TaskDetailPage.tsx'
import { HandoffsPage } from './pages/HandoffsPage.tsx'
import { LedgerPage } from './pages/LedgerPage.tsx'
import { SettingsPage } from './pages/SettingsPage.tsx'
import { useMuUISettings, useSSE } from './hooks.ts'
import { text } from './i18n.ts'

const NAV = [
  { to: '/', en: 'Overview', zh: '概览', end: true },
  { to: '/agents', en: 'Agents', zh: 'Agents', end: false },
  { to: '/projects', en: 'Projects', zh: 'Projects', end: false },
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
  const sse = useSSE()
  const { settings } = useMuUISettings()
  const [completionToast, setCompletionToast] = useState<CompletionToast | undefined>()
  const seenEventRef = useRef<string | undefined>(undefined)

  useEffect(() => {
    document.documentElement.lang = settings.language
  }, [settings.language])

  useEffect(() => {
    const latest = sse.at(-1)
    if (latest === undefined || latest.event !== 'turn_ended') return
    const data = latest.data as {
      taskID?: string
      runID?: string
      status?: string
      title?: string
      endedAt?: string
    } | null
    if (data?.status !== 'completed' || data.taskID === undefined) return
    const eventKey = `${data.runID ?? data.taskID}:${data.endedAt ?? latest.event}`
    if (seenEventRef.current === eventKey) return
    seenEventRef.current = eventKey
    if (!settings.completionNotificationsEnabled) return
    setCompletionToast({
      id: eventKey,
      message: text(settings.language, `${data.title ?? 'Project task'} completed.`, `${data.title ?? '项目任务'}已完成。`),
    })
  }, [settings.completionNotificationsEnabled, sse])

  useEffect(() => {
    if (completionToast === undefined) return
    const timer = window.setTimeout(
      () => setCompletionToast((current) => current?.id === completionToast.id ? undefined : current),
      settings.completionToastDuration * 1000,
    )
    return () => window.clearTimeout(timer)
  }, [completionToast, settings.completionToastDuration])

  return (
    <>
      <div className="mu-app-shell flex h-screen bg-zinc-950 text-zinc-100">
        {/* Sidebar */}
        <aside className="flex w-56 shrink-0 flex-col border-r border-zinc-800 bg-zinc-900/80 px-2">
          <div className="flex items-center gap-3 px-3 pb-5 pt-5">
            <div className="mu-brand-mark">μ</div>
            <div className="min-w-0">
              <div className="font-semibold tracking-wide text-zinc-100">Mu</div>
              <div className="truncate text-[11px] text-zinc-500">{text(settings.language, 'Runtime control plane', '运行时控制平面')}</div>
            </div>
          </div>
          <nav className="flex-1 space-y-1">
            {NAV.map((item) => (
              <NavLink key={item.to} to={item.to} end={item.end} className={({ isActive }) => navClass(isActive)}>
                <span className="mr-2 inline-block h-1.5 w-1.5 rounded-full bg-current align-middle opacity-70" />
                {text(settings.language, item.en, item.zh)}
              </NavLink>
            ))}
          </nav>
          <div className="border-t border-zinc-800 px-4 py-3">
            <NavLink to="/settings" className="flex items-center gap-2 text-xs font-medium text-zinc-400 hover:text-zinc-200"><span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />{text(settings.language, 'Local control plane', '本地控制平面')} <span className="ml-auto">⚙</span></NavLink>
            <div className="mt-1 text-[11px] text-zinc-600">SQLite + CAS · {text(settings.language, 'no hosted relay', '无需托管中继')}</div>
            <div className="mt-1 text-[11px] text-zinc-600">{text(settings.language, 'State saves continuously', '状态会自动保存')}</div>
          </div>
        </aside>

        {/* Main content */}
        <main className="flex-1 overflow-y-auto">
          <Routes>
            <Route path="/" element={<OverviewPage />} />
            <Route path="/overview" element={<OverviewPage />} />
            <Route path="/projects" element={<ProjectsPage />} />
            <Route path="/agents" element={<AgentsPage />} />
            {/* Runtime setup and registry intentionally share one surface. */}
            <Route path="/endpoints" element={<Navigate to="/agents" replace />} />
            <Route path="/tasks" element={<TasksPage />} />
            <Route path="/tasks/:id" element={<TaskDetailPage />} />
            <Route path="/handoffs" element={<HandoffsPage />} />
            <Route path="/ledger" element={<LedgerPage />} />
            <Route path="/settings" element={<SettingsPage />} />
          </Routes>
        </main>
      </div>
      {completionToast !== undefined && (
        <div className="fixed bottom-5 right-5 z-50 flex max-w-sm items-start gap-3 rounded-xl border border-emerald-500/30 bg-zinc-900/95 px-4 py-3 text-sm text-zinc-100 shadow-2xl backdrop-blur">
          <span className="mt-0.5 text-emerald-300">✓</span>
          <div className="min-w-0 flex-1">
            <div className="text-[11px] font-semibold uppercase tracking-[0.12em] text-zinc-500">{text(settings.language, 'Task completed', '任务已完成')}</div>
            <div className="mt-1 leading-5">{completionToast.message}</div>
          </div>
          <button type="button" aria-label={text(settings.language, 'Dismiss task completion notification', '关闭任务完成通知')} onClick={() => setCompletionToast(undefined)} className="text-zinc-500 hover:text-zinc-200">×</button>
        </div>
      )}
    </>
  )
}

interface CompletionToast {
  readonly id: string
  readonly message: string
}
