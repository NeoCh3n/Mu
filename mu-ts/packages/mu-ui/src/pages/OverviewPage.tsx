import { useEffect, useState } from 'react'
import { Link } from 'react-router'
import { api, type Agent, type Project, type Task } from '../api.ts'
import { collaborationApi, useCollaborationSpace } from '../collaboration.ts'
import { useMuUISettings, useQuery } from '../hooks.ts'
import { text } from '../i18n.ts'
import { ErrorBanner, Page } from './ProjectsPage.tsx'

/** The same first-glance control-plane summary shown by the native app. */
export function OverviewPage() {
  const { settings } = useMuUISettings()
  const t = (english: string, simplifiedChinese: string) => text(settings.language, english, simplifiedChinese)
  const { data: projects, error: projectsError } = useQuery(() => api.listProjects())
  const { data: tasks, error: tasksError } = useQuery(() => api.listTasks())
  const { data: agents, error: agentsError } = useQuery(() => api.listAgents())
  const { data: endpoints, error: endpointsError } = useQuery(() => api.listEndpoints())
  const { data: spaces, error: spacesError, reload: reloadSpaces } = useQuery(() => collaborationApi.listSpaces())
  const [selectedSpaceID, setSelectedSpaceID] = useState<string | undefined>()
  const [newSpaceName, setNewSpaceName] = useState('')
  const [spaceCreating, setSpaceCreating] = useState(false)
  const [spaceError, setSpaceError] = useState<string | undefined>()

  const taskRows = tasks?.tasks ?? []
  const activeTasks = taskRows.filter((task) => ['running', 'blocked', 'ready'].includes(task.status))
  const projectRows = projects?.projects.filter((project) => project.status !== 'archived') ?? []
  const agentRows = agents?.agents ?? []
  const participatingAgentIDs = new Set(activeTasks.flatMap((task) => task.assignedAgentIdentityID === undefined ? [] : [task.assignedAgentIdentityID]))
  const participatingAgents = agentRows.filter((agent) => participatingAgentIDs.has(agent.id))
  const usefulEndpoints = (endpoints?.endpoints ?? []).filter((endpoint) => endpoint.status !== 'discovered' || endpoint.instanceIdentity !== undefined || endpoint.nativeConfiguration !== undefined)
  const sharedSpaces = spaces?.spaces.filter((space) => space.status !== 'archived') ?? []
  const activeSpaceID = selectedSpaceID ?? sharedSpaces[0]?.id
  const activeSpace = sharedSpaces.find((space) => space.id === activeSpaceID)
  const spaceSync = useCollaborationSpace(activeSpaceID)
  const error = projectsError ?? tasksError ?? agentsError ?? endpointsError ?? spacesError ?? spaceError

  useEffect(() => {
    if (activeSpaceID !== undefined && selectedSpaceID !== activeSpaceID && sharedSpaces.some((space) => space.id === activeSpaceID)) {
      setSelectedSpaceID(activeSpaceID)
    }
  }, [activeSpaceID, selectedSpaceID, sharedSpaces])

  async function createSharedSpace(): Promise<void> {
    const displayName = newSpaceName.trim()
    if (displayName === '' || spaceCreating) return
    setSpaceCreating(true)
    setSpaceError(undefined)
    try {
      const result = await collaborationApi.createSpace(displayName)
      setNewSpaceName('')
      setSelectedSpaceID(result.space.id)
      reloadSpaces()
    } catch (reason) {
      setSpaceError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setSpaceCreating(false)
    }
  }

  return (
    <Page title={t('Control plane', '控制平面')} subtitle={t('Projects organize portable Task state across runtime boundaries.', 'Projects 将可移植的任务状态组织在不同运行时边界之上。')}>
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-5 flex justify-end">
        <Link to="/projects" className="mu-primary-button">{t('New project', '新建 Project')}</Link>
      </div>

      <SharedSpacesPanel
        spaces={sharedSpaces}
        activeSpaceID={activeSpaceID}
        activeSpaceName={activeSpace?.displayName}
        batch={spaceSync.batch}
        connected={spaceSync.connected}
        newSpaceName={newSpaceName}
        creating={spaceCreating}
        language={settings.language}
        onSelect={setSelectedSpaceID}
        onNameChange={setNewSpaceName}
        onCreate={() => void createSharedSpace()}
      />

      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <MetricCard label={t('Current projects', '当前 Projects')} value={`${projectRows.length}`} detail={`${activeTasks.length} ${t('active Tasks', '个活跃任务')}`} tone="violet" />
        <MetricCard label={t('Agents in work', '参与中的 Agents')} value={`${participatingAgents.length}`} detail={t('Assigned to active Tasks', '已分配到活跃任务')} tone="coral" />
        <MetricCard label={t('All agents', '全部 Agents')} value={`${agentRows.length}`} detail={t('Local identities', '本地身份')} tone="mint" />
        <MetricCard label={t('Connected runtimes', '已连接运行时')} value={`${usefulEndpoints.length}`} detail={t('Useful endpoint records', '可用 endpoint 记录')} tone="blue" />
      </div>

      <div className="mt-4 grid gap-4 lg:grid-cols-[1.25fr_0.75fr]">
        <section className="mu-panel min-h-44">
          <PanelHeading title={t('Current Projects', '当前 Projects')} subtitle={t('Open a Project to continue its workspace chat', '打开 Project 继续工作区聊天')} />
          {projectRows.length === 0 ? <EmptyInline message={t('No Projects yet', '还没有 Projects')} detail={t('Create a Project to give Agents a shared workspace.', '创建 Project，为 Agents 提供共享工作区。')} /> : <div className="space-y-2">{projectRows.slice(0, 8).map((project) => <ProjectPresenceRow key={project.id} project={project} tasks={taskRows} agents={agentRows} language={settings.language} />)}</div>}
        </section>
        <section className="mu-panel min-h-44">
          <PanelHeading title={t('Agents in the room', '当前参与的 Agents')} subtitle={t('Who is currently participating', '当前有哪些 Agent 参与')} />
          {participatingAgents.length === 0 ? <EmptyInline message={t('No active Agent assignments', '没有活跃的 Agent 分配')} detail={t('Agents appear here when a Project Task starts.', 'Project 任务开始后，Agent 会显示在这里。')} /> : <div className="space-y-2">{participatingAgents.map((agent) => <AgentPresenceRow key={agent.id} agent={agent} taskCount={activeTasks.filter((task) => task.assignedAgentIdentityID === agent.id).length} language={settings.language} />)}</div>}
        </section>
      </div>

      <section className="mu-panel mt-4 flex items-center gap-3">
        <span className="mu-icon-chip mu-icon-violet">●</span>
        <div className="min-w-0 flex-1"><h2 className="text-sm font-semibold text-zinc-200">{t('Honest integration boundary', '真实集成边界')}</h2><p className="mt-1 text-xs text-zinc-500">{t('Mu will not label a vendor runtime as controlled until an adapter probe proves it.', '只有适配器检查通过后，Mu 才会将 vendor runtime 标记为可控。')}</p></div>
        <Link to="/agents" className="mu-secondary-button shrink-0">{t('Manage agents & runtimes', '管理 Agents 和运行时')}</Link>
      </section>
    </Page>
  )
}

