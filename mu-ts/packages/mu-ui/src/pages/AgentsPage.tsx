import { useMemo, useState } from 'react'
import { api, type Agent, type Endpoint } from '../api.ts'
import { useMuUISettings, useQuery } from '../hooks.ts'
import { text } from '../i18n.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

const RUNTIME_PROFILES = [
  { id: 'codex', name: 'Codex', runtimeTypeID: 'openai.codex/app-server', summary: 'Detected Codex Desktop or CLI. Select the verified instance below the Project chat composer.' },
  { id: 'claude', name: 'Claude Code', runtimeTypeID: 'anthropic.claude-code/cli', summary: 'Detected Claude Code terminal. Select the verified instance below the Project chat composer.' },
  { id: 'pi', name: 'Pi', runtimeTypeID: 'pi/coding-agent', summary: 'Choose the Pi executable once, then select it below the Project chat composer.' },
  { id: 'opencode', name: 'OpenCode', runtimeTypeID: 'opencode/cli', summary: 'Choose the OpenCode executable once, then select it below the Project chat composer.' },
] as const

export function AgentsPage() {
  const { settings } = useMuUISettings()
  const t = (english: string, simplifiedChinese: string) => text(settings.language, english, simplifiedChinese)
  const { data, error, reload } = useQuery(() => api.listAgents())
  const { data: endpointData, reload: reloadEndpoints } = useQuery(() => api.listEndpoints())
  const [displayName, setDisplayName] = useState('')
  const [shortName, setShortName] = useState('')
  const [summary, setSummary] = useState('')
  const [preferredEndpointID, setPreferredEndpointID] = useState('')
  const [creating, setCreating] = useState(false)
  const [showOtherRuntimes, setShowOtherRuntimes] = useState(false)
  const [cleaningRuntimes, setCleaningRuntimes] = useState(false)
  const [runtimeSetup, setRuntimeSetup] = useState<(typeof RUNTIME_PROFILES)[number]['id'] | undefined>()
  const [runtimePath, setRuntimePath] = useState('')
  const [configuringRuntime, setConfiguringRuntime] = useState(false)
  const [probingRuntime, setProbingRuntime] = useState<string | undefined>()
  const agents = data?.agents ?? []
  const primaryAgents = useMemo(() => agents.filter((agent) => !isHiddenStarterAgent(agent) && !isPlaceholderAgent(agent)), [agents])
  const primaryEndpoints = useMemo(() => {
    const useful = (endpointData?.endpoints ?? []).filter(isUsefulEndpoint)
    const groups = new Map<string, Endpoint[]>()
    for (const endpoint of useful) {
      const key = endpointIdentityKey(endpoint)
      groups.set(key, [...(groups.get(key) ?? []), endpoint])
    }
    return [...groups.values()]
      .map((items) => [...items].sort((left, right) => Number(right.status === 'active') - Number(left.status === 'active') || right.lastProbedAt.localeCompare(left.lastProbedAt))[0])
      .filter((endpoint): endpoint is Endpoint => endpoint !== undefined)
      .sort((left, right) => left.displayName.localeCompare(right.displayName))
  }, [endpointData?.endpoints])
  const otherEndpoints = useMemo(() => {
    const primaryIDs = new Set(primaryEndpoints.map((endpoint) => endpoint.id))
    return (endpointData?.endpoints ?? []).filter((endpoint) => !primaryIDs.has(endpoint.id))
  }, [endpointData?.endpoints, primaryEndpoints])
  const duplicateDiscoveredIDs = useMemo(
    () => duplicateDiscoveredEndpointIDs(otherEndpoints),
    [otherEndpoints],
  )

  function configuredEndpoint(profile: (typeof RUNTIME_PROFILES)[number]): Endpoint | undefined {
    return (endpointData?.endpoints ?? []).find((endpoint) => endpoint.runtimeTypeID === profile.runtimeTypeID)
  }

  async function configureRuntime(profile: (typeof RUNTIME_PROFILES)[number]): Promise<void> {
    if (runtimePath.trim() === '') return
    setConfiguringRuntime(true)
    try {
      await api.createEndpoint({
        runtimeTypeID: profile.runtimeTypeID,
        displayName: profile.name + ' CLI',
        runtimeVersion: 'configured locally',
        location: 'local',
        executablePath: runtimePath.trim(),
        surfaceKind: 'terminal_cli',
        instanceLabel: profile.name + ' CLI',
      })
      setRuntimePath('')
      setRuntimeSetup(undefined)
      reloadEndpoints()
    } catch (reason) {
      console.error(reason)
    } finally {
      setConfiguringRuntime(false)
    }
  }

  async function probeRuntime(profile: (typeof RUNTIME_PROFILES)[number]): Promise<void> {
    if (profile.id === 'pi' || profile.id === 'opencode') return
    setProbingRuntime(profile.id)
    try {
      await api.probeEndpoints()
      reloadEndpoints()
    } catch (reason) {
      console.error(reason)
    } finally {
      setProbingRuntime(undefined)
    }
  }

  async function removeEndpoint(endpoint: Endpoint): Promise<void> {
    if (!window.confirm(t(`Remove “${endpoint.displayName}” from discovered runtimes?`, `从已发现的运行时中移除“${endpoint.displayName}”？`))) return
    try {
      await api.removeEndpoint(endpoint.id)
      reloadEndpoints()
    } catch (reason) {
      console.error(reason)
    }
  }

  async function cleanDuplicateRuntimes(): Promise<void> {
    if (duplicateDiscoveredIDs.length === 0) return
    setCleaningRuntimes(true)
    try {
      await api.removeDuplicateDiscoveredEndpoints()
      reloadEndpoints()
    } catch (reason) {
      console.error(reason)
    } finally {
      setCleaningRuntimes(false)
    }
  }

  async function create(): Promise<void> {
    if (displayName.trim() === '') return
    setCreating(true)
    try {
      await api.createAgent({
        displayName: displayName.trim(),
        shortName: shortName.trim() || displayName.trim().toLowerCase(),
        role: 'builder',
        summary: summary.trim(),
        preferredEndpointID: preferredEndpointID || undefined,
      })
      setDisplayName('')
      setShortName('')
      setSummary('')
      setPreferredEndpointID('')
      reload()
    } catch (reason) {
      console.error(reason)
    } finally {
      setCreating(false)
    }
  }

  return (
    <Page title={t('Agent identities', 'Agent 身份')} subtitle={t('Agent identities are optional; Tasks can start directly on a local Runtime.', 'Agent 身份不是必选项；任务可以直接在本地 Runtime 上启动。')}>
      {error !== undefined && <ErrorBanner message={error} />}
      <div className="mb-6 rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
        <div className="mb-3 text-xs font-semibold uppercase tracking-[0.16em] text-zinc-500">{t('Optional aliases', '可选别名')} · {primaryAgents.length} {t('configured', '个已配置')}</div>
        <p className="mb-4 max-w-2xl text-sm leading-6 text-zinc-500">{t('Start work with a local Runtime first. Add an identity only when you need a reusable name, role, or alias.', '先使用本地 Runtime 开始工作。只有需要复用名称、角色或别名时才添加身份。')}</p>
        <div className="grid gap-2 md:grid-cols-4">
          <input value={displayName} onChange={(event) => setDisplayName(event.target.value)} placeholder={t('Display name', '显示名称')} className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm" />
          <input value={shortName} onChange={(event) => setShortName(event.target.value)} placeholder={t('Mention name', '提及名称')} className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm" />
          <select value={preferredEndpointID} onChange={(event) => setPreferredEndpointID(event.target.value)} className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm">
            <option value="">{t('Preferred endpoint…', '首选 endpoint…')}</option>
            {(endpointData?.endpoints ?? []).map((endpoint) => <option key={endpoint.id} value={endpoint.id}>{endpointLabel(endpoint)}</option>)}
          </select>
          <button onClick={() => void create()} disabled={creating || displayName.trim() === ''} className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-500 disabled:opacity-40">{creating ? t('Registering…', '注册中…') : t('Register agent', '注册 Agent')}</button>
          <input value={summary} onChange={(event) => setSummary(event.target.value)} placeholder={t('Optional note', '可选备注')} className="md:col-span-4 rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm" />
        </div>
      </div>

      <section className="mb-8 rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
        <div className="mb-3">
            <h2 className="text-sm font-semibold text-zinc-200">{t('Runtime setup', '运行时配置')}</h2>
            <p className="mt-1 max-w-3xl text-xs leading-5 text-zinc-500">{t('Configure the LLM host, not an Agent identity. Once a Runtime is ready, select it below the Project chat composer.', '这里配置 LLM host，而不是预先定义 Agent 身份。Runtime 就绪后，在 Project 聊天输入框下方选择它。')}</p>
        </div>
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          {RUNTIME_PROFILES.map((profile) => {
            const endpoint = configuredEndpoint(profile)
            const ready = endpoint?.status === 'active'
            return <article key={profile.id} className="rounded-lg border border-zinc-800/80 bg-zinc-950/40 p-3"><div className="flex items-center justify-between gap-2"><h3 className="text-sm font-medium text-zinc-100">{profile.name}</h3><span className={`rounded-full px-2 py-0.5 text-[10px] ${ready ? 'bg-emerald-950 text-emerald-200' : endpoint === undefined ? 'bg-zinc-800 text-zinc-500' : 'bg-amber-950 text-amber-200'}`}>{ready ? t('Ready', '就绪') : endpoint === undefined ? t('Not configured', '未配置') : t('Found', '已发现')}</span></div><p className="mt-2 min-h-10 text-xs leading-5 text-zinc-500">{runtimeProfileSummary(profile, settings.language)}</p><div className="mt-3 flex items-center justify-between gap-2"><span className="text-[11px] font-medium text-violet-300">{t('Select in Project chat', '在 Project 聊天中选择')}</span>{ready ? <span className="text-[11px] text-emerald-300">{t('Configured', '已配置')}</span> : endpoint !== undefined && (profile.id === 'codex' || profile.id === 'claude') ? <button type="button" onClick={() => void probeRuntime(profile)} disabled={probingRuntime !== undefined} className="rounded-md bg-zinc-800 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-zinc-700 disabled:opacity-50">{probingRuntime === profile.id ? t('Checking…', '检查中…') : t('Check now', '立即检查')}</button> : <button type="button" onClick={() => { setRuntimeSetup(profile.id); setRuntimePath(endpoint?.nativeConfiguration?.executable ?? '') }} className="rounded-md bg-zinc-800 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-zinc-700">{endpoint === undefined ? t('Configure', '配置') : t('Finish setup', '完成配置')}</button>}</div></article>
          })}
        </div>
        {runtimeSetup !== undefined && (
          <form onSubmit={(event) => { event.preventDefault(); const profile = RUNTIME_PROFILES.find((item) => item.id === runtimeSetup); if (profile !== undefined) void configureRuntime(profile) }} className="mt-4 rounded-lg border border-violet-900/60 bg-violet-950/20 p-3">
            <div className="mb-2 text-xs font-medium text-violet-100">{t('Choose the local executable for', '选择本地可执行文件')} {RUNTIME_PROFILES.find((item) => item.id === runtimeSetup)?.name}</div>
            <div className="flex gap-2"><input autoFocus value={runtimePath} onChange={(event) => setRuntimePath(event.target.value)} placeholder="/path/to/cli" className="min-w-0 flex-1 rounded-md border border-zinc-700 bg-zinc-950 px-3 py-2 font-mono text-xs" /><button type="submit" disabled={configuringRuntime || runtimePath.trim() === ''} className="rounded-md bg-violet-600 px-3 py-2 text-xs text-white disabled:opacity-40">{configuringRuntime ? t('Saving…', '保存中…') : t('Save runtime', '保存运行时')}</button><button type="button" onClick={() => setRuntimeSetup(undefined)} className="rounded-md px-2 py-2 text-xs text-zinc-500 hover:bg-zinc-800">{t('Cancel', '取消')}</button></div>
            <p className="mt-2 text-[11px] leading-5 text-zinc-500">{t('Mu stores this path locally. A host-specific adapter check must pass before it can execute a Task.', 'Mu 会将路径保存在本机。必须通过对应 host 的适配器检查后，才能执行任务。')}</p>
          </form>
        )}
        </section>

      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        {primaryAgents.map((agent) => {
          const endpoint = endpointData?.endpoints.find((candidate) => candidate.id === agent.preferredEndpointID)
          return <AgentCard key={agent.id} agent={agent} endpoint={endpoint} />
        })}
      </div>
      {primaryAgents.length === 0 && <Empty message={t('No reusable identities yet. This is expected — Tasks can run without one.', '还没有可复用身份。这是正常的，任务无需预先定义身份也能运行。')} />}

      <section className="mt-8">
        <div className="mb-3 flex items-end justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold text-zinc-200">{t('Runtime endpoints', '运行时 endpoints')}</h2>
            <p className="mt-1 max-w-2xl text-xs leading-5 text-zinc-500">{t('Mu keeps one card per identifiable local Runtime. A runtime is useful when it has a stable identity or has passed a probe; the rest stay as removable discoveries.', 'Mu 会为可识别的本地 Runtime 保留一张卡片。拥有稳定身份或通过检查的 Runtime 才算有用，其余发现记录可以移除。')}</p>
          </div>
          <div className="flex items-center gap-2">
            <span className="text-xs text-zinc-600">{primaryEndpoints.length} {t('useful', '个有用')} · {otherEndpoints.length} {t('unverified', '个未验证')}</span>
            {duplicateDiscoveredIDs.length > 0 && (
              <button
                type="button"
                onClick={() => void cleanDuplicateRuntimes()}
                disabled={cleaningRuntimes}
                className="rounded-md border border-amber-700/60 px-2.5 py-1 text-[11px] text-amber-200 hover:bg-amber-950/50 disabled:opacity-40"
              >
                {cleaningRuntimes ? t('Cleaning…', '清理中…') : `${t('Close', '关闭')} ${duplicateDiscoveredIDs.length} ${t('duplicates', '个重复项')}`}
              </button>
            )}
          </div>
        </div>
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {primaryEndpoints.map((endpoint) => <RuntimeCompactCard key={endpoint.id} endpoint={endpoint} onRemove={() => void removeEndpoint(endpoint)} />)}
          {primaryEndpoints.length === 0 && <Empty message={t('No useful runtime endpoints yet.', '还没有可用的运行时 endpoint。')} />}
        </div>
        {otherEndpoints.length > 0 && <div className="mt-3 rounded-xl border border-zinc-800 bg-zinc-950/40 p-3"><button type="button" onClick={() => setShowOtherRuntimes((current) => !current)} className="flex w-full items-center justify-between text-left text-sm font-medium text-zinc-300"><span>{t('Other discovered runtimes', '其他已发现的运行时')} · {otherEndpoints.length}</span><span className="text-xs text-zinc-600">{showOtherRuntimes ? t('Hide', '隐藏') : t('Show', '显示')}</span></button>{showOtherRuntimes && <div className="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-3">{otherEndpoints.map((endpoint) => <RuntimeCompactCard key={endpoint.id} endpoint={endpoint} onRemove={() => void removeEndpoint(endpoint)} />)}</div>}</div>}
      </section>
    </Page>
  )
}

