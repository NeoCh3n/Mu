import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useParams } from 'react-router'
import { api, type ContextRecord, type Endpoint, type ExternalConversationCandidate, type RunRecord } from '../api.ts'
import { useQuery, useSSE } from '../hooks.ts'
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
  const { data: task, error } = useQuery(() => api.fetchTask(id), [id])
  const { data: chat, reload: reloadChat } = useQuery(() => api.listChat(id), [id])
  const { data: runs, reload: reloadRuns } = useQuery(() => api.listRuns(id), [id])
  const { data: artifacts, reload: reloadArtifacts } = useQuery(() => api.listArtifacts(id), [id])
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
  const [historyOpen, setHistoryOpen] = useState(false)
  const [historyLoading, setHistoryLoading] = useState(false)
  const [historyError, setHistoryError] = useState<string | undefined>()
  const [history, setHistory] = useState<ExternalConversationCandidate[]>([])
  const [hydratingID, setHydratingID] = useState<string | undefined>()
  const chatEndRef = useRef<HTMLDivElement>(null)

  const endpoints = endpointData?.endpoints ?? []
  const currentTask = task?.task
  const running = runs?.runs.some((run) => ['starting', 'active'].includes(run.state)) === true
  const latestRun = runs?.runs[0]
  const mentionedEndpoint = useMemo(() => resolveMentionEndpoint(input, endpoints), [input, endpoints])
  const effectiveEndpointID = mentionedEndpoint?.id
    ?? selectedEndpointID
    ?? currentTask?.currentEndpointID
    ?? endpoints.find((endpoint) => endpoint.status === 'active')?.id
    ?? endpoints[0]?.id
    ?? ''
  const effectiveEndpoint = endpoints.find((endpoint) => endpoint.id === effectiveEndpointID)
  const autoEffort = inferEffort(currentTask?.title ?? '', currentTask?.objective ?? '')

  useEffect(() => {
    const current = endpoints.find((endpoint) => endpoint.id === currentTask?.currentEndpointID)
    const fallback = current ?? endpoints.find((endpoint) => endpoint.status === 'active') ?? endpoints[0]
    if (selectedEndpointID === '' && fallback !== undefined) setSelectedEndpointID(fallback.id)
  }, [currentTask?.currentEndpointID, endpoints, selectedEndpointID])

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
    }, 900)
    return () => clearInterval(timer)
  }, [running, reloadArtifacts, reloadChat, reloadRuns])

  useEffect(() => {
    const latest = sse[sse.length - 1]
    if (latest === undefined) return
    const payload = latest.data as { taskID?: string; event?: { kind?: string; text?: string } } | null
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
    }
  }, [id, reloadArtifacts, reloadChat, reloadRuns, sse])

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
          <div className="mb-1 text-xs uppercase tracking-[0.18em] text-zinc-600">Project workspace</div>
          <h1 className="truncate text-2xl font-semibold tracking-tight text-zinc-100">{currentTask?.title ?? 'Task'}</h1>
          <p className="mt-1 max-w-3xl text-sm leading-6 text-zinc-400">{currentTask?.objective}</p>
          <p className="mt-1 truncate font-mono text-xs text-zinc-600">{currentTask?.repositoryPath}</p>
        </div>
        <div className="flex items-center gap-2 rounded-xl border border-zinc-800 bg-zinc-900/80 p-2">
          <span className={`h-2.5 w-2.5 rounded-full ${running ? 'animate-pulse bg-blue-400' : 'bg-zinc-600'}`} />
          <span className="text-xs text-zinc-400">{running ? 'Working' : currentTask?.status ?? 'Loading'}</span>
        </div>
      </div>
      {error !== undefined && <ErrorBanner message={error} />}
      {errorMessage !== undefined && <ErrorBanner message={errorMessage} />}

      <div className="relative mb-4 flex flex-wrap items-center gap-1 rounded-xl border border-zinc-800 bg-zinc-900/70 p-1.5">
        <button type="button" onClick={() => setSurface('chat')} className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition ${surface === 'chat' ? 'bg-violet-500/15 text-violet-200' : 'text-zinc-500 hover:bg-zinc-800 hover:text-zinc-200'}`}>Chat</button>
        <button type="button" onClick={() => setToolsOpen((current) => !current)} className="rounded-lg px-3 py-1.5 text-xs font-semibold text-zinc-400 transition hover:bg-zinc-800 hover:text-zinc-200">Tools ▾</button>
        {toolsOpen && <div className="absolute left-1 top-11 z-20 w-44 rounded-xl border border-zinc-700 bg-zinc-900 p-1.5 shadow-2xl"><div className="px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.15em] text-zinc-600">Workspace tools</div>{SURFACES.filter((item) => item.value !== 'chat').map((item) => <button key={item.value} type="button" onClick={() => { setSurface(item.value); setToolsOpen(false) }} className="block w-full rounded-lg px-2 py-1.5 text-left text-xs text-zinc-300 hover:bg-zinc-800">{item.label}</button>)}<div className="my-1 border-t border-zinc-800" /><button type="button" onClick={() => { setEnvironmentOpen(true); setToolsOpen(false) }} className="block w-full rounded-lg px-2 py-1.5 text-left text-xs text-zinc-300 hover:bg-zinc-800">Environment</button></div>}
        <button type="button" onClick={() => setEnvironmentOpen((current) => !current)} className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition ${environmentOpen ? 'bg-violet-500/15 text-violet-200' : 'text-zinc-500 hover:bg-zinc-800 hover:text-zinc-200'}`}>{environmentOpen ? 'Hide Environment' : 'Environment'}</button>
        <span className="ml-auto truncate px-2 font-mono text-[10px] text-zinc-600">{currentTask?.repositoryPath}</span>
      </div>

      <div className={`grid gap-4 ${environmentOpen ? 'xl:grid-cols-[minmax(0,1fr)_22rem]' : ''}`}>
        {surface === 'chat' ? <section className="flex min-h-[calc(100vh-12rem)] flex-col rounded-xl border border-zinc-800 bg-zinc-900/50">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-800 px-4 py-3">
            <div className="flex min-w-0 items-center gap-2">
              <span className="text-sm font-semibold text-zinc-200">Workspace chat</span>
              {mentionedEndpoint !== undefined && <span className="rounded-full bg-violet-950 px-2 py-0.5 text-[11px] text-violet-200">@ routed to {mentionedEndpoint.displayName}</span>}
            </div>
            <div className="flex flex-wrap items-center gap-2">
              <label className="text-[11px] text-zinc-500">Endpoint</label>
              <select value={effectiveEndpointID} onChange={(event) => setSelectedEndpointID(event.target.value)} className="max-w-52 rounded-md border border-zinc-700 bg-zinc-950 px-2 py-1 text-xs text-zinc-300">
                {endpoints.map((endpoint) => <option key={endpoint.id} value={endpoint.id}>{endpointLabel(endpoint)}</option>)}
              </select>
              <button onClick={() => void interrupt()} disabled={!running} className="rounded-md bg-red-950/70 px-2.5 py-1 text-xs text-red-200 transition hover:bg-red-900 disabled:opacity-30">Interrupt</button>
            </div>
          </div>

          <div className="flex-1 space-y-4 overflow-y-auto p-4">
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
                <div className="text-[11px] text-blue-300">{effectiveEndpoint?.displayName ?? 'Agent'} · streaming</div>
                <div className="mt-1 inline-block max-w-[92%] rounded-xl border border-blue-900/70 bg-blue-950/30 px-3 py-2 text-sm leading-6 text-zinc-100"><MarkdownMessage text={streamingText} /></div>
              </div>
            )}
            {chat?.entries.length === 0 && streamingText === '' && <div className="py-12 text-center text-sm text-zinc-600">No messages yet. Mention @Codex or @Claude Code to route the first turn.</div>}
            <div ref={chatEndRef} />
          </div>

          <div className="border-t border-zinc-800 p-3">
            <div className="mb-2 flex flex-wrap items-center gap-2 text-xs">
              <span className="text-zinc-500">Reasoning</span>
              {EFFORTS.map((option) => (
                <button key={option.value} type="button" title={option.hint} onClick={() => setEffort(option.value)} className={`rounded-full px-2.5 py-1 transition ${effort === option.value ? 'bg-violet-600 text-white' : 'bg-zinc-800 text-zinc-400 hover:bg-zinc-700'}`}>
                  {option.label}{option.value === 'auto' && <span className="ml-1 text-[10px] opacity-70">({autoEffort})</span>}
                </button>
              ))}
              <span className="ml-auto text-zinc-600">{selectedContextIDs.length} context item{selectedContextIDs.length === 1 ? '' : 's'} selected</span>
            </div>
            <div className="flex gap-2">
              <textarea
                value={input}
                onChange={(event) => setInput(event.target.value)}
                onKeyDown={(event) => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); void send() } }}
                placeholder="Message the workspace… use @Codex or @Claude Code"
                rows={2}
                className="min-h-11 flex-1 resize-none rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm outline-none ring-blue-500 focus:ring-1"
              />
              <button onClick={() => void send()} disabled={sending || input.trim() === '' || effectiveEndpointID === ''} className="self-end rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-500 disabled:opacity-40">{sending ? 'Starting…' : 'Send'}</button>
            </div>
          </div>
        </section> : <WorkspaceSurfacePlaceholder surface={surface} repositoryPath={currentTask?.repositoryPath} artifacts={artifacts?.artifacts ?? []} />}

        {environmentOpen && <aside className="space-y-3">
          <RuntimeCard endpoint={effectiveEndpoint} latestRun={latestRun} />
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

function resolveMentionEndpoint(input: string, endpoints: Endpoint[]): Endpoint | undefined {
  const lower = input.toLowerCase()
  const explicit = lower.includes('@claude') ? 'claude_code' : lower.includes('@codex') ? 'codex' : undefined
  if (explicit !== undefined) return endpoints.find((endpoint) => endpoint.instanceIdentity?.provider?.rawValue === explicit || endpoint.runtimeTypeID.toLowerCase().includes(explicit.replace('_', '-')))
  return endpoints.find((endpoint) => {
    const label = endpoint.displayName.toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()
    return label !== '' && lower.includes(`@${label}`)
  })
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
