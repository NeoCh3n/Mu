import { api } from '../api.ts'
import { useQuery } from '../hooks.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

export function LedgerPage() {
  const { data, error } = useQuery(() => api.listLedger())

  return (
    <Page title="Ledger">
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="rounded-lg border border-zinc-800 bg-zinc-900">
        {data?.events.map((event) => (
          <div key={event.sequence} className="flex gap-3 border-b border-zinc-800/60 px-4 py-2 text-sm last:border-b-0">
            <span className="w-12 shrink-0 text-right font-mono text-xs text-zinc-600">{event.sequence}</span>
            <span className="w-40 shrink-0 truncate font-mono text-xs text-blue-400">{event.type}</span>
            <span className="flex-1 truncate text-zinc-300">{event.summary}</span>
            <span className="shrink-0 text-xs text-zinc-600">{new Date(event.occurredAt).toLocaleTimeString()}</span>
          </div>
        ))}
        {data?.events.length === 0 && (
          <div className="p-6">
            <Empty message="No ledger events yet." />
          </div>
        )}
      </div>
    </Page>
  )
}
