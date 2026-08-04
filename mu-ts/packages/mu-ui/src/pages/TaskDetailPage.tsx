import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useParams } from 'react-router'
import { api, type ContextRecord, type Endpoint, type ExternalConversationCandidate, type LedgerEvent, type RunRecord } from '../api.ts'
import { useCollaborationSpace, type SpaceSyncBatch } from '../collaboration.ts'
import { useMuUISettings, useQuery, useSSE } from '../hooks.ts'
import { statusText, text } from '../i18n.ts'
import { ErrorBanner } from './ProjectsPage.tsx'

const EFFORTS = [
  { value: 'auto', label: 'Auto', hint: 'Route from task shape' },
  { value: 'medium', label: 'Medium', hint: 'Short bounded work' },
  { value: 'high', label: 'High', hint: 'Multi-step implementation' },
  { value: 'ultra', label: 'Ultra', hint: 'Architecture or risky changes' },
] as const

const SURFACES = [
  { value: 'chat', label: 'Chat' },
  { value: 'files', label: 'Files' },
  { value: 'browser', label: 'Browser' },
  { value: 'terminal', label: 'Terminal' },
  { value: 'artifacts', label: 'Review' },
] as const

/** Workspace for one task: chat + live stream + endpoint/context inspector. */
export function TaskDetailPage() {
  const { id = '' } = useParams()
  const { settings } = useMuUISettings()
  const t = (english: string, simplifiedChinese: string) => text(settings.language, english, simplifiedChinese)
  const { data: task, error } = useQuery(() => api.fetchTask(id), [id])
  const { data: chat, reload: reloadChat } = useQuery(() => api.listChat(id), [id])
  const { data: runs, reload: reloadRuns } = useQuery(() => api.listRuns(id), [id])
  const { data: artifacts, reload: reloadArtifacts } = useQuery(() => api.listArtifacts(id), [id])
  const { data: ledger, reload: reloadLedger } = useQuery(() => api.listLedger(id), [id])
  const { data: contexts, reload: reloadContexts } = useQuery(() => api.listContext(id), [id])
  const { data: endpointData } = useQuery(() => api.listEndpoints())
  const sse = useSSE(150)
  const [input, setInput] = useState('')
  const [sending, setSending] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | undefined>()
  const [selectedEndpointID, setSelectedEndpointID] = useState('')
  const [surface, setSurface] = useState<(typeof SURFACES)[number]['value']>('chat')
  const [toolsOpen, setToolsOpen] = useState(false)
  const [environmentOpen, setEnvironmentOpen] = useState(false)
  const [effort, setEffort] = useState('auto')
  const [selectedContextIDs, setSelectedContextIDs] = useState<string[]>([])
  const [streamingText, setStreamingText] = useState('')
  const [liveActivities, setLiveActivities] = useState<ActivityItem[]>([])
  const [activityOpen, setActivityOpen] = useState(true)
  const [historyOpen, setHistoryOpen] = useState(false)
  const [historyLoading, setHistoryLoading] = useState(false)
  const [historyError, setHistoryError] = useState<string | undefined>()
  const [history, setHistory] = useState<ExternalConversationCandidate[]>([])
  const [hydratingID, setHydratingID] = useState<string | undefined>()
  const chatEndRef = useRef<HTMLDivElement>(null)
  const seenActivityIDs = useRef(new Set<string>())

  const endpoints = endpointData?.endpoints ?? []
  const currentTask = task?.task
  const sharedRoom = useCollaborationSpace(currentTask?.workspaceID ?? currentTask?.projectID)
  const running = runs?.runs.some((run) => ['starting', 'active'].includes(run.state)) === true
  const latestRun = runs?.runs[0]
  const runnableEndpoints = useMemo(
    () => endpoints.filter((endpoint) => endpoint.status === 'active'),
    [endpoints],
  )
  const effectiveEndpointID = selectedEndpointID
    || currentTask?.currentEndpointID
    || endpoints.find((endpoint) => endpoint.status === 'active')?.id
    || endpoints[0]?.id
    || ''
  const effectiveEndpoint = endpoints.find((endpoint) => endpoint.id === effectiveEndpointID)
  const autoEffort = inferEffort(currentTask?.title ?? '', currentTask?.objective ?? '')
  const activityItems = useMemo(
    () => mergeActivityItems(ledger?.events ?? [], liveActivities),
    [ledger?.events, liveActivities],
  )

  useEffect(() => {
    const current = endpoints.find((endpoint) => endpoint.id === currentTask?.currentEndpointID)
    const fallback = current ?? runnableEndpoints[0] ?? endpoints[0]
    if ((selectedEndpointID === '' || !endpoints.some((endpoint) => endpoint.id === selectedEndpointID)) && fallback !== undefined) {
      setSelectedEndpointID(fallback.id)
    }
  }, [currentTask?.currentEndpointID, endpoints, runnableEndpoints, selectedEndpointID])

  useEffect(() => {
    if (contexts?.records === undefined) return
    setSelectedContextIDs(contexts.records.filter((record) => record.status === 'accepted').map((record) => record.id))
  }, [contexts?.records])

  // Poll as a fallback, and use SSE visible-text deltas for responsive chat.
  useEffect(() => {
    if (!running) return
    const timer = setInterval(() => {
      reloadChat()
      reloadRuns()
      reloadArtifacts()
      reloadLedger()
    }, 900)
    return () => clearInterval(timer)
  }, [running, reloadArtifacts, reloadChat, reloadLedger, reloadRuns])

  useEffect(() => {
    const latest = sse[sse.length - 1]
    if (latest === undefined) return
    const payload = latest.data as { taskID?: string; event?: { kind?: string; text?: string; activity?: RuntimeActivityPayload } } | null
    if (payload?.taskID !== id) return
    if (latest.event === 'turn_event' && payload.event?.kind === 'visible_text' && payload.event.text !== undefined) {
      setStreamingText((current) => current + payload.event!.text)
      reloadChat()
    }
    if (latest.event === 'turn_ended' || latest.event === 'turn_error') {
      setStreamingText('')
      reloadChat()
      reloadRuns()
      reloadArtifacts()
      reloadLedger()
    }
  }, [id, reloadArtifacts, reloadChat, reloadLedger, reloadRuns, sse])

  useEffect(() => {
    for (const envelope of sse) {
      if (envelope.event !== 'turn_event') continue
      const payload = envelope.data as { taskID?: string; event?: { kind?: string; activity?: RuntimeActivityPayload } } | null
      if (payload?.taskID !== id || payload.event?.kind !== 'activity' || payload.event.activity === undefined) continue
      const activity = payload.event.activity
      const activityID = `${activity.id ?? activity.phase}:${activity.status}:${activity.title}`
      if (seenActivityIDs.current.has(activityID)) continue
      seenActivityIDs.current.add(activityID)
      setLiveActivities((current) => [...current, activityItemFromRuntime(activity, activityID)])
    }
  }, [id, sse])

  useEffect(() => {
    setLiveActivities([])
    seenActivityIDs.current = new Set<string>()
  }, [id])

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [chat?.entries.length, streamingText])

  async function send(): Promise<void> {
    const text = input.trim()
    if (text === '' || sending || currentTask === undefined) return
    setSending(true)
    setErrorMessage(undefined)
    setStreamingText('')
    try {
      await api.startTurn(id, text, {
        endpointID: effectiveEndpointID || undefined,
        contextRecordIDs: selectedContextIDs,
        reasoningEffort: effort,
      })
      setInput('')
      reloadChat()
      reloadRuns()
    } catch (reason) {
      setErrorMessage(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setSending(false)
    }
  }

  async function interrupt(): Promise<void> {
    const activeRun = runs?.runs.find((run) => ['starting', 'active'].includes(run.state))
    if (activeRun === undefined) return
    try {
      await api.interruptRun(id, activeRun.id)
      reloadRuns()
    } catch (reason) {
      setErrorMessage(reason instanceof Error ? reason.message : String(reason))
    }
  }

  async function acceptContext(record: ContextRecord): Promise<void> {
    try {
      if (record.status === 'candidate') {
        await api.reviewContext(record.id, 'accepted')
        reloadContexts()
      }
      setSelectedContextIDs((current) => current.includes(record.id) ? current.filter((idValue) => idValue !== record.id) : [...current, record.id])
    } catch (reason) {
      setErrorMessage(reason instanceof Error ? reason.message : String(reason))
    }
  }

  async function discoverHistory(): Promise<void> {
    if (effectiveEndpointID === '') return
    setHistoryLoading(true)
    setHistoryError(undefined)
    try {
      const result = await api.discoverHistory(effectiveEndpointID, currentTask?.repositoryPath ?? '')
      setHistory(result.conversations)
    } catch (reason) {
      setHistoryError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setHistoryLoading(false)
    }
  }

  async function hydrate(candidate: ExternalConversationCandidate): Promise<void> {
    setHydratingID(candidate.nativeSessionID)
    setHistoryError(undefined)
    try {
      const result = await api.hydrateHistory(effectiveEndpointID, candidate)
      setHistory((current) => current.map((item) => item.nativeSessionID === candidate.nativeSessionID ? result.conversation : item))
    } catch (reason) {
      setHistoryError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setHydratingID(undefined)
    }
  }

  async function importConversation(candidate: ExternalConversationCandidate): Promise<void> {
    if (currentTask?.projectID === undefined || candidate.messages.length === 0) return
    const text = candidate.messages.map((message) => `${message.role === 'user' ? 'User' : 'Agent'}: ${message.text}`).join('\n\n')
    try {
      const imported = await api.importContext({
        projectID: currentTask.projectID,
        taskID: id,
        kind: 'fact',
        subject: candidate.title,
        text,
        externalRef: candidate.nativeSessionID,
        runtimeEndpointID: effectiveEndpointID || undefined,
        runtimeSessionID: candidate.nativeSessionID,
      })
      await api.reviewContext(imported.record.id, 'accepted')
      reloadContexts()
    } catch (reason) {
      setHistoryError(reason instanceof Error ? reason.message : String(reason))
    }
  }

  return (
    <div className="mx-auto max-w-[1440px] p-4 md:p-6">
      <div className="mb-5 flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="mb-1 text-xs uppercase tracking-[0.18em] text-zinc-600">{t('Project workspace', 'Project 工作区')}</div>
          <h1 className="truncate text-2xl font-semibold tracking-tight text-zinc-100">{currentTask?.title ?? t('Task', '任务')}</h1>
          <p className="mt-1 max-w-3xl text-sm leading-6 text-zinc-400">{currentTask?.objective}</p>
          <p className="mt-1 truncate font-mono text-xs text-zinc-600">{currentTask?.repositoryPath}</p>
        </div>
        <div className="flex items-center gap-2 rounded-xl border border-zinc-800 bg-zinc-900/80 p-2">
          <span className={`h-2.5 w-2.5 rounded-full ${running ? 'animate-pulse bg-blue-400' : 'bg-zinc-600'}`} />
          <span className="text-xs text-zinc-400">{running ? t('Working', '工作中') : currentTask?.status === undefined ? t('Loading', '加载中') : statusText(settings.language, currentTask.status)}</span>
        </div>
      </div>
      {error !== undefined && <ErrorBanner message={error} />}
      {errorMessage !== undefined && <ErrorBanner message={errorMessage} />}

      <div className="relative mb-4 flex flex-wrap items-center gap-1 rounded-xl border border-zinc-800 bg-zinc-900/70 p-1.5">
        <button type="button" onClick={() => setSurface('chat')} className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition ${surface === 'chat' ? 'bg-violet-500/15 text-violet-200' : 'text-zinc-500 hover:bg-zinc-800 hover:text-zinc-200'}`}>{t('Chat', '聊天')}</button>
        <button type="button" onClick={() => setToolsOpen((current) => !current)} className="rounded-lg px-3 py-1.5 text-xs font-semibold text-zinc-400 transition hover:bg-zinc-800 hover:text-zinc-200">{t('Tools', '工具')} ▾</button>
        {toolsOpen && <div className="absolute left-1 top-11 z-20 w-44 rounded-xl border border-zinc-700 bg-zinc-900 p-1.5 shadow-2xl"><div className="px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.15em] text-zinc-600">{t('Workspace tools', '工作区工具')}</div>{SURFACES.filter((item) => item.value !== 'chat').map((item) => <button key={item.value} type="button" onClick={() => { setSurface(item.value); setToolsOpen(false) }} className="block w-full rounded-lg px-2 py-1.5 text-left text-xs text-zinc-300 hover:bg-zinc-800">{surfaceText(settings.language, item.value)}</button>)}<div className="my-1 border-t border-zinc-800" /><button type="button" onClick={() => { setEnvironmentOpen(true); setToolsOpen(false) }} className="block w-full rounded-lg px-2 py-1.5 text-left text-xs text-zinc-300 hover:bg-zinc-800">{t('Environment', '环境')}</button></div>}
        <button type="button" onClick={() => setEnvironmentOpen((current) => !current)} className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition ${environmentOpen ? 'bg-violet-500/15 text-violet-200' : 'text-zinc-500 hover:bg-zinc-800 hover:text-zinc-200'}`}>{environmentOpen ? t('Hide Environment', '隐藏环境') : t('Environment', '环境')}</button>
        <span className="ml-auto truncate px-2 font-mono text-[10px] text-zinc-600">{currentTask?.repositoryPath}</span>
      </div>

      <div className={`grid gap-4 ${environmentOpen ? 'xl:grid-cols-[minmax(0,1fr)_22rem]' : ''}`}>
        {surface === 'chat' ? <section className="flex min-h-[calc(100vh-12rem)] flex-col rounded-xl border border-zinc-800 bg-zinc-900/50">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-800 px-4 py-3">
            <div className="flex min-w-0 items-center gap-2">
              <span className="text-sm font-semibold text-zinc-200">{t('Workspace chat', '工作区聊天')}</span>
              {effectiveEndpoint !== undefined && <span className="rounded-full bg-violet-950 px-2 py-0.5 text-[11px] text-violet-200">{t('Selected', '已选择')}：{endpointLabel(effectiveEndpoint)}</span>}
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <button onClick={() => void interrupt()} disabled={!running} className="rounded-md bg-red-950/70 px-2.5 py-1 text-xs text-red-200 transition hover:bg-red-900 disabled:opacity-30">{t('Interrupt', '中断')}</button>
            </div>
          </div>

          <div className="flex-1 space-y-4 overflow-y-auto p-4">
            {activityItems.length > 0 && <RuntimeActivityTimeline items={activityItems} open={activityOpen} onToggle={() => setActivityOpen((current) => !current)} running={running} />}
            {chat?.entries.map((entry) => (
              <div key={entry.id} className={entry.authorKind === 'user' ? 'text-right' : ''}>
                <div className="text-[11px] text-zinc-500">{entry.authorName}</div>
                <div className={`mt-1 inline-block max-w-[92%] rounded-xl px-3 py-2 text-left text-sm leading-6 ${entry.authorKind === 'user' ? 'bg-blue-700/40 text-blue-50' : 'bg-zinc-800/90 text-zinc-100'}`}>
                  {entry.authorKind === 'agent' ? <MarkdownMessage text={entry.text} /> : <span className="whitespace-pre-wrap">{entry.text}</span>}
                </div>
              </div>
            ))}
            {streamingText !== '' && (
              <div>
                <div className="text-[11px] text-blue-300">{effectiveEndpoint?.displayName ?? 'Agent'} · {t('streaming', '流式输出')}</div>
                <div className="mt-1 inline-block max-w-[92%] rounded-xl border border-blue-900/70 bg-blue-950/30 px-3 py-2 text-sm leading-6 text-zinc-100"><MarkdownMessage text={streamingText} /></div>
              </div>
            )}
            {chat?.entries.length === 0 && streamingText === '' && <div className="py-12 text-center text-sm text-zinc-600">{settings.language === 'zh-Hans' ? '还没有消息。点击下方 Runtime 选择执行对象，然后发送第一条消息。' : 'No messages yet. Choose a Runtime below, then send the first turn.'}</div>}
            <div ref={chatEndRef} />
          </div>

          <div className="border-t border-zinc-800 p-3">
            <div className="mb-3 rounded-lg border border-violet-900/60 bg-violet-950/20 px-3 py-2 text-xs leading-5 text-violet-100">
              {settings.language === 'zh-Hans'
                ? '点击下方 Runtime 选择当前执行对象，再发送消息。Runtime 在 Agents 页面配置；底部齿轮也可打开设置。没有可用 Runtime 时，请先完成配置和检查。'
                : 'Click a Runtime below to choose where this message runs. Configure runtimes in Agents; the bottom gear opens Settings. A Runtime must be active before sending.'}
            </div>
            <div className="mb-3 flex flex-wrap items-center gap-2 rounded-lg border border-zinc-800 bg-zinc-950/40 px-3 py-2">
              <span className="mr-1 text-[11px] font-semibold uppercase tracking-[0.14em] text-zinc-500">Runtime</span>
              {runnableEndpoints.map((endpoint) => {
                const selected = endpoint.id === effectiveEndpointID
                return <button key={endpoint.id} type="button" onClick={() => setSelectedEndpointID(endpoint.id)} className={`flex max-w-full items-center gap-2 rounded-full border px-3 py-1.5 text-xs transition ${selected ? 'border-violet-500/60 bg-violet-500/20 text-violet-100' : 'border-zinc-700 bg-zinc-900 text-zinc-400 hover:border-zinc-500 hover:text-zinc-200'}`} title={endpointLabel(endpoint)}><span className={`h-1.5 w-1.5 shrink-0 rounded-full ${selected ? 'bg-violet-300' : 'bg-emerald-400'}`} /><span className="max-w-64 truncate">{endpointLabel(endpoint)}</span><span className="text-[10px] opacity-70">{surfaceLabel(endpoint.instanceIdentity?.surfaceKind)}</span></button>
              })}
              {runnableEndpoints.length === 0 && <span className="text-xs text-zinc-600">{t('Configure and check a Runtime in Agents first.', '请先在 Agents 中配置并检查 Runtime。')}</span>}
              <span className="ml-auto text-[11px] text-zinc-600">{t('Click to select · no @ needed', '点击选择 · 无需 @')}</span>
            </div>
            <div className="mb-2 flex flex-wrap items-center gap-2 text-xs">
              <span className="text-zinc-500">{t('Reasoning', '思考强度')}</span>
              {EFFORTS.map((option) => (
                <button key={option.value} type="button" title={option.hint} onClick={() => setEffort(option.value)} className={`rounded-full px-2.5 py-1 transition ${effort === option.value ? 'bg-violet-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}`}>
                  {effortText(settings.language, option.value)}{option.value === 'auto' && <span className="ml-1 text-[10px] opacity-70">({autoEffort})</span>}
                </button>
              ))}
              <span className="ml-auto text-zinc-600">{selectedContextIDs.length} context item{selectedContextIDs.length === 1 ? '' : 's'} selected</span>
            </div>
            <div className="flex gap-2">
              <textarea
                value={input}
                onChange={(event) => setInput(event.target.value)}
                onKeyDown={(event) => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); void send() } }}
                placeholder={settings.language === 'zh-Hans' ? '输入消息；先点击下方 Runtime 选择执行对象' : 'Message the workspace… click a Runtime below to choose where it runs'}
                rows={2}
                className="min-h-11 flex-1 resize-none rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm outline-none ring-blue-500 focus:ring-1"
              />
              <button onClick={() => void send()} disabled={sending || input.trim() === '' || effectiveEndpointID === '' || effectiveEndpoint?.status !== 'active'} title={effectiveEndpointID !== '' && effectiveEndpoint?.status === 'active' ? undefined : t('Configure and check a Runtime in Agents first.', '请先在 Agents 中配置并检查 Runtime。')} className="self-end rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-500 disabled:opacity-40">{sending ? t('Starting…', '启动中…') : t('Run', '执行')}</button>
            </div>
          </div>
        </section> : <WorkspaceSurfacePlaceholder surface={surface} repositoryPath={currentTask?.repositoryPath} artifacts={artifacts?.artifacts ?? []} />}

        {environmentOpen && <aside className="space-y-3">
          <RuntimeCard endpoint={effectiveEndpoint} latestRun={latestRun} />
          <SharedRoomCard batch={sharedRoom.batch} connected={sharedRoom.connected} taskID={id} language={settings.language} />
          <ContextPanel records={contexts?.records ?? []} selectedIDs={selectedContextIDs} onToggle={(record) => void acceptContext(record)} />
          <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
            <div className="flex items-center justify-between">
              <div>
                <h2 className="text-sm font-semibold text-zinc-200">Imported history</h2>
                <p className="mt-1 text-xs text-zinc-500">Read-only conversations from the selected endpoint.</p>
              </div>
              <button type="button" onClick={() => { setHistoryOpen((open) => !open); if (!historyOpen) void discoverHistory() }} className="rounded-md bg-zinc-800 px-2.5 py-1 text-xs text-zinc-300 hover:bg-zinc-700">{historyOpen ? 'Hide' : 'Find history'}</button>
            </div>
            {historyOpen && (
              <div className="mt-3 space-y-2 border-t border-zinc-800 pt-3">
                {historyLoading && <ProgressBar label="Scanning endpoint history…" />}
                {historyError !== undefined && <div className="rounded-md bg-red-950/40 px-2 py-2 text-xs text-red-200">{historyError}</div>}
                {!historyLoading && history.length === 0 && historyError === undefined && <div className="text-xs text-zinc-600">No conversations found for this workspace.</div>}
                {history.map((candidate) => <HistoryCard key={candidate.nativeSessionID} candidate={candidate} hydrating={hydratingID === candidate.nativeSessionID} onHydrate={() => void hydrate(candidate)} onImport={() => void importConversation(candidate)} />)}
              </div>
            )}
          </div>
          <RunsPanel runs={runs?.runs ?? []} endpoints={endpoints} />
          <MiniPanel title="Artifacts" empty={artifacts?.artifacts.length === 0}>{artifacts?.artifacts.map((artifact) => <div key={artifact.id} className="flex justify-between gap-2 text-xs"><span className="truncate font-mono text-zinc-400">{artifact.relativePath}</span><span className="shrink-0 text-zinc-600">{artifact.byteCount} B</span></div>)}</MiniPanel>
        </aside>}
      </div>
    </div>
  )
}