function isUsefulEndpoint(endpoint: Endpoint): boolean {
  return endpoint.status !== 'discovered' || endpoint.instanceIdentity !== undefined || endpoint.nativeConfiguration !== undefined
}

function runtimeProfileSummary(profile: (typeof RUNTIME_PROFILES)[number], language: 'en' | 'zh-Hans'): string {
  if (language === 'zh-Hans') {
    if (profile.id === 'codex') return '已发现 Codex Desktop 或 CLI。在 Project 聊天输入框下方选择经过验证的实例。'
    if (profile.id === 'claude') return '已发现 Claude Code terminal。在 Project 聊天输入框下方选择经过验证的 terminal。'
    if (profile.id === 'pi') return '配置一次 Pi 可执行文件，然后在 Project 聊天输入框下方选择它。'
    return '配置一次 OpenCode 可执行文件，然后在 Project 聊天输入框下方选择它。'
  }
  return profile.summary
}

function endpointIdentityKey(endpoint: Endpoint): string {
  const identity = endpoint.instanceIdentity
  if (identity?.stableInstanceKey !== undefined) {
    return `identity:${identity.provider?.rawValue ?? endpoint.runtimeTypeID}:${identity.stableInstanceKey}`
  }
  const executable = endpoint.nativeConfiguration?.executable
  if (executable !== undefined) return `executable:${endpoint.runtimeTypeID}:${executable}`
  return `unidentified:${endpoint.runtimeTypeID}:${endpoint.displayName.trim().toLowerCase()}`
}

