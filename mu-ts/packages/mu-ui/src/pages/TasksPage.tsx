import { useState } from 'react'
import { Link } from 'react-router'
import { api } from '../api.ts'
import { useMuUISettings, useQuery } from '../hooks.ts'
import { statusText, text } from '../i18n.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

const STATUS_STYLE: Record<string, string> = {
  ready: 'bg-zinc-800 text-zinc-300',
  running: 'bg-blue-900 text-blue-200',
  blocked: 'bg-amber-900 text-amber-200',
  completed: 'bg-green-900 text-green-200',
  failed: 'bg-red-900 text-red-200',
  cancelled: 'bg-zinc-800 text-zinc-400',
}

export function TasksPage() {
  const { settings } = useMuUISettings()
  const t = (english: string, simplifiedChinese: string) => text(settings.language, english, simplifiedChinese)
  const { data, error, reload } = useQuery(() => api.listTasks())
  const { data: projects } = useQuery(() => api.listProjects())
  const { data: agents } = useQuery(() => api.listAgents())
  const [title, setTitle] = useState('')
  const [objective, setObjective] = useState('')
  const [repositoryPath, setRepositoryPath] = useState('')
  const [projectID, setProjectID] = useState('')
  const [agentID, setAgentID] = useState('')

  async function create(): Promise<void> {
    if (title.trim() === '' || objective.trim() === '' || repositoryPath.trim() === '') return
    try {
      await api.createTask({
        projectID: projectID === '' ? undefined : projectID,
        title: title.trim(),
        objective: objective.trim(),
        repositoryPath: repositoryPath.trim(),
        assignedAgentIdentityID: agentID === '' ? undefined : agentID,
      })
      setTitle('')
      setObjective('')
      reload()
    } catch (reason) {
      console.error(reason)
    }
  }

  return (
    <Page title={t('Projects', 'Projects')} subtitle={t('Tasks are conversations and execution records nested inside a Project.', '任务是嵌套在 Project 中的对话和执行记录。')}>
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-6 grid grid-cols-2 gap-2">
        <div className="col-span-2 text-xs font-semibold uppercase tracking-[0.16em] text-zinc-500">{t('New Task', '新建任务')}</div>
        <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder={t('Title', '标题')} className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm" />
        <input value={repositoryPath} onChange={(e) => setRepositoryPath(e.target.value)} placeholder={t('Repository path', '仓库路径')} className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm" />
        <input value={objective} onChange={(e) => setObjective(e.target.value)} placeholder={t('Objective', '目标')} className="col-span-2 rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm" />
        <select value={projectID} onChange={(e) => setProjectID(e.target.value)} className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm">
          <option value="">{t('No project', '无 Project')}</option>
          {projects?.projects.map((p) => (
            <option key={p.id} value={p.id}>{p.displayName}</option>
          ))}
        </select>
        <select value={agentID} onChange={(e) => setAgentID(e.target.value)} className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm">
          <option value="">{t('No agent', '无 Agent')}</option>
          {agents?.agents.map((a) => (
            <option key={a.id} value={a.id}>{a.displayName}</option>
          ))}
        </select>
        <button onClick={() => void create()} disabled={title.trim() === '' || objective.trim() === '' || repositoryPath.trim() === ''} className="col-span-2 rounded-md bg-blue-600 px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40">
          {t('Create task', '创建任务')}
        </button>
      </div>
      <div className="space-y-2">
        {data?.tasks.map((task) => (
          <Link key={task.id} to={`/tasks/${task.id}`} className="block rounded-lg border border-zinc-800 bg-zinc-900 p-4 hover:border-zinc-600">
            <div className="flex items-baseline justify-between gap-4">
              <span className="font-medium">{task.title}</span>
              <span className={`rounded-full px-2 py-0.5 text-xs ${STATUS_STYLE[task.status] ?? 'bg-zinc-800 text-zinc-300'}`}>{statusText(settings.language, task.status)}</span>
            </div>
            <div className="mt-1 text-sm text-zinc-400">{task.objective}</div>
            <div className="mt-1 font-mono text-xs text-zinc-600">{task.repositoryPath}</div>
          </Link>
        ))}
        {data?.tasks.length === 0 && <Empty message={t('No tasks yet — create one above.', '还没有任务，请在上方创建。')} />}
      </div>
    </Page>
  )
}