function SharedSpacesPanel({
  spaces,
  activeSpaceID,
  activeSpaceName,
  batch,
  connected,
  newSpaceName,
  creating,
  language,
  onSelect,
  onNameChange,
  onCreate,
}: {
  spaces: readonly { id: string; displayName: string; description: string }[]
  activeSpaceID: string | undefined
  activeSpaceName: string | undefined
  batch: import('../collaboration.ts').SpaceSyncBatch | undefined
  connected: boolean
  newSpaceName: string
  creating: boolean
  language: 'en' | 'zh-Hans'
  onSelect: (id: string) => void
  onNameChange: (value: string) => void
  onCreate: () => void
}) {
  const t = (english: string, simplifiedChinese: string) => text(language, english, simplifiedChinese)
  const presence = batch?.presence ?? []
  return (
    <section className="mu-panel mb-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-zinc-200">{t('Shared workspaces', '共享工作区')}</h2>
          <p className="mt-1 max-w-2xl text-xs leading-5 text-zinc-500">{t('A Space is a shared room for people and Agents. Durable events are ordered; presence is temporary.', 'Space 是人与 Agent 共同工作的房间。持久事件有序保存，在线状态只表示当前连接。')}</p>
        </div>
        <span className={`rounded-full px-2 py-1 text-[11px] ${connected ? 'bg-emerald-950 text-emerald-300' : 'bg-zinc-800 text-zinc-500'}`}>{connected ? t('Live', '实时连接') : t('Offline', '未连接')}</span>
      </div>
      <div className="mt-4 grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(15rem,0.7fr)]">
        <div className="space-y-1.5">
          {spaces.length === 0 ? <div className="rounded-lg border border-dashed border-zinc-800 px-3 py-4 text-xs text-zinc-500">{t('No shared spaces yet. Create one for a common collaboration room.', '还没有共享工作区。创建一个公共房间即可开始协作。')}</div> : spaces.map((space) => <button key={space.id} type="button" onClick={() => onSelect(space.id)} className={`flex w-full items-center gap-3 rounded-lg border px-3 py-2 text-left transition ${space.id === activeSpaceID ? 'border-violet-500/50 bg-violet-500/10' : 'border-zinc-800 hover:bg-zinc-800/60'}`}><span className="mu-icon-chip mu-icon-violet h-8 w-8 text-xs">⌂</span><span className="min-w-0 flex-1"><span className="block truncate text-sm text-zinc-200">{space.displayName}</span><span className="block truncate text-[11px] text-zinc-500">{space.description || t('Shared Mu room', 'Mu 共享房间')}</span></span><span className="text-xs text-zinc-600">{space.id === activeSpaceID ? '●' : '›'}</span></button>)}
        </div>
        <div className="rounded-lg border border-zinc-800 bg-zinc-950/30 p-3">
          <div className="flex items-center justify-between gap-2"><span className="text-xs font-semibold text-zinc-300">{activeSpaceName ?? t('New Space', '新建 Space')}</span><span className="text-[11px] text-zinc-600">{batch?.events.length ?? 0} {t('events', '个事件')}</span></div>
          <div className="mt-2 flex flex-wrap gap-1.5">{presence.length === 0 ? <span className="text-[11px] text-zinc-600">{t('No one else is online yet.', '暂时没有其他协作者在线。')}</span> : presence.map((person) => <span key={person.id} className="rounded-full bg-emerald-950/60 px-2 py-1 text-[11px] text-emerald-200">● {person.displayName}</span>)}</div>
          <form className="mt-3 flex gap-2" onSubmit={(event) => { event.preventDefault(); onCreate() }}><input aria-label={t('New shared space name', '新共享工作区名称')} value={newSpaceName} onChange={(event) => onNameChange(event.target.value)} placeholder={t('Space name', 'Space 名称')} className="min-w-0 flex-1 rounded-md border border-zinc-700 bg-zinc-950 px-2.5 py-1.5 text-xs outline-none ring-violet-500 focus:ring-1" /><button type="submit" disabled={creating || newSpaceName.trim() === ''} className="rounded-md bg-violet-600 px-2.5 py-1.5 text-xs font-medium text-white disabled:opacity-40">{creating ? t('Creating…', '创建中…') : t('Create', '创建')}</button></form>
        </div>
      </div>
    </section>
  )
}