interface RuntimeActivityPayload {
  readonly id?: string
  readonly phase?: string
  readonly status?: string
  readonly title?: string
  readonly detail?: string
  readonly toolName?: string
  readonly path?: string
  readonly command?: string
  readonly requestID?: string
  readonly artifactID?: string
}

interface ActivityItem {
  readonly id: string
  readonly title: string
  readonly detail?: string
  readonly phase: string
  readonly status: string
  readonly occurredAt: string
  readonly payload?: RuntimeActivityPayload
  readonly live?: boolean
}

function mergeActivityItems(events: readonly LedgerEvent[], live: readonly ActivityItem[]): ActivityItem[] {
  const items = events
    .filter((event) => event.type === 'runtime.activity' || event.type === 'task.approval_requested' || event.type.startsWith('task.run_') || event.type.startsWith('artifact.'))
    .map(activityItemFromLedger)
  const byID = new Map<string, ActivityItem>()
  for (const item of [...items, ...live]) byID.set(item.id, item)
  return [...byID.values()]
    .sort((left, right) => left.occurredAt.localeCompare(right.occurredAt))
    .slice(-120)
}

function activityItemFromLedger(event: LedgerEvent): ActivityItem {
  const payload = event.payload ?? {}
  const phase = payload.phase ?? (event.type === 'task.approval_requested' ? 'authorization' : event.type.startsWith('artifact.') ? 'artifact' : 'status')
  const status = payload.status ?? (event.type.endsWith('failed') ? 'failed' : event.type.endsWith('blocked') ? 'blocked' : event.type.endsWith('completed') ? 'completed' : 'updated')
  const detail = payload.detail ?? payload.command ?? payload.path
  return {
    id: event.id,
    title: event.summary,
    detail,
    phase,
    status,
    occurredAt: event.occurredAt,
    payload,
  }
}

