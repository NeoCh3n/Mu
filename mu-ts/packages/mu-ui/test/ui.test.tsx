import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import App from '../src/App.tsx'

// Stub the fetch layer so component tests run without a server.
const jsonResponse = (body: unknown, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  json: async () => body,
})

beforeEach(() => {
  window.localStorage.clear()
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = String(input)
    if (url === '/projects') return jsonResponse({ projects: [{ id: 'p1', displayName: 'Renderer', status: 'active', createdAt: new Date().toISOString() }] })
    if (url === '/agents') return jsonResponse({ agents: [] })
    if (url === '/endpoints') return jsonResponse({ endpoints: [] })
    if (url === '/tasks') return jsonResponse({ tasks: [] })
    if (url === '/handoffs') return jsonResponse({ handoffs: [] })
    if (url === '/ledger') return jsonResponse({ events: [] })
    return jsonResponse({ error: 'not_found', message: 'nope' }, 404)
  }))
  // EventSource is unavailable in jsdom; stub a no-op.
  vi.stubGlobal('EventSource', class { addEventListener() {} close() {} })
})

afterEach(() => cleanup())

describe('Mu UI', () => {
  it('renders the sidebar navigation', async () => {
    render(
      <MemoryRouter initialEntries={['/projects']}>
        <App />
      </MemoryRouter>,
    )
    // The nav labels also appear as page titles on their own route, so match
    // the sidebar links explicitly.
    const links = document.querySelectorAll('nav a')
    const labels = Array.from(links).map((link) => link.textContent)
    expect(labels).toEqual(expect.arrayContaining(['Overview', 'Projects', 'Agents']))
    expect(labels).not.toEqual(expect.arrayContaining(['Settings']))
    expect(labels).not.toEqual(expect.arrayContaining(['Runtimes', 'Handoffs', 'Ledger']))
  })

  it('lists projects fetched from the API', async () => {
    render(
      <MemoryRouter initialEntries={['/projects']}>
        <App />
      </MemoryRouter>,
    )
    expect(await screen.findByText('Renderer')).toBeTruthy()
  })

  it('shows an empty state when there are no tasks', async () => {
    render(
      <MemoryRouter initialEntries={['/tasks']}>
        <App />
      </MemoryRouter>,
    )
    expect(await screen.findByText(/No tasks yet/)).toBeTruthy()
  })

  it('shows an empty state when there are no handoffs', async () => {
    render(
      <MemoryRouter initialEntries={['/handoffs']}>
        <App />
      </MemoryRouter>,
    )
    expect(await screen.findByText(/No handoffs yet/)).toBeTruthy()
  })

  it('merges runtime endpoints into the Agents surface', async () => {
    render(
      <MemoryRouter initialEntries={['/agents']}>
        <App />
      </MemoryRouter>,
    )
    expect(await screen.findByText('Runtime endpoints')).toBeTruthy()
    expect(await screen.findByText(/No useful runtime endpoints yet/)).toBeTruthy()
  })

  it('shows project and participating-agent summaries on Overview', async () => {
    render(
      <MemoryRouter initialEntries={['/']}>
        <App />
      </MemoryRouter>,
    )
    expect(await screen.findByText('Current Projects')).toBeTruthy()
    expect(await screen.findByText('Agents in the room')).toBeTruthy()
  })

  it('renders local control plane notification settings', async () => {
    render(
      <MemoryRouter initialEntries={['/settings']}>
        <App />
      </MemoryRouter>,
    )
    expect(await screen.findByText('Task completion notifications')).toBeTruthy()
    expect(screen.getByRole('heading', { name: 'Local control plane' })).toBeTruthy()
    expect(screen.getByRole('switch', { name: 'Show task completion notifications' })).toBeTruthy()
  })

  it('updates the visible interface immediately when switching to Simplified Chinese', async () => {
    render(
      <MemoryRouter initialEntries={['/settings']}>
        <App />
      </MemoryRouter>,
    )
    const languageSelect = screen.getByRole('combobox', { name: 'Interface language' })
    fireEvent.change(languageSelect, { target: { value: 'zh-Hans' } })
    expect(await screen.findByRole('heading', { name: '设置' })).toBeTruthy()
    expect(screen.getByRole('heading', { name: '本地控制平面' })).toBeTruthy()
    const links = document.querySelectorAll('nav a')
    expect(Array.from(links).map((link) => link.textContent)).toEqual(expect.arrayContaining(['概览', 'Projects', 'Agents']))
  })
})
