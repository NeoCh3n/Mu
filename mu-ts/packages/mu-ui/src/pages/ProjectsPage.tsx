import { useState } from 'react'
import { api } from '../api.ts'
import { useQuery } from '../hooks.ts'

export function ProjectsPage() {
  const { data, error, reload } = useQuery(() => api.listProjects())
  const [name, setName] = useState('')
  const [creating, setCreating] = useState(false)

  async function create(): Promise<void> {
    if (name.trim() === '') return
    setCreating(true)
    try {
      await api.createProject(name.trim())
      setName('')
      reload()
    } finally {
      setCreating(false)
    }
  }

  return (
    <Page title="Projects">
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-4 flex gap-2">
        <input
          value={name}
          onChange={(event) => setName(event.target.value)}
          onKeyDown={(event) => event.key === 'Enter' && void create()}
          placeholder="Project name"
          className="rounded-md border border-zinc-700 bg-zinc-900 px-3 py-1.5 text-sm"
        />
        <button
          onClick={() => void create()}
          disabled={creating || name.trim() === ''}
          className="rounded-md bg-blue-600 px-4 py-1.5 text-sm font-medium text-white disabled:opacity-40"
        >
          Create
        </button>
      </div>
      <div className="space-y-2">
        {data?.projects.map((project) => (
          <div key={project.id} className="rounded-lg border border-zinc-800 bg-zinc-900 p-4">
            <div className="flex items-baseline justify-between">
              <span className="font-medium">{project.displayName}</span>
              <span className="text-xs text-zinc-500">{project.status}</span>
            </div>
            {project.repositoryPath !== undefined && (
              <div className="mt-1 font-mono text-xs text-zinc-500">{project.repositoryPath}</div>
            )}
          </div>
        ))}
        {data?.projects.length === 0 && <Empty message="No projects yet — create one above." />}
      </div>
    </Page>
  )
}

export function Page({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="mx-auto max-w-4xl p-8">
      <h1 className="mb-6 text-xl font-semibold">{title}</h1>
      {children}
    </div>
  )
}

export function ErrorBanner({ message }: { message: string }) {
  return (
    <div className="mb-4 rounded-md border border-red-800 bg-red-950/40 px-4 py-2 text-sm text-red-300">
      {message}
    </div>
  )
}

export function Empty({ message }: { message: string }) {
  return <div className="rounded-lg border border-dashed border-zinc-800 p-6 text-center text-sm text-zinc-500">{message}</div>
}
