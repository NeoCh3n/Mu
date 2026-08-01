import { Link } from 'react-router'
import { api, type Agent, type Project, type Task } from '../api.ts'
import { useQuery } from '../hooks.ts'
import { ErrorBanner, Page } from './ProjectsPage.tsx'

/** The same first-glance control-plane summary shown by the native app. */
export function OverviewPage() {
  const { data: projects, error: projectsError } = useQuery(() => api.listProjects())
  const { data: tasks, error: tasksError } = useQuery(() => api.listTasks())
  const { data: agents, error: agentsError } = useQuery(() => api.listAgents())
  const { data: endpoints, error: endpointsError } = useQuery(() => api.listEndpoints())

  const taskRows = tasks?.tasks ?? []
  const activeTasks = taskRows.filter((task) => ['running', 'blocked', 'ready'].includes(task.status))
  const projectRows = projects?.projects.filter((project) => project.status !== 'archived') ?? []
  const agentRows = agents?.agents ?? []
  const participatingAgentIDs = new Set(activeTasks.flatMap((task) => task.assignedAgentIdentityID === undefined ? [] : [task.assignedAgentIdentityID]))
  const participatingAgents = agentRows.filter((agent) => participatingAgentIDs.has(agent.id))
  const usefulEndpoints = (endpoints?.endpoints ?? []).filter((endpoint) => endpoint.status !== 'discovered' || endpoint.instanceIdentity !== undefined || endpoint.nativeConfiguration !== undefined)
  const error = projectsError ?? tasksError ?? agentsError ?? endpointsError

  return (
    <Page title="Control plane" subtitle="Projects organize portable Task state across runtime boundaries.">
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-5 flex justify-end">
        <Link to="/projects" className="mu-primary-button">New project</Link>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <MetricCard label="Current projects" value={`${projectRows.length}`} detail={`${activeTasks.length} active Tasks`} tone="violet" />
        <MetricCard label="Agents in work" value={`${participatingAgents.length}`} detail="Assigned to active Tasks" tone="coral" />
        <MetricCard label="All agents" value={`${agentRows.length}`} detail="Local identities" tone="mint" />
        <MetricCard label="Connected runtimes" value={`${usefulEndpoints.length}`} detail="Useful endpoint records" tone="blue" />
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-[1.25fr_0.75fr]">
        <section className="mu-panel min-h-44">
          <PanelHeading title="Current Projects" subtitle="Open a Project to continue its workspace chat" />
          {projectRows.length === 0 ? <EmptyInline message="No Projects yet" detail="Create a Project to give Agents a shared workspace." /> : <div className="space-y-2">{projectRows.slice(0, 8).map((project) => <ProjectPresenceRow key={project.id} project={project} tasks={taskRows} agents={agentRows} />)}</div>}
        </section>
        <section className="mu-panel min-h-44">
          <PanelHeading title="Agents in the room" subtitle="Who is currently participating" />
          {participatingAgents.length === 0 ? <EmptyInline message="No active Agent assignments" detail="Agents appear here when a Project Task starts." /> : <div className="space-y-2">{participatingAgents.map((agent) => <AgentPresenceRow key={agent.id} agent={agent} taskCount={activeTasks.filter((task) => task.assignedAgentIdentityID === agent.id).length} />)}</div>}
        </section>
      </div>

      <section className="mu-panel mt-4 flex items-center gap-3">
        <span className="mu-icon-chip mu-icon-violet">●</span>
        <div className="min-w-0 flex-1"><h2 className="text-sm font-semibold text-zinc-200">Honest integration boundary</h2><p className="mt-1 text-xs text-zinc-500">Mu will not label a vendor runtime as controlled until an adapter probe proves it.</p></div>
        <Link to="/agents" className="mu-secondary-button shrink-0">Manage agents & runtimes</Link>
      </section>
    </Page>
  )
}

function ProjectPresenceRow({ project, tasks, agents }: { project: Project; tasks: Task[]; agents: Agent[] }) {
  const projectTasks = tasks.filter((task) => task.projectID === project.id)
  const activeCount = projectTasks.filter((task) => ['running', 'blocked', 'ready'].includes(task.status)).length
  const names = [...new Set(projectTasks.flatMap((task) => {
    const agent = agents.find((candidate) => candidate.id === task.assignedAgentIdentityID)
    return agent === undefined ? [] : [agent.displayName]
  }))]
  return <Link to={`/projects?project=${project.id}`} className="mu-list-row"><span className="mu-icon-chip mu-icon-violet text-xs">⌂</span><span className="min-w-0 flex-1"><span className="block truncate font-medium text-zinc-200">{project.displayName}</span><span className="mt-0.5 block truncate text-[11px] text-zinc-500">{activeCount} active · {projectTasks.length} conversations{names.length > 0 ? ` · ${names.join(', ')}` : ''}</span></span><span className="text-zinc-600">›</span></Link>
}

function AgentPresenceRow({ agent, taskCount }: { agent: Agent; taskCount: number }) {
  return <div className="flex items-center gap-3 rounded-lg border border-zinc-800/80 px-3 py-2"><span className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: agent.accentHex }} /><span className="min-w-0 flex-1"><span className="block truncate text-sm text-zinc-200">{agent.displayName}</span><span className="block truncate text-[11px] text-zinc-500">{agent.role} · {taskCount} active Task{taskCount === 1 ? '' : 's'}</span></span><span className="text-xs text-emerald-300">{agent.availability}</span></div>
}

function MetricCard({ label, value, detail, tone }: { label: string; value: string; detail: string; tone: 'violet' | 'coral' | 'mint' | 'blue' }) {
  return <div className="mu-panel flex min-h-24 items-start justify-between"><div><div className="mu-eyebrow">{label}</div><div className="mt-2 text-3xl font-semibold tracking-tight text-zinc-100">{value}</div><div className="mt-1 text-xs text-zinc-500">{detail}</div></div><span className={`mu-icon-chip mu-icon-${tone}`}>●</span></div>
}

function PanelHeading({ title, subtitle }: { title: string; subtitle: string }) {
  return <div className="mb-4"><h2 className="text-sm font-semibold text-zinc-200">{title}</h2><p className="mt-1 text-xs text-zinc-500">{subtitle}</p></div>
}

function EmptyInline({ message, detail }: { message: string; detail: string }) {
  return <div className="flex min-h-20 items-center gap-3 text-xs text-zinc-500"><span className="text-lg text-zinc-600">◌</span><div><div className="font-medium text-zinc-300">{message}</div><div className="mt-1">{detail}</div></div></div>
}