function activityItemFromRuntime(activity: RuntimeActivityPayload, id: string): ActivityItem {
  return {
    id,
    title: activity.title ?? 'Agent activity',
    detail: activity.detail ?? activity.command ?? activity.path,
    phase: activity.phase ?? 'status',
    status: activity.status ?? 'updated',
    occurredAt: new Date().toISOString(),
    payload: activity,
    live: true,
  }
}

function RuntimeActivityTimeline({ items, open, onToggle, running }: { items: readonly ActivityItem[]; open: boolean; onToggle: () => void; running: boolean }) {
  return <section className="rounded-xl border border-blue-900/50 bg-blue-950/10 p-3" aria-label="Agent activity timeline">
    <button type="button" onClick={onToggle} className="flex w-full items-center gap-2 text-left">
      <span className={`text-blue-300 transition ${open ? 'rotate-90' : ''}`}>›</span>
      <span className={`h-2 w-2 rounded-full ${running ? 'animate-pulse bg-blue-400' : 'bg-zinc-500'}`} />
      <span className="text-xs font-semibold text-zinc-200">Agent activity</span>
      <span className="text-[10px] text-zinc-500">{items.length} events · visible receipts only</span>
      <span className="ml-auto text-[10px] text-zinc-600">{open ? 'Collapse' : 'Expand'}</span>
    </button>
    {open && <div className="mt-3 ml-1 border-l border-blue-900/60 pl-3">
      <div className="space-y-1.5">
        {items.map((item, index) => <details key={`${item.id}-${index}`} open={item.live === true && index === items.length - 1} className="group rounded-lg border border-transparent px-2 py-1.5 transition hover:border-zinc-800 hover:bg-zinc-950/40">
          <summary className="flex cursor-pointer list-none items-center gap-2 text-xs text-zinc-300 [&::-webkit-details-marker]:hidden">
            <span className="w-5 text-center text-sm text-zinc-500">{activityIcon(item.phase)}</span>
            <span className="min-w-0 flex-1 truncate">{item.title}</span>
            <span className={`shrink-0 rounded-full px-1.5 py-0.5 text-[9px] ${activityStatusClass(item.status)}`}>{item.status}</span>
            <time className="shrink-0 text-[10px] text-zinc-600">{formatActivityTime(item.occurredAt)}</time>
            <span className="text-[10px] text-zinc-600 transition group-open:rotate-90">›</span>
          </summary>
          {(item.detail !== undefined || item.payload?.toolName !== undefined || item.payload?.requestID !== undefined || item.payload?.artifactID !== undefined) && <div className="ml-7 mt-1 space-y-1 text-[11px] leading-5 text-zinc-500">
            {item.detail !== undefined && <div className="whitespace-pre-wrap break-words">{item.detail}</div>}
            {item.payload?.toolName !== undefined && <div><span className="text-zinc-600">Tool </span><code className="font-mono text-zinc-400">{item.payload.toolName}</code></div>}
            {item.payload?.requestID !== undefined && <div><span className="text-zinc-600">Request </span><code className="font-mono text-zinc-400">{item.payload.requestID}</code></div>}
            {item.payload?.artifactID !== undefined && <div><span className="text-zinc-600">Artifact </span><code className="font-mono text-zinc-400">{item.payload.artifactID}</code></div>}
          </div>}
        </details>)}
      </div>
    </div>}
  </section>
}

