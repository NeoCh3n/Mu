import { useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router'
import { api } from '../api.ts'
import { useQuery, useSSE } from '../hooks.ts'
import { ErrorBanner } from './ProjectsPage.tsx'

/**
 * Workspace for one task: chat + runs + artifacts + context. The chat pane
 * re-polls while a run is active; the live event strip shows SSE envelopes.
 */
export function TaskDetailPage() {
  const { id = '' } = useParams()
  const { data: task, error } = useQuery(() => api.fetchTask(id), [id])
  const { data: chat, reload: reloadChat } = useQuery(() => api.listChat(id), [id])
  const { data: runs, reload: reloadRuns } = useQuery(() => api.listRuns(id), [id])
  const { data: artifacts, reload: reloadArtifacts } = useQuery(() => api.listArtifacts(id), [id])
  const { data: handoffs } = useQuery(() => api.listHandoffs(id), [id])
  const { data: ledger } = useQuery(() => api.listLedger(id), [id])
  const sse = useSSE(100)
  const [input, setInput] = useState('')
  const [sending, setSending] = useState(false)
  const [errorMessage, setErrorMessage] = useState<string | undefined>()
  const chatEndRef = useRef<HTMLDivElement>(null)

  const running = runs?.runs.some((run) => ['starting', 'active'].includes(run.state)) === true

  // Poll while the task is running so the chat stays live.
  useEffect(() => {
    if (!running) return
    const timer = setInterval(() => {
      reloadChat()
      reloadRuns()
      reloadArtifacts()
    }, 1000)
    return () => clearInterval(timer)
  }, [running, reloadChat, reloadRuns, reloadArtifacts])

  useEffect(() => {
    chatEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [chat?.entries.length])

  async function send(): Promise<void> {
    const text = input.trim()
    if (text === '' || sending) return
    setSending(true)
    setErrorMessage(undefined)
    try {
      await api.startTurn(id, text)
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

  return (
    <div className="mx-auto max-w-5xl p-8">
      <div className="mb-6">
        <h1 className="text-xl font-semibold">{task?.task.title ?? 'Task'}</h1>
        <p className="mt-1 text-sm text-zinc-400">{task?.task.objective}</p>
        <p className="mt-0.5 font-mono text-xs text-zinc-600">{task?.task.repositoryPath}</p>
      </div>
      {error !== undefined && <ErrorBanner message={error} />}
      {errorMessage !== undefined && <ErrorBanner message={errorMessage} />}

      <div className="grid grid-cols-3 gap-4">
        {/* Chat + composer */}
        <section className="col-span-2 flex h-[60vh] flex-col rounded-lg border border-zinc-800 bg-zinc-900">
          <div className="flex items-center justify-between border-b border-zinc-800 px-4 py-2 text-sm text-zinc-400">
            <span>Chat</span>
            <div className="flex items-center gap-2">
              {running && (
                <button onClick={() => void interrupt()} className="rounded bg-red-900/60 px-2 py-0.5 text-xs text-red-200 hover:bg-red-900">
                  Interrupt
                </button>
              )}
              <span className={`h-2 w-2 rounded-full ${running ? 'animate-pulse bg-blue-500' : 'bg-zinc-600'}`} />
            </div>
          </div>
          <div className="flex-1 space-y-3 overflow-y-auto p-4">
            {chat?.entries.map((entry) => (
              <div key={entry.id} className={entry.authorKind === 'user' ? 'text-right' : ''}>
                <div className="text-xs text-zinc-500">{entry.authorName}</div>
                <div className={`mt-0.5 inline-block rounded-lg px-3 py-1.5 text-sm whitespace-pre-wrap ${entry.authorKind === 'user' ? 'bg-blue-700/40 text-blue-50' : 'bg-zinc-800 text-zinc-100'}`}>
                  {entry.text}
                </div>
              </div>
            ))}
            {chat?.entries.length === 0 && <div className="text-sm text-zinc-600">No messages yet.</div>}
            <div ref={chatEndRef} />
          </div>
          <div className="border-t border-zinc-800 p-3">
            <div className="flex gap-2">
              <input
                value={input}
                onChange={(event) => setInput(event.target.value)}
                onKeyDown={(event) => event.key === 'Enter' && !event.shiftKey && void send()}
                placeholder="Send a message to the agent…"
                className="flex-1 rounded-md border border-zinc-700 bg-zinc-950 px-3 py-1.5 text-sm"
              />
              <button onClick={() => void send()} disabled={sending || input.trim() === ''} className="rounded-md bg-blue-600 px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40">
                Send
              </button>
            </div>
          </div>
        </section>

        {/* Runs / artifacts / context column */}
        <section className="space-y-4">
          <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-4">
            <h2 className="mb-2 text-sm font-semibold text-zinc-300">Runs</h2>
            <div className="space-y-2">
              {runs?.runs.map((run) => (
                <div key={run.id} className="text-xs">
                  <div className="flex justify-between">
                    <span>{run.actorName}</span>
                    <span className="text-zinc-500">{run.state}</span>
                  </div>
                  <div className="truncate text-zinc-500">{run.nativeOutput}</div>
                </div>
              ))}
              {runs?.runs.length === 0 && <div className="text-xs text-zinc-600">No runs yet.</div>}
            </div>
          </div>

          <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-4">
            <h2 className="mb-2 text-sm font-semibold text-zinc-300">Artifacts</h2>
            <div className="space-y-1">
              {artifacts?.artifacts.map((artifact) => (
                <div key={artifact.id} className="flex justify-between text-xs">
                  <span className="truncate font-mono">{artifact.relativePath}</span>
                  <span className="text-zinc-500">{artifact.byteCount} B</span>
                </div>
              ))}
              {artifacts?.artifacts.length === 0 && <div className="text-xs text-zinc-600">None yet.</div>}
            </div>
          </div>

          <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-4">
            <h2 className="mb-2 text-sm font-semibold text-zinc-300">Handoffs</h2>
            <div className="space-y-1 text-xs">
              {handoffs?.handoffs.map((handoff) => (
                <div key={handoff.id} className="flex justify-between">
                  <span className="truncate">{handoff.validationMessage || handoff.status}</span>
                  <span className="text-zinc-500">{handoff.status}</span>
                </div>
              ))}
              {handoffs?.handoffs.length === 0 && <div className="text-zinc-600">None yet.</div>}
            </div>
          </div>

          <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-4">
            <h2 className="mb-2 text-sm font-semibold text-zinc-300">Ledger</h2>
            <div className="max-h-48 space-y-1 overflow-y-auto text-xs">
              {ledger?.events.map((event) => (
                <div key={event.sequence} className="flex gap-2">
                  <span className="w-8 shrink-0 text-right text-zinc-600">{event.sequence}</span>
                  <span className="truncate text-zinc-400">{event.summary}</span>
                </div>
              ))}
            </div>
          </div>
        </section>
      </div>

      {/* Live event strip */}
      <div className="mt-4 rounded-lg border border-zinc-800 bg-zinc-900 p-3">
        <div className="text-xs font-medium uppercase tracking-wider text-zinc-500">Live</div>
        <div className="mt-1 flex flex-wrap gap-1 text-[11px]">
          {sse.slice(-20).map((envelope, index) => (
            <span key={`${envelope.event}-${index}`} className="rounded bg-zinc-800 px-1.5 py-0.5 text-zinc-400">
              {envelope.event}
            </span>
          ))}
          {sse.length === 0 && <span className="text-zinc-600">No live events.</span>}
        </div>
      </div>
    </div>
  )
}