function duplicateDiscoveredEndpointIDs(endpoints: Endpoint[]): string[] {
  const groups = new Map<string, Endpoint[]>()
  for (const endpoint of endpoints.filter((candidate) => candidate.status === 'discovered' && !isUsefulEndpoint(candidate))) {
    const key = endpointIdentityKey(endpoint)
    groups.set(key, [...(groups.get(key) ?? []), endpoint])
  }
  return [...groups.values()].flatMap((items) => items
    .sort((left, right) => right.lastProbedAt.localeCompare(left.lastProbedAt))
    .slice(1)
    .map((endpoint) => endpoint.id))
}

function isHiddenStarterAgent(agent: Agent): boolean {
  return ['Orchestrator', 'Builder', 'Researcher', 'Reviewer'].includes(agent.displayName)
    && agent.preferredEndpointID === undefined
    && (agent.capabilityTags?.length ?? 0) === 0
}

function RuntimeCompactCard({ endpoint, onRemove }: { endpoint: Endpoint; onRemove: () => void }) {
  const identity = endpoint.instanceIdentity
  const surface = identity?.surfaceKind === 'desktop_app' || identity?.surfaceKind === 'desktop_application' ? 'Desktop' : identity?.surfaceKind === 'terminal_cli' ? 'Terminal' : 'Runtime'
  return <article className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4"><div className="flex items-start gap-3"><span className={`mt-1 h-2.5 w-2.5 shrink-0 rounded-full ${endpoint.status === 'active' ? 'bg-emerald-400' : 'bg-amber-400'}`} /><div className="min-w-0 flex-1"><h3 className="truncate text-sm font-medium text-zinc-100">{endpoint.displayName}</h3><p className="mt-1 text-xs leading-5 text-zinc-500">{runtimeSummary(endpoint)}</p></div><span className="rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] text-zinc-400">{surface}</span></div><div className="mt-4 flex items-center justify-between gap-3 border-t border-zinc-800 pt-3 text-[11px] text-zinc-500"><span className="truncate">{identity?.instanceLabel ?? identity?.terminalIdentifier ?? 'Identity pending'}</span><div className="flex items-center gap-2"><span className="shrink-0 capitalize">{endpoint.status === 'active' ? 'Ready' : endpoint.status === 'discovered' ? 'Found' : 'Needs setup'}</span><button type="button" onClick={onRemove} className="rounded px-2 py-1 text-zinc-500 hover:bg-red-950 hover:text-red-200">Remove</button></div></div></article>
}