function activityIcon(phase: string): string {
  if (phase === 'file') return '▧'
  if (phase === 'tool') return '⌘'
  if (phase === 'authorization') return '⚿'
  if (phase === 'artifact') return '◇'
  if (phase === 'thinking') return '◌'
  return '·'
}

function activityStatusClass(status: string): string {
  if (status === 'completed') return 'bg-emerald-950 text-emerald-300'
  if (status === 'blocked') return 'bg-amber-950 text-amber-300'
  if (status === 'failed') return 'bg-red-950 text-red-300'
  if (status === 'started' || status === 'updated') return 'bg-blue-950 text-blue-300'
  return 'bg-zinc-800 text-zinc-500'
}

function effortText(language: 'en' | 'zh-Hans', value: string): string {
  const labels: Record<string, [string, string]> = {
    auto: ['Auto', '自动'],
    medium: ['Medium', '中等'],
    high: ['High', '高'],
    ultra: ['Ultra', '极高'],
  }
  const label = labels[value]
  return label === undefined ? value : text(language, label[0], label[1])
}

function surfaceText(language: 'en' | 'zh-Hans', value: string): string {
  const labels: Record<string, [string, string]> = {
    files: ['Files', '文件'],
    browser: ['Browser', '浏览器'],
    terminal: ['Terminal', '终端'],
    artifacts: ['Review', '产物'],
  }
  const label = labels[value]
  return label === undefined ? value : text(language, label[0], label[1])
}

