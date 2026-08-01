import { useMemo, useState, type ReactNode } from 'react'
import { Link, useNavigate } from 'react-router'
import { api, type Project, type Task } from '../api.ts'
import { useQuery } from '../hooks.ts'

const STATUS_STYLE: Record<string, string> = {
  ready: 'bg-zinc-800 text-zinc-300',
  running: 'bg-blue-950 text-blue-200',
  blocked: 'bg-amber-950 text-amber-200',
  completed: 'bg-emerald-950 text-emerald-200',
  failed: 'bg-red-950 text-red-200',
  cancelled: 'bg-zinc-800 text-zinc-400',
}

export function ProjectsPage() {
  const { data: projectData, error: projectError, reload: reloadProjects } = useQuery(() => api.listProjects())
  const { data: taskData, error: taskError, reload: reloadTasks } = useQuery(() => api.listTasks())
  const { data: agentData } = useQuery(() => api.listAgents())
  const { data: endpointData } = useQuery(() => api.listEndpoints())
  const navigate = useNavigate()
  const [name, setName] = useState('')
  const [repositoryPath, setRepositoryPath] = useState('')
  const [creating, setCreating] = useState(false)
  const [expanded, setExpanded] = useState<Record<string, boolean>>({})
  const [editingID, setEditingID] = useState<string | undefined>()
  const [editingName, setEditingName] = useState('')
  const [errorMessage, setErrorMessage] = useState<string | undefined>()
  const [creatingTaskForProjectID, setCreatingTaskForProjectID] = useState<string | undefined>()

  const projects = useMemo(
    () => (projectData?.projects ?? []).filter((project) => project.status !== 'archived'),
    [projectData?.projects],
  )
  const tasksByProject = useMemo(() => {
    const groups = new Map<string, Task[]>()
    for (const task of taskData?.tasks ?? []) {
      const key = task.projectID ?? '__unassigned__'
      groups.set(key, [...(groups.get(key) ?? []), task])
    }
    return groups
  }, [taskData?.tasks])

  async function create(): Promise<void> {
    if (name.trim() === '') return
    setCreating(true)
    setErrorMessage(undefined)
    try {
      await api.createProject(name.trim(), repositoryPath.trim() || undefined)
      setName('')
      setRepositoryPath('')
      reloadProjects()
    } catch (reason) {
      setErrorMessage(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setCreating(false)
    }
  }

  async function rename(project: Project): Promise<void> {
    const next = editingName.trim()
    if (next === '') return
    try {
      await api.renameProject(project.id, next)
      setEditingID(undefined)
      reloadProjects()
    } catch (reason) {
      setErrorMessage(reason instanceof Error ? reason.message : String(reason))
    }
  }

  async function remove(project: Project): Promise<void> {
    if (!window.confirm(`Remove project “${project.displayName}”? It will be archived, not deleted.`)) return
    try {
      await api.removeProject(project.id)
      reloadProjects()
    } catch (reason) {
      setErrorMessage(reason instanceof Error ? reason.message : String(reason))
    }
  }

  async function startProjectTask(project: Project): Promise<void> {
    if (project.repositoryPath === undefined || project.repositoryPath.trim() === '') {
      setErrorMessage('Import a workspace folder for this Project before starting a Task.')
      return
    }
    setCreatingTaskForProjectID(project.id)
    setErrorMessage(undefined)
    try {
      const existingTask = tasksByProject.get(project.id)?.[0]
      const preferredAgentID = existingTask?.assignedAgentIdentityID
        ?? agentData?.agents.find((agent) => agent.preferredEndpointID !== undefined)?.id
      const result = await api.createTask({
        projectID: project.id,
        title: 'New task',
        objective: `Start working in ${project.displayName}.`,
        repositoryPath: project.repositoryPath,
        assignedAgentIdentityID: preferredAgentID,
      })
      reloadProjects()
      reloadTasks()
      navigate(`/tasks/${result.task.id}`)
    } catch (reason) {
      setErrorMessage(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setCreatingTaskForProjectID(undefined)
    }
  }

  function toggle(projectID: string): void {
    setExpanded((current) => ({ ...current, [projectID]: !(current[projectID] ?? true) }))
  }

  return (
    <Page title="Projects" subtitle="Projects are the durable workspace. Each project keeps its agent conversations and Context Packs together.">
      {(projectError ?? taskError ?? errorMessage) !== undefined && <ErrorBanner message={projectError ?? taskError ?? errorMessage ?? ''} />}

      <div className="mb-6 rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
        <div className="mb-3 text-xs font-semibold uppercase tracking-[0.16em] text-zinc-500">New project</div>
        <div className="grid gap-2 md:grid-cols-[1fr_1.2fr_auto]">
          <input
            value={name}
            onChange={(event) => setName(event.target.value)}
            onKeyDown={(event) => event.key === 'Enter' && void create()}
            placeholder="Project name"
            className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm outline-none ring-blue-500 focus:ring-1"
          />
          <input
            value={repositoryPath}
            onChange={(event) => setRepositoryPath(event.target.value)}
            placeholder="Workspace folder (optional)"
            className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 font-mono text-sm outline-none ring-blue-500 focus:ring-1"
          />
          <button onClick={() => void create()} disabled={creating || name.trim() === ''} className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-500 disabled:opacity-40">
            {creating ? 'Creating…' : 'Create project'}
          </button>
        </div>
      </div>

      <div className="space-y-3">
        {projects.map((project) => {
          const tasks = tasksByProject.get(project.id) ?? []
          const isExpanded = expanded[project.id] ?? true
          return (
            <section key={project.id} className="overflow-hidden rounded-xl border border-zinc-800 bg-zinc-900/70">
              <div className="flex items-center gap-3 px-4 py-3">
                <button
                  type="button"
                  aria-label={`${isExpanded ? 'Collapse' : 'Expand'} ${project.displayName}`}
                  onClick={() => toggle(project.id)}
                  className="flex h-7 w-7 items-center justify-center rounded-md text-zinc-500 transition hover:bg-zinc-800 hover:text-zinc-200"
                >
                  <span className={`text-lg leading-none transition-transform ${isExpanded ? 'rotate-90' : ''}`}>›</span>
                </button>
                <div className="min-w-0 flex-1">
                  {editingID === project.id ? (
                    <form onSubmit={(event) => { event.preventDefault(); void rename(project) }} className="flex gap-2">
                      <input autoFocus value={editingName} onChange={(event) => setEditingName(event.target.value)} className="min-w-0 flex-1 rounded-md border border-blue-500 bg-zinc-950 px-2 py-1 text-sm" />
                      <button className="rounded-md bg-blue-600 px-2 py-1 text-xs">Save</button>
                      <button type="button" onClick={() => setEditingID(undefined)} className="rounded-md px-2 py-1 text-xs text-zinc-400 hover:bg-zinc-800">Cancel</button>
                    </form>
                  ) : (
                    <div className="flex items-baseline gap-2">
                      <h2 className="truncate font-semibold text-zinc-100">{project.displayName}</h2>
                      <span className="text-xs text-zinc-500">{tasks.length} {tasks.length === 1 ? 'conversation' : 'conversations'}</span>
                    </div>
                  )}
                  {project.repositoryPath !== undefined && <div className="mt-0.5 truncate font-mono text-[11px] text-zinc-600">{project.repositoryPath}</div>}
                </div>
                <button type="button" onClick={() => { setEditingID(project.id); setEditingName(project.displayName) }} className="rounded-md px-2 py-1 text-xs text-zinc-500 hover:bg-zinc-800 hover:text-zinc-200">Rename</button>
                <button type="button" onClick={() => void startProjectTask(project)} disabled={creatingTaskForProjectID === project.id} className="rounded-md px-2 py-1 text-xs text-violet-300 hover:bg-violet-950/50 disabled:opacity-40">{creatingTaskForProjectID === project.id ? 'Starting…' : '+ Task'}</button>
                <button type="button" onClick={() => void remove(project)} className="rounded-md px-2 py-1 text-xs text-zinc-500 hover:bg-red-950 hover:text-red-200">Remove</button>
              </div>
              {isExpanded && (
                <div className="border-t border-zinc-800/80 px-3 py-2">
                  {tasks.map((task) => <TaskRow key={task.id} task={task} agentName={agentData?.agents.find((agent) => agent.id === task.assignedAgentIdentityID)?.displayName} endpointName={endpointData?.endpoints.find((endpoint) => endpoint.id === task.currentEndpointID)?.displayName} />)}
                  {tasks.length === 0 && <div className="px-2 py-4 text-sm text-zinc-600">No conversations yet. Create a task to start this project.</div>}
                </div>
              )}
            </section>
          )
        })}
        {(projects.length === 0) && <Empty message="No projects yet — create one above." />}
        {(tasksByProject.get('__unassigned__') ?? []).length > 0 && (
          <section className="overflow-hidden rounded-xl border border-dashed border-zinc-800 bg-zinc-950/40">
            <div className="px-4 py-3 text-sm font-medium text-zinc-400">Unassigned conversations</div>
            <div className="border-t border-zinc-800/80 px-3 py-2">
              {(tasksByProject.get('__unassigned__') ?? []).map((task) => <TaskRow key={task.id} task={task} agentName={agentData?.agents.find((agent) => agent.id === task.assignedAgentIdentityID)?.displayName} endpointName={endpointData?.endpoints.find((endpoint) => endpoint.id === task.currentEndpointID)?.displayName} />)}
            </div>
          </section>
        )}
      </div>
    </Page>
  )
}

function TaskRow({ task, agentName, endpointName }: { task: Task; agentName?: string; endpointName?: string }) {
  return (
    <Link to={`/tasks/${task.id}`} className="group flex items-center gap-3 rounded-lg px-3 py-3 transition hover:bg-zinc-800/80">
      <span className="h-2 w-2 shrink-0 rounded-full bg-zinc-600 group-hover:bg-blue-400" />
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-medium text-zinc-200">{task.title}</div>
        <div className="mt-0.5 truncate text-xs text-zinc-500">{task.objective}</div>
        {(agentName !== undefined || endpointName !== undefined) && <div className="mt-1 truncate text-[10px] text-zinc-600">{agentName ?? 'Unassigned'}{endpointName === undefined ? '' : ` · ${endpointName}`}</div>}
      </div>
      <span className={`shrink-0 rounded-full px-2 py-0.5 text-[11px] ${STATUS_STYLE[task.status] ?? 'bg-zinc-800 text-zinc-400'}`}>{task.status}</span>
    </Link>
  )
}

export function Page({ title, subtitle, children }: { title: string; subtitle?: string; children: ReactNode }) {
  return (
    <div className="mx-auto max-w-6xl p-6 md:p-8">
      <div className="mb-6">
        <h1 className="text-2xl font-semibold tracking-tight text-zinc-100">{title}</h1>
        {subtitle !== undefined && <p className="mt-1 max-w-3xl text-sm leading-6 text-zinc-500">{subtitle}</p>}
      </div>
      {children}
    </div>
  )
}

export function ErrorBanner({ message }: { message: string }) {
  return <div className="mb-4 rounded-lg border border-red-800/80 bg-red-950/40 px-4 py-3 text-sm text-red-200">{message}</div>
}

export function Empty({ message }: { message: string }) {
  return <div className="rounded-xl border border-dashed border-zinc-800 p-8 text-center text-sm text-zinc-500">{message}</div>
}
