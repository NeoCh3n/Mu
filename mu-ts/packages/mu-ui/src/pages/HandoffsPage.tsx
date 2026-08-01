import { api } from '../api.ts'
import { useQuery } from '../hooks.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

export function HandoffsPage() {
  const { data, error, reload } = useQuery(() => api.listHandoffs())

  async function resolve(handoffID: string, accepted: boolean): Promise<void> {
    try {
      await fetch(`/handoffs/${handoffID}/resolve`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ accepted, validationMessage: accepted ? 'Accepted from UI.' : 'Rejected from UI.' }),
      })
      reload()
    } catch (reason) {
      console.error(reason)
    }
  }

  return (
    <Page title="Handoffs">
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="space-y-2">
        {data?.handoffs.map((handoff) => (
          <div key={handoff.id} className="flex items-center gap-4 rounded-lg border border-zinc-800 bg-zinc-900 p-4">
            <div className="min-w-0 flex-1">
              <div className="text-sm">{handoff.validationMessage || handoff.id}</div>
              <div className="text-xs text-zinc-500">
                task {handoff.taskID.slice(0, 8)} · {handoff.sourceEndpointID.slice(0, 8)} → {handoff.receiverEndpointID.slice(0, 8)}
              </div>
            </div>
            <span className="rounded-full bg-zinc-800 px-2 py-0.5 text-xs text-zinc-300">{handoff.status}</span>
            {handoff.status === 'proposed' && (
              <div className="flex gap-1">
                <button onClick={() => void resolve(handoff.id, true)} className="rounded bg-green-900/60 px-2 py-1 text-xs text-green-200 hover:bg-green-900">
                  Accept
                </button>
                <button onClick={() => void resolve(handoff.id, false)} className="rounded bg-red-900/60 px-2 py-1 text-xs text-red-200 hover:bg-red-900">
                  Reject
                </button>
              </div>
            )}
          </div>
        ))}
        {data?.handoffs.length === 0 && <Empty message="No handoffs yet." />}
      </div>
    </Page>
  )
}