function formatActivityTime(value: string): string {
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '' : date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

function WorkspaceSurfacePlaceholder({ surface, repositoryPath, artifacts }: { surface: (typeof SURFACES)[number]['value']; repositoryPath?: string; artifacts: readonly { relativePath: string; byteCount: number }[] }) {
  const title = SURFACES.find((item) => item.value === surface)?.label ?? surface
  if (surface === 'artifacts') {
    return <section className="mu-panel min-h-[calc(100vh-12rem)]"><h2 className="text-sm font-semibold text-zinc-200">Artifacts</h2><p className="mt-1 text-xs text-zinc-500">Reviewable outputs published by the current Run.</p><div className="mt-5 space-y-2">{artifacts.map((artifact) => <div key={artifact.relativePath} className="flex items-center justify-between gap-3 rounded-lg border border-zinc-800 bg-zinc-950/40 px-3 py-2 text-xs"><span className="truncate font-mono text-zinc-300">{artifact.relativePath}</span><span className="shrink-0 text-zinc-600">{artifact.byteCount} B</span></div>)}{artifacts.length === 0 && <div className="text-xs text-zinc-600">No artifacts yet.</div>}</div></section>
  }
  return <section className="mu-panel flex min-h-[calc(100vh-12rem)] flex-col items-center justify-center text-center"><div className="mu-icon-chip mu-icon-violet text-lg">●</div><h2 className="mt-4 text-sm font-semibold text-zinc-200">{title}</h2><p className="mt-2 max-w-sm text-xs leading-5 text-zinc-500">{surface === 'files' ? `Read-only workspace tree for ${repositoryPath ?? 'this Project'}.` : surface === 'terminal' ? 'Terminal control remains endpoint-scoped; use Workspace Chat to route a bounded turn.' : 'Browser surface is available when a compatible local runtime exposes it.'}</p></section>
}

function RuntimeCard({ endpoint, latestRun }: { endpoint?: Endpoint; latestRun?: RunRecord }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
      <div className="mb-2 text-[11px] font-semibold uppercase tracking-[0.16em] text-zinc-500">Runtime boundary</div>
      {endpoint === undefined ? <div className="text-sm text-zinc-600">No endpoint available.</div> : (
        <>
          <div className="flex items-center gap-2"><span className={`h-2 w-2 rounded-full ${endpoint.status === 'active' ? 'bg-emerald-400' : 'bg-amber-400'}`} /><span className="font-medium text-zinc-200">{endpoint.displayName}</span></div>
          <div className="mt-2 grid grid-cols-2 gap-2 text-[11px] text-zinc-500"><span>Surface</span><span className="text-right text-zinc-300">{surfaceLabel(endpoint.instanceIdentity?.surfaceKind)}</span><span>Instance</span><span className="truncate text-right font-mono text-zinc-400" title={endpoint.instanceIdentity?.stableInstanceKey}>{endpoint.instanceIdentity?.instanceLabel ?? endpoint.instanceIdentity?.terminalIdentifier ?? 'default'}</span></div>
          {latestRun?.contextPackID !== undefined && <div className="mt-3 rounded-md border border-emerald-900/60 bg-emerald-950/30 px-2 py-2 text-xs text-emerald-200">Context Pack delivered · {shortID(latestRun.contextPackID)}</div>}
        </>
      )}
    </div>
  )
}