function runtimeSummary(endpoint: Endpoint): string {
  const type = endpoint.runtimeTypeID.toLowerCase()
  if (type.includes('codex')) return 'Codex is available locally; probe once to verify the account and start Tasks.'
  if (type.includes('claude')) return 'Claude Code was found locally; probe once to verify the terminal and start Tasks.'
  if (type.includes('openworker')) return 'OpenWorker was found locally; probe once to connect its desktop session.'
  if (endpoint.provenance === 'artifact_only') return 'Evidence-only source. It can contribute files but cannot run a Task.'
  return endpoint.status === 'active' ? 'Verified local Runtime ready for Tasks.' : 'A Runtime candidate found on this Mac.'
}

function isPlaceholderAgent(agent: Agent): boolean {
  if (agent.preferredEndpointID !== undefined || (agent.capabilityTags?.length ?? 0) > 0) return false
  if (agent.shortName.toLowerCase() !== agent.displayName.toLowerCase()) return false
  const summaries: Record<string, string> = {
    builder: 'Implements task work in the workspace.',
    reviewer: 'Reviews work and approves changes.',
    researcher: 'Discovers and verifies context facts.',
    orchestrator: 'Plans and routes tasks across agents.',
  }
  return summaries[agent.displayName.toLowerCase()]?.toLowerCase() === agent.summary.toLowerCase()
}

