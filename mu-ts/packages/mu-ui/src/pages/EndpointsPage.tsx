import { api } from '../api.ts'
import { useQuery } from '../hooks.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

export function EndpointsPage() {
  const { data, error, reload } = useQuery(() => api.listEndpoints())

  async function probe(): Promise<void> {
    try {
      await api.probeEndpoints()
      reload()
    } catch (reason) {
      console.error(reason)
    }
  }

  return (
    <Page title="Runtimes">
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-4">
        <button onClick={() => void probe()} className="rounded-md bg-zinc-800 px-4 py-1.5 text-sm font-medium text-zinc-200 hover:bg-zinc-700">
          Probe all
        </button>
      </div>
      <div className="space-y-2">
        {data?.endpoints.map((endpoint) => (
          <div key={endpoint.id} className="flex items-center gap-3 rounded-lg border border-zinc-800 bg-zinc-900 p-4">
            <StatusDot status={endpoint.status} />
            <div>
              <div className="font-medium">{endpoint.displayName}</div>
              <div className="font-mono text-xs text-zinc-500">{endpoint.runtimeTypeID}</div>
            </div>
            <div className="ml-auto text-right text-xs text-zinc-500">
              <div>{endpoint.runtimeVersion}</div>
              <div>{endpoint.location}</div>
            </div>
          </div>
        ))}
        {data?.endpoints.length === 0 && <Empty message="No runtimes registered." />}
      </div>
    </Page>
  )
}

function StatusDot({ status }: { status: string }) {
  const color = status === 'active' ? 'bg-green-500' : status === 'offline' ? 'bg-red-500' : 'bg-amber-500'
  return <span className={`h-2.5 w-2.5 shrink-0 rounded-full ${color}`} title={status} />
}