function SharedRoomCard({ batch, connected, taskID, language }: { batch: SpaceSyncBatch | undefined; connected: boolean; taskID: string; language: 'en' | 'zh-Hans' }) {
  const t = (english: string, simplifiedChinese: string) => text(language, english, simplifiedChinese)
  const messages = (batch?.events ?? []).filter((event) => event.eventType === 'thread.message' && event.payload.taskID === taskID).slice(-8)
  return <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
    <div className="flex items-center justify-between gap-2"><h2 className="text-sm font-semibold text-zinc-200">{t('Shared room', '共享房间')}</h2><span className={`rounded-full px-1.5 py-0.5 text-[10px] ${connected ? 'bg-emerald-950 text-emerald-300' : 'bg-zinc-800 text-zinc-500'}`}>{connected ? t('Live', '实时') : t('Offline', '离线')}</span></div>
    <p className="mt-1 text-[11px] leading-4 text-zinc-500">{t('People and Agents in this Project see the same ordered thread events.', '这个 Project 中的人和 Agent 会看到同一组有序 thread 事件。')}</p>
    <div className="mt-2 flex flex-wrap gap-1.5">{batch?.presence.map((person) => <span key={person.id} className="rounded-full bg-emerald-950/60 px-1.5 py-0.5 text-[10px] text-emerald-200">● {person.displayName}</span>)}</div>
    <div className="mt-3 space-y-2 border-t border-zinc-800 pt-3">{messages.map((event) => <div key={event.id} className="rounded-lg bg-zinc-950/45 px-2.5 py-2"><div className="text-[10px] text-zinc-500">{event.payload.authorName ?? t('Participant', '参与者')}</div><div className="mt-1 text-[11px] leading-4 text-zinc-300"><MarkdownMessage text={event.payload.text ?? ''} /></div></div>)}{messages.length === 0 && <div className="text-[11px] text-zinc-600">{t('No shared messages for this thread yet.', '这个 thread 还没有共享消息。')}</div>}</div>
  </div>
}