function endpointLabel(endpoint: Endpoint): string {
  const identity = endpoint.instanceIdentity
  const suffix = identity?.instanceLabel ?? identity?.terminalIdentifier
  return suffix === undefined ? endpoint.displayName : `${endpoint.displayName} · ${suffix}`
}

function AgentCard({ agent, endpoint }: { agent: { id: string; displayName: string; shortName: string; role: string; summary: string; accentHex: string; availability: string }; endpoint?: Endpoint }) {
  const identity = endpoint?.instanceIdentity
  const surface = identity?.surfaceKind === 'desktop_app' || identity?.surfaceKind === 'desktop_application' ? 'Desktop' : identity?.surfaceKind === 'terminal_cli' ? 'Terminal' : 'Runtime'
  const terminal = identity?.terminalIdentifier ?? identity?.instanceLabel ?? identity?.stableInstanceKey
  return (
    <article className="flex h-[326px] min-h-[326px] flex-col justify-between rounded-xl border border-zinc-800 bg-zinc-900/70 p-4 transition hover:border-zinc-700">
      <div className="flex items-start gap-3">
        <span className="mt-1 h-3 w-3 shrink-0 rounded-full" style={{ backgroundColor: agent.accentHex }} />
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2">
            <h2 className="truncate font-medium text-zinc-100">{agent.displayName}</h2>
            <span className="shrink-0 rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] uppercase tracking-wider text-zinc-400">{agent.availability}</span>
          </div>
          <div className="mt-1 text-xs text-zinc-500">{agent.role} · @{agent.shortName}</div>
          <p className="mt-2 line-clamp-2 text-sm leading-5 text-zinc-400">{agent.summary || 'No description yet.'}</p>
        </div>
      </div>
      <div className="border-t border-zinc-800 pt-2">
        {endpoint === undefined ? (
          <span className="text-xs text-zinc-600">No endpoint linked</span>
        ) : (
          <div className="flex items-center gap-2 text-xs">
            <span className={`h-2 w-2 rounded-full ${endpoint.status === 'active' ? 'bg-emerald-400' : 'bg-amber-400'}`} />
            <span className="truncate text-zinc-300">{endpoint.displayName}</span>
            <span className="rounded bg-blue-950 px-1.5 py-0.5 text-[10px] text-blue-200">{surface}</span>
            {terminal !== undefined && <span className="ml-auto max-w-[10rem] truncate font-mono text-[10px] text-zinc-600" title={terminal}>{terminal}</span>}
          </div>
        )}
      </div>
    </article>
  )
}