function ProjectPresenceRow({ project, tasks, agents, language }: { project: Project; tasks: Task[]; agents: Agent[]; language: 'en' | 'zh-Hans' }) {
  const t = (english: string, simplifiedChinese: string) => text(language, english, simplifiedChinese)
  const projectTasks = tasks.filter((task) => task.projectID === project.id)
  const activeCount = projectTasks.filter((task) => ['running', 'blocked', 'ready'].includes(task.status)).length
  const names = [...new Set(projectTasks.flatMap((task) => {
    const agent = agents.find((candidate) => candidate.id === task.assignedAgentIdentityID)
    return agent === undefined ? [] : [agent.displayName]
  }))]
  return <Link to={`/projects?project=${project.id}`} className="mu-list-row"><span className="mu-icon-chip mu-icon-violet text-xs">⌂</span><span className="min-w-0 flex-1"><span className="block truncate font-medium text-zinc-200">{project.displayName}</span><span className="mt-0.5 block truncate text-[11px] text-zinc-500">{activeCount} {t('active', '活跃')} · {projectTasks.length} {t('conversations', '条对话')}{names.length > 0 ? ` · ${names.join(', ')}` : ''}</span></span><span className="text-zinc-600">›</span></Link>
}

function AgentPresenceRow({ agent, taskCount, language }: { agent: Agent; taskCount: number; language: 'en' | 'zh-Hans' }) {
  const t = (english: string, simplifiedChinese: string) => text(language, english, simplifiedChinese)
  return <div className="flex items-center gap-3 rounded-lg border border-zinc-800/80 px-3 py-2"><span className="h-2.5 w-2.5 rounded-full" style={{ backgroundColor: agent.accentHex }} /><span className="min-w-0 flex-1"><span className="block truncate text-sm text-zinc-200">{agent.displayName}</span><span className="block truncate text-[11px] text-zinc-500">{agent.role} · {taskCount} {t('active Task', '个活跃任务')}{taskCount === 1 ? '' : t('s', '')}</span></span><span className="text-xs text-emerald-300">{agent.availability}</span></div>
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