function ContextPanel({ records, selectedIDs, onToggle }: { records: ContextRecord[]; selectedIDs: string[]; onToggle: (record: ContextRecord) => void }) {
  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
      <div className="flex items-center justify-between"><h2 className="text-sm font-semibold text-zinc-200">Context Pack</h2><span className="text-xs text-zinc-500">{selectedIDs.length} selected</span></div>
      <p className="mt-1 text-xs leading-5 text-zinc-500">Choose accepted records for the next turn. They remain separate from live chat.</p>
      <div className="mt-3 space-y-2">
        {records.map((record) => {
          const selected = selectedIDs.includes(record.id)
          const value = contextValue(record)
          return <button key={record.id} type="button" onClick={() => onToggle(record)} className={`w-full rounded-lg border px-3 py-2 text-left transition ${selected ? 'border-violet-800 bg-violet-950/30' : 'border-zinc-800 bg-zinc-950/40 hover:border-zinc-700'}`}>
            <div className="flex items-center gap-2"><span className={`h-2 w-2 rounded-full ${selected ? 'bg-violet-400' : 'bg-zinc-600'}`} /><span className="min-w-0 flex-1 truncate text-xs font-medium text-zinc-200">{record.subject ?? 'Untitled context'}</span><span className="text-[10px] text-zinc-600">{record.status}</span></div>
            <div className="mt-1 line-clamp-2 text-[11px] leading-4 text-zinc-500">{value}</div>
          </button>
        })}
        {records.length === 0 && <div className="text-xs text-zinc-600">No imported context yet.</div>}
      </div>
    </div>
  )
}

function HistoryCard({ candidate, hydrating, onHydrate, onImport }: { candidate: ExternalConversationCandidate; hydrating: boolean; onHydrate: () => void; onImport: () => void }) {
  const ready = candidate.messages.length > 0
  return <div className="rounded-lg border border-zinc-800 bg-zinc-950/50 p-3"><div className="flex items-start gap-2"><div className="min-w-0 flex-1"><div className="truncate text-xs font-medium text-zinc-200">{candidate.title || candidate.nativeSessionID}</div><div className="mt-1 text-[10px] text-zinc-600">{candidate.provider.rawValue} · {candidate.discoveredMessageCount ?? 0} messages · {candidate.resumability}</div></div><span className="rounded bg-zinc-800 px-1.5 py-0.5 text-[10px] text-zinc-500">read-only</span></div><div className="mt-2 flex gap-2"><button type="button" onClick={onHydrate} disabled={hydrating} className="rounded-md bg-zinc-800 px-2 py-1 text-[11px] text-zinc-300 hover:bg-zinc-700 disabled:opacity-40">{hydrating ? 'Hydrating…' : ready ? 'Refresh' : 'Hydrate'}</button>{ready && <button type="button" onClick={onImport} className="rounded-md bg-violet-700 px-2 py-1 text-[11px] text-white hover:bg-violet-600">Import selected</button>}</div>{ready && <div className="mt-2 max-h-24 overflow-y-auto rounded-md bg-zinc-900 p-2 text-[10px] leading-4 text-zinc-500">{candidate.messages.slice(0, 3).map((message) => <div key={message.nativeItemID}><span className="text-zinc-400">{message.role}: </span>{message.text}</div>)}</div>}</div>
}

