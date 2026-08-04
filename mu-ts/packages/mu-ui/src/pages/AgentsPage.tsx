import { useMemo, useState } from 'react'
import type { Endpoint } from '../api.ts'
import { api } from '../api.ts'
import { useMuUISettings, useQuery } from '../hooks.ts'
import { text } from '../i18n.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

const RUNTIME_PROFILES = [
  { id: 'codex', name: 'Codex', runtimeTypeID: 'openai.codex/app-server', summary: 'Configure Codex Desktop or CLI, then choose the verified instance in the Project composer.' },
  { id: 'claude', name: 'Claude Code', runtimeTypeID: 'anthropic.claude-code/cli', summary: 'Configure a Claude Code terminal, then choose that terminal in the Project composer.' },
  { id: 'pi', name: 'Pi', runtimeTypeID: 'pi/coding-agent', summary: 'Choose the Pi executable once, then select it in the Project composer.' },
  { id: 'opencode', name: 'OpenCode', runtimeTypeID: 'opencode/cli', summary: 'Choose the OpenCode executable once, then select it in the Project composer.' },
] as const

export function AgentsPage() {
  const { settings } = useMuUISettings()
  const t = (english: string, simplifiedChinese: string) => text(settings.language, english, simplifiedChinese)
  const { data: endpointData, error, reload: reloadEndpoints } = useQuery(() => api.listEndpoints())
  const [showOtherRuntimes, setShowOtherRuntimes] = useState(false)
  const [cleaningRuntimes, setCleaningRuntimes] = useState(false)
  const [runtimeSetup, setRuntimeSetup] = useState<(typeof RUNTIME_PROFILES)[number]['id'] | undefined>()
  const [runtimePath, setRuntimePath] = useState('')
  const [configuringRuntime, setConfiguringRuntime] = useState(false)
  const [probingRuntime, setProbingRuntime] = useState<string | undefined>()
  const [runtimeSettingsEndpoint, setRuntimeSettingsEndpoint] = useState<Endpoint | undefined>()
  const [settingsDefaultModel, setSettingsDefaultModel] = useState('')
  const [settingsModelOptions, setSettingsModelOptions] = useState('')
  const [settingsPermissionModel, setSettingsPermissionModel] = useState('fine_grained')
  const [savingRuntimeSettings, setSavingRuntimeSettings] = useState(false)
  const endpoints = endpointData?.endpoints ?? []

  const primaryEndpoints = useMemo(() => {
    const useful = endpoints.filter(isUsefulEndpoint)
    const groups = new Map<string, Endpoint[]>()
    for (const endpoint of useful) {
      const key = endpointIdentityKey(endpoint)
      groups.set(key, [...(groups.get(key) ?? []), endpoint])
    }
    return [...groups.values()]
      .map((items) => [...items].sort((left, right) => Number(right.status === 'active') - Number(left.status === 'active') || right.lastProbedAt.localeCompare(left.lastProbedAt))[0])
      .filter((endpoint): endpoint is Endpoint => endpoint !== undefined)
      .sort((left, right) => left.displayName.localeCompare(right.displayName))
  }, [endpoints])

  const otherEndpoints = useMemo(() => {
    const primaryIDs = new Set(primaryEndpoints.map((endpoint) => endpoint.id))
    return endpoints.filter((endpoint) => !primaryIDs.has(endpoint.id))
  }, [endpoints, primaryEndpoints])

  const duplicateDiscoveredIDs = useMemo(
    () => duplicateDiscoveredEndpointIDs(otherEndpoints),
    [otherEndpoints],
  )

  function configuredEndpoint(profile: (typeof RUNTIME_PROFILES)[number]): Endpoint | undefined {
    return endpoints.find((endpoint) => endpoint.runtimeTypeID === profile.runtimeTypeID && isConfiguredEndpoint(endpoint))
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

  function openRuntimeSettings(endpoint: Endpoint): void {
    setRuntimeSettingsEndpoint(endpoint)
    setSettingsDefaultModel(endpoint.nativeConfiguration?.default_model ?? '')
    setSettingsModelOptions(endpoint.nativeConfiguration?.model_options?.split(',').map((value) => value.trim()).filter(Boolean).join(', ') ?? '')
    setSettingsPermissionModel(endpoint.permissionModel ?? 'fine_grained')
  }

  async function saveRuntimeSettings(): Promise<void> {
    if (runtimeSettingsEndpoint === undefined) return
    setSavingRuntimeSettings(true)
    try {
      await api.updateEndpointSettings(runtimeSettingsEndpoint.id, {
        permissionModel: settingsPermissionModel,
        defaultModel: settingsDefaultModel.trim() === '' ? undefined : settingsDefaultModel.trim(),
        modelOptions: settingsModelOptions.split(',').map((value) => value.trim()).filter(Boolean),
      })
      setRuntimeSettingsEndpoint(undefined)
      reloadEndpoints()
    } catch (reason) {
      console.error(reason)
    } finally {
      setSavingRuntimeSettings(false)
    }
  }

  return (
    <Page title={t('Agents & Runtimes', 'Agents 与运行时')} subtitle={t('Choose a configured local Runtime when a Project starts. Agent identities are created only when you explicitly need a reusable alias.', 'Project 开始任务时选择已配置的本地 Runtime。只有明确需要可复用别名时，才创建 Agent 身份。')}>
      {error !== undefined && <ErrorBanner message={error} />}

      <section className="mb-8 rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
        <div className="mb-3">
          <h2 className="text-sm font-semibold text-zinc-200">{t('Runtime setup', '运行时配置')}</h2>
          <p className="mt-1 max-w-3xl text-xs leading-5 text-zinc-500">{t('Configure the local LLM host here. No Agent identity is required before a Project starts; select the Runtime in the Project composer when you work.', '在这里配置本地 LLM host。Project 开始前不需要定义 Agent 身份；工作时在 Project 输入框中选择 Runtime。')}</p>
        </div>
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          {RUNTIME_PROFILES.map((profile) => {
            const endpoint = configuredEndpoint(profile)
            const ready = endpoint?.status === 'active'
            const needsSetup = endpoint !== undefined && !ready
            return (
              <article key={profile.id} className="rounded-lg border border-zinc-800/80 bg-zinc-950/40 p-3">
                <div className="flex items-center justify-between gap-2">
                  <h3 className="text-sm font-medium text-zinc-100">{profile.name}</h3>
                  <span className={`rounded-full px-2 py-0.5 text-[10px] ${ready ? 'bg-emerald-950 text-emerald-200' : needsSetup ? 'bg-amber-950 text-amber-200' : 'bg-zinc-800 text-zinc-500'}`}>
                    {ready ? t('Ready', '就绪') : needsSetup ? t('Needs setup', '需要配置') : t('Not configured', '未配置')}
                  </span>
                </div>
                <p className="mt-2 min-h-10 text-xs leading-5 text-zinc-500">{runtimeProfileSummary(profile, settings.language)}</p>
                <div className="mt-3 flex items-center justify-between gap-2">
                  <span className="text-[11px] font-medium text-violet-300">{t('Select in Project chat', '在 Project 聊天中选择')}</span>
                  {ready ? <span className="text-[11px] text-emerald-300">{t('Configured', '已配置')}</span> : endpoint !== undefined && (profile.id === 'codex' || profile.id === 'claude') ? <button type="button" onClick={() => void probeRuntime(profile)} disabled={probingRuntime !== undefined} className="rounded-md bg-zinc-800 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-zinc-700 disabled:opacity-50">{probingRuntime === profile.id ? t('Checking…', '检查中…') : t('Check now', '立即检查')}</button> : <button type="button" onClick={() => { setRuntimeSetup(profile.id); setRuntimePath(endpoint?.nativeConfiguration?.executable ?? '') }} className="rounded-md bg-zinc-800 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-zinc-700">{endpoint === undefined ? t('Configure', '配置') : t('Finish setup', '完成配置')}</button>}
                </div>
              </article>
            )
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

      <section>
        <div className="mb-3 flex items-end justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold text-zinc-200">{t('Runtime endpoints', '运行时 endpoints')}</h2>
            <p className="mt-1 max-w-2xl text-xs leading-5 text-zinc-500">{t('This is the registry for the same local Runtimes configured above. Desktop and terminal instances remain separate when Mu has concrete identity evidence.', '这里显示上面配置的同一组本地 Runtime。Mu 有明确身份证据时，会分开显示 Desktop 和不同 terminal 实例。')}</p>
          </div>
          <div className="flex items-center gap-2">
            <span className="text-xs text-zinc-600">{primaryEndpoints.length} {t('useful', '个有用')} · {otherEndpoints.length} {t('unverified', '个未验证')}</span>
            {duplicateDiscoveredIDs.length > 0 && <button type="button" onClick={() => void cleanDuplicateRuntimes()} disabled={cleaningRuntimes} className="rounded-md border border-amber-700/60 px-2.5 py-1 text-[11px] text-amber-200 hover:bg-amber-950/50 disabled:opacity-40">{cleaningRuntimes ? t('Cleaning…', '清理中…') : `${t('Close', '关闭')} ${duplicateDiscoveredIDs.length} ${t('duplicates', '个重复项')}`}</button>}
          </div>
        </div>
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          {primaryEndpoints.map((endpoint) => <RuntimeCompactCard key={endpoint.id} endpoint={endpoint} onRemove={() => void removeEndpoint(endpoint)} onConfigure={() => openRuntimeSettings(endpoint)} language={settings.language} />)}
          {primaryEndpoints.length === 0 && <Empty message={t('No useful runtime endpoints yet.', '还没有可用的运行时 endpoint。')} />}
        </div>
        {otherEndpoints.length > 0 && <div className="mt-3 rounded-xl border border-zinc-800 bg-zinc-950/40 p-3"><button type="button" onClick={() => setShowOtherRuntimes((current) => !current)} className="flex w-full items-center justify-between text-left text-sm font-medium text-zinc-300"><span>{t('Other discovered runtimes', '其他已发现的运行时')} · {otherEndpoints.length}</span><span className="text-xs text-zinc-600">{showOtherRuntimes ? t('Hide', '隐藏') : t('Show', '显示')}</span></button>{showOtherRuntimes && <div className="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-3">{otherEndpoints.map((endpoint) => <RuntimeCompactCard key={endpoint.id} endpoint={endpoint} onRemove={() => void removeEndpoint(endpoint)} onConfigure={() => openRuntimeSettings(endpoint)} language={settings.language} />)}</div>}</div>}
        {runtimeSettingsEndpoint !== undefined && <form onSubmit={(event) => { event.preventDefault(); void saveRuntimeSettings() }} className="mt-4 rounded-xl border border-violet-900/60 bg-violet-950/20 p-4"><div className="mb-3 flex items-center justify-between gap-3"><div><h3 className="text-sm font-medium text-violet-100">{t('Configure runtime', '配置运行时')} · {runtimeSettingsEndpoint.displayName}</h3><p className="mt-1 text-xs leading-5 text-zinc-400">{t('Model is sent to the host for the next turn. Mu still enforces its current read-only safety boundary.', '模型会在下一轮发送给 host。Mu 仍会强制当前的只读安全边界。')}</p></div><button type="button" onClick={() => setRuntimeSettingsEndpoint(undefined)} className="rounded px-2 py-1 text-xs text-zinc-500 hover:bg-zinc-800">{t('Cancel', '取消')}</button></div><div className="grid gap-3 md:grid-cols-3"><label className="text-xs text-zinc-400"><span className="mb-1 block">{t('Default model', '默认模型')}</span><input value={settingsDefaultModel} onChange={(event) => setSettingsDefaultModel(event.target.value)} placeholder="host default" className="w-full rounded-md border border-zinc-700 bg-zinc-950 px-3 py-2 font-mono text-xs text-zinc-100" /></label><label className="text-xs text-zinc-400"><span className="mb-1 block">{t('Model IDs', '模型 ID')}</span><input value={settingsModelOptions} onChange={(event) => setSettingsModelOptions(event.target.value)} placeholder="model-a, model-b" className="w-full rounded-md border border-zinc-700 bg-zinc-950 px-3 py-2 font-mono text-xs text-zinc-100" /></label><label className="text-xs text-zinc-400"><span className="mb-1 block">{t('Permission level', '权限等级')}</span><select value={settingsPermissionModel} onChange={(event) => setSettingsPermissionModel(event.target.value)} className="w-full rounded-md border border-zinc-700 bg-zinc-950 px-3 py-2 text-xs text-zinc-100"><option value="fine_grained">Fine-grained</option><option value="prompt_gate">Prompt gate</option><option value="all_or_nothing">All or nothing</option><option value="none">No permissions</option><option value="unknown">Runtime-defined</option></select></label></div><div className="mt-3 flex justify-end"><button type="submit" disabled={savingRuntimeSettings} className="rounded-md bg-violet-600 px-3 py-2 text-xs text-white disabled:opacity-40">{savingRuntimeSettings ? t('Saving…', '保存中…') : t('Save settings', '保存设置')}</button></div></form>}
      </section>
    </Page>
  )
}

function hasRuntimeEvidence(endpoint: Endpoint): boolean {
  if (endpoint.status !== 'discovered') return true
  const config = endpoint.nativeConfiguration ?? {}
  if (['executable', 'application_path', 'bundle_identifier', 'terminal_id', 'tty'].some((key) => typeof config[key] === 'string' && config[key]!.trim() !== '')) return true
  if (Object.entries(config).some(([key, value]) => key.startsWith('identity.') && value.trim() !== '')) return true
  const identity = endpoint.instanceIdentity
  if (identity === undefined) return false
  if (identity.identityBasis !== 'installation') return true
  if (identity.executablePath !== undefined || identity.terminalIdentifier !== undefined || identity.surfaceKind === 'desktop_application') return true
  return identity.stableInstanceKey !== `${endpoint.runtimeTypeID}:${endpoint.id}`
}

function isConfiguredEndpoint(endpoint: Endpoint): boolean {
  return endpoint.status === 'active' || endpoint.nativeConfiguration?.['identity.native_source'] === 'user_configured'
}

function isUsefulEndpoint(endpoint: Endpoint): boolean {
  return hasRuntimeEvidence(endpoint)
}

function runtimeProfileSummary(profile: (typeof RUNTIME_PROFILES)[number], language: 'en' | 'zh-Hans'): string {
  if (language === 'zh-Hans') {
    if (profile.id === 'codex') return '配置 Codex Desktop 或 CLI，完成后在 Project 聊天输入框中选择具体实例。'
    if (profile.id === 'claude') return '配置 Claude Code terminal，完成后在 Project 聊天输入框中选择具体 terminal。'
    if (profile.id === 'pi') return '配置一次 Pi 可执行文件，然后在 Project 聊天输入框中选择它。'
    return '配置一次 OpenCode 可执行文件，然后在 Project 聊天输入框中选择它。'
  }
  return profile.summary
}

function endpointIdentityKey(endpoint: Endpoint): string {
  const identity = endpoint.instanceIdentity
  if (identity?.stableInstanceKey !== undefined) return `identity:${identity.provider?.rawValue ?? endpoint.runtimeTypeID}:${identity.stableInstanceKey}`
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
  return [...groups.values()].flatMap((items) => items.sort((left, right) => right.lastProbedAt.localeCompare(left.lastProbedAt)).slice(1).map((endpoint) => endpoint.id))
}

function RuntimeCompactCard({ endpoint, onRemove, onConfigure, language }: { endpoint: Endpoint; onRemove: () => void; onConfigure: () => void; language: 'en' | 'zh-Hans' }) {
  const identity = endpoint.instanceIdentity
  const surface = identity?.surfaceKind === 'desktop_app' || identity?.surfaceKind === 'desktop_application' ? 'Desktop' : identity?.surfaceKind === 'terminal_cli' ? 'Terminal' : 'Runtime'
  const state = endpoint.status === 'active' ? text(language, 'Ready', '就绪') : endpoint.status === 'discovered' && hasRuntimeEvidence(endpoint) ? text(language, 'Found', '已发现') : endpoint.status === 'discovered' ? text(language, 'Unverified', '未验证') : text(language, 'Needs setup', '需要配置')
  const configuredModel = endpoint.nativeConfiguration?.default_model ?? text(language, 'Runtime default', 'Runtime 默认')
  const configuredPermission = endpoint.permissionModel ?? 'unknown'
  return <article className="rounded-xl border border-zinc-800 bg-zinc-900/70 p-4"><div className="flex items-start gap-3"><span className={`mt-1 h-2.5 w-2.5 shrink-0 rounded-full ${endpoint.status === 'active' ? 'bg-emerald-400' : endpoint.status === 'discovered' && hasRuntimeEvidence(endpoint) ? 'bg-amber-400' : 'bg-zinc-600'}`} /><div className="min-w-0 flex-1"><h3 className="truncate text-sm font-medium text-zinc-100">{endpoint.displayName}</h3><p className="mt-1 text-xs leading-5 text-zinc-500">{runtimeSummary(endpoint, language)}</p><p className="mt-2 truncate text-[11px] text-zinc-500">{text(language, 'Model', '模型')}: {configuredModel} · {text(language, 'Permissions', '权限')}: {configuredPermission}</p></div><span className="rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] text-zinc-400">{surface}</span></div><div className="mt-4 flex items-center justify-between gap-3 border-t border-zinc-800 pt-3 text-[11px] text-zinc-500"><span className="truncate">{identity?.instanceLabel ?? identity?.terminalIdentifier ?? text(language, 'Identity pending', '等待身份')}</span><div className="flex items-center gap-2"><span className="shrink-0">{state}</span><button type="button" onClick={onConfigure} className="rounded px-2 py-1 text-zinc-400 hover:bg-zinc-800">{text(language, 'Configure', '配置')}</button><button type="button" onClick={onRemove} className="rounded px-2 py-1 text-zinc-500 hover:bg-red-950 hover:text-red-200">{text(language, 'Remove', '移除')}</button></div></div></article>
}

function runtimeSummary(endpoint: Endpoint, language: 'en' | 'zh-Hans'): string {
  const type = endpoint.runtimeTypeID.toLowerCase()
  if (type.includes('codex')) return text(language, 'Configure Codex and probe it before starting a Task.', '配置 Codex 并完成检查后，才能开始任务。')
  if (type.includes('claude')) return text(language, 'Configure a Claude Code terminal and probe it before starting a Task.', '配置 Claude Code terminal 并完成检查后，才能开始任务。')
  if (type.includes('openworker')) return text(language, 'This desktop runtime is kept for the native compatibility path.', '这个桌面运行时保留在原生兼容路径中。')
  if (endpoint.provenance === 'artifact_only') return text(language, 'Evidence-only source. It cannot run a Task.', '仅证据来源；不能执行任务。')
  if (endpoint.status === 'discovered' && !hasRuntimeEvidence(endpoint)) return text(language, 'No concrete local evidence is recorded yet. Remove it or configure the Runtime.', '还没有记录明确的本地证据。可以移除，或重新配置这个 Runtime。')
  return endpoint.status === 'active' ? text(language, 'Verified local Runtime ready for Tasks.', '已验证的本地 Runtime，可以执行任务。') : text(language, 'Runtime needs setup before it can run a Task.', 'Runtime 需要完成配置后才能执行任务。')
}