function RunsPanel({ runs, endpoints }: { runs: RunRecord[]; endpoints: Endpoint[] }) {
  return <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4"><h2 className="mb-3 text-sm font-semibold text-zinc-200">Runs</h2><div className="space-y-2">{runs.map((run) => <div key={run.id} className="rounded-lg border border-zinc-800/80 bg-zinc-950/40 p-2 text-xs"><div className="flex items-center justify-between gap-2"><span className="truncate text-zinc-300">{run.actorName}</span><span className={`rounded-full px-1.5 py-0.5 ${run.state === 'completed' ? 'bg-emerald-950 text-emerald-200' : run.state === 'active' ? 'bg-blue-950 text-blue-200' : 'bg-zinc-800 text-zinc-400'}`}>{run.state}</span></div><div className="mt-1 truncate text-[10px] text-zinc-600">{endpoints.find((endpoint) => endpoint.id === run.endpointID)?.displayName ?? run.endpointID} · effort {run.reasoningEffort ?? 'auto'}</div>{run.contextPackID !== undefined && <div className="mt-1 font-mono text-[10px] text-emerald-300/70">pack {shortID(run.contextPackID)}</div>}</div>)}{runs.length === 0 && <div className="text-xs text-zinc-600">No runs yet.</div>}</div></div>
}

function MiniPanel({ title, empty, children }: { title: string; empty?: boolean; children?: ReactNode }) {
  return <div className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4"><h2 className="mb-2 text-sm font-semibold text-zinc-200">{title}</h2><div className="space-y-1">{empty ? <div className="text-xs text-zinc-600">None yet.</div> : children}</div></div>
}

function ProgressBar({ label }: { label: string }) {
  return <div className="rounded-md border border-blue-900/70 bg-blue-950/30 px-2 py-2 text-xs text-blue-200"><div className="mb-1">{label}</div><div role="progressbar" aria-label={label} className="h-1 overflow-hidden rounded-full bg-blue-950"><div className="h-full w-1/3 animate-[mu-progress_1.2s_ease-in-out_infinite] rounded-full bg-blue-400" /></div></div>
}

function MarkdownMessage({ text }: { text: string }) {
  const blocks = text.split('```')
  return <div className="space-y-2">{blocks.map((block, index) => index % 2 === 1 ? <pre key={index} className="overflow-x-auto rounded-lg bg-zinc-950 px-3 py-2 font-mono text-xs leading-5 text-zinc-300">{block.replace(/^\w+\n/, '')}</pre> : <MarkdownLines key={index} text={block} />)}</div>
}

function MarkdownLines({ text }: { text: string }) {
  const lines = text.split('\n')
  return <div className="space-y-1">{lines.map((line, index) => { const trimmed = line.trim(); if (trimmed === '') return <div key={index} className="h-1" />; if (trimmed.startsWith('# ')) return <h3 key={index} className="text-base font-semibold text-zinc-100">{inlineMarkdown(trimmed.slice(2))}</h3>; if (trimmed.startsWith('## ')) return <h4 key={index} className="text-sm font-semibold text-zinc-200">{inlineMarkdown(trimmed.slice(3))}</h4>; if (trimmed.startsWith('- ')) return <div key={index} className="flex gap-2"><span className="text-blue-300">•</span><span>{inlineMarkdown(trimmed.slice(2))}</span></div>; return <p key={index}>{inlineMarkdown(trimmed)}</p> })}</div>
}

function inlineMarkdown(value: string): ReactNode {
  const chunks = value.split(/(`[^`]+`|\*\*[^*]+\*\*)/g)
  return chunks.map((chunk, index) => chunk.startsWith('`') && chunk.endsWith('`') ? <code key={index} className="rounded bg-zinc-950 px-1 py-0.5 font-mono text-[0.9em] text-blue-200">{chunk.slice(1, -1)}</code> : chunk.startsWith('**') && chunk.endsWith('**') ? <strong key={index}>{chunk.slice(2, -2)}</strong> : <span key={index}>{chunk}</span>)
}

function endpointLabel(endpoint: Endpoint): string {
  const identity = endpoint.instanceIdentity
  const suffix = identity?.instanceLabel ?? identity?.terminalIdentifier
  return suffix === undefined ? endpoint.displayName : `${endpoint.displayName} · ${suffix}`
}

function surfaceLabel(surfaceKind?: string): string {
  if (surfaceKind === 'desktop_app' || surfaceKind === 'desktop_application') return 'Desktop'
  if (surfaceKind === 'terminal_cli') return 'Terminal'
  return 'Runtime'
}

function contextValue(record: ContextRecord): string {
  if (record.value?.type === 'string' && typeof record.value.value === 'string') return record.value.value
  return typeof record.value?.value === 'string' ? record.value.value : JSON.stringify(record.value?.value ?? '')
}

function shortID(value: string): string {
  return value.length > 12 ? `${value.slice(0, 8)}…${value.slice(-4)}` : value
}

function inferEffort(title: string, objective: string): string {
  const text = `${title} ${objective}`.toLowerCase()
  const score = ['architecture', 'migration', 'security', 'concurrency', 'integration', 'refactor', 'debug'].reduce((count, signal) => count + (text.includes(signal) ? 1 : 0), 0) + Math.floor(text.length / 800)
  return score >= 4 ? 'ultra' : score >= 1 ? 'high' : 'medium'
}
