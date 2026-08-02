import { useMemo, useState } from 'react'
import type { Endpoint } from '../api.ts'
import { api } from '../api.ts'
import { useMuUISettings, useQuery } from '../hooks.ts'
import { text } from '../i18n.ts'
import { Empty, ErrorBanner, Page } from './ProjectsPage.tsx'

export function EndpointsPage() {
  const { settings } = useMuUISettings()
  const t = (english: string, simplifiedChinese: string) => text(settings.language, english, simplifiedChinese)
  const { data, error, reload } = useQuery(() => api.listEndpoints())
  const [cleaning, setCleaning] = useState(false)
  const endpoints = data?.endpoints ?? []
  const primaryEndpoints = useMemo(() => {
    const groups = new Map<string, Endpoint[]>()
    for (const endpoint of endpoints.filter(isUsefulEndpoint)) {
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
  const duplicateIDs = useMemo(() => duplicateDiscoveredEndpointIDs(otherEndpoints), [otherEndpoints])

  async function probe(): Promise<void> {
    try {
      await api.probeEndpoints()
      reload()
    } catch (reason) {
      console.error(reason)
    }
  }

  async function remove(endpoint: Endpoint): Promise<void> {
    if (!window.confirm(t('Remove “' + endpoint.displayName + '” from discovered runtimes?', '从已发现的运行时中移除“' + endpoint.displayName + '”？'))) return
    try {
      await api.removeEndpoint(endpoint.id)
      reload()
    } catch (reason) {
      console.error(reason)
    }
  }

  async function cleanDuplicates(): Promise<void> {
    if (duplicateIDs.length === 0) return
    setCleaning(true)
    try {
      await api.removeDuplicateDiscoveredEndpoints()
      reload()
    } catch (reason) {
      console.error(reason)
    } finally {
      setCleaning(false)
    }
  }

  return (
    <Page title={t('Runtime registry', '运行时注册表')} subtitle={t('Mu shows the few local runtimes that can actually help with work.', 'Mu 只显示真正可以帮助工作的本地运行时。')}>
      {error !== undefined && <ErrorBanner message={error} />}
      <section className="mb-5 rounded-xl border border-zinc-800 bg-zinc-900/70 p-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold text-zinc-200">{t('How discovery works', '发现标准')}</h2>
            <p className="mt-1 max-w-3xl text-xs leading-5 text-zinc-500">{t('Found means Mu saw a local executable or bundle. Useful means it has a stable identity or passed a probe. Duplicate unverified records are grouped conservatively; cleanup keeps the newest copy.', '“已发现”表示 Mu 看到了本地可执行文件或 bundle。“有用”表示它有稳定身份或已通过检查。未验证的重复记录会保守分组，清理时保留最新的一条。')}</p>
          </div>
          <div className="flex gap-2">
            {duplicateIDs.length > 0 && <button type="button" onClick={() => void cleanDuplicates()} disabled={cleaning} className="rounded-md border border-amber-700/60 px-3 py-1.5 text-xs text-amber-200 hover:bg-amber-950/50 disabled:opacity-40">{cleaning ? t('Cleaning…', '清理中…') : t('Close duplicates', '关闭重复项')}</button>}
            <button type="button" onClick={() => void probe()} className="rounded-md bg-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-200 hover:bg-zinc-700">{t('Check again', '再次检查')}</button>
          </div>
        </div>
      </section>
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {primaryEndpoints.map((endpoint) => <EndpointCard key={endpoint.id} endpoint={endpoint} language={settings.language} onProbe={() => void probe()} onRemove={() => void remove(endpoint)} />)}
        {primaryEndpoints.length === 0 && <Empty message={t('No useful runtime endpoints yet.', '还没有可用的运行时 endpoint。')} />}
      </div>
      {otherEndpoints.length > 0 && <section className="mt-4 rounded-xl border border-zinc-800 bg-zinc-950/40 p-3"><div className="mb-3 flex items-center justify-between"><div><h2 className="text-sm font-medium text-zinc-300">{t('Other discovered runtimes', '其他已发现的运行时')}</h2><p className="mt-1 text-xs text-zinc-600">{otherEndpoints.length} {t('unverified record(s); each can be removed.', '条未验证记录；每条都可以移除。')}</p></div><span className="text-xs text-zinc-600">{duplicateIDs.length} {t('duplicate(s)', '个重复项')}</span></div><div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">{otherEndpoints.map((endpoint) => <EndpointCard key={endpoint.id} endpoint={endpoint} language={settings.language} onProbe={() => void probe()} onRemove={() => void remove(endpoint)} />)}</div></section>}
      {endpoints.length === 0 && <Empty message={t('No runtimes registered.', '还没有注册运行时。')} />}
    </Page>
  )
}

function EndpointCard({ endpoint, language, onProbe, onRemove }: { endpoint: Endpoint; language: 'en' | 'zh-Hans'; onProbe: () => void; onRemove: () => void }) {
  const t = (english: string, simplifiedChinese: string) => text(language, english, simplifiedChinese)
  const identity = endpoint.instanceIdentity
  const surface = identity?.surfaceKind === 'desktop_app' || identity?.surfaceKind === 'desktop_application' ? 'Desktop' : identity?.surfaceKind === 'terminal_cli' ? 'Terminal' : 'Runtime'
  const state = endpoint.status === 'active' ? t('Ready', '就绪') : endpoint.status === 'discovered' ? t('Found', '已发现') : t('Needs setup', '需要配置')
  return <article className="flex min-h-[190px] flex-col rounded-xl border border-zinc-800 bg-zinc-900/70 p-4"><div className="flex items-start gap-3"><span className={endpoint.status === 'active' ? 'mt-1 h-2.5 w-2.5 shrink-0 rounded-full bg-emerald-400' : 'mt-1 h-2.5 w-2.5 shrink-0 rounded-full bg-amber-400'} /><div className="min-w-0 flex-1"><div className="truncate font-medium text-zinc-100">{endpoint.displayName}</div><div className="mt-1 text-xs text-zinc-500">{runtimeSummary(endpoint, language)}</div></div><span className="rounded-full bg-zinc-800 px-2 py-0.5 text-[10px] text-zinc-400">{surface}</span></div><div className="mt-4 flex items-center justify-between gap-3 text-xs text-zinc-500"><span className="truncate">{identity?.instanceLabel ?? identity?.terminalIdentifier ?? t('Identity pending', '等待身份')}</span><span>{state}</span></div><div className="mt-auto flex justify-end gap-2 border-t border-zinc-800 pt-3"><button type="button" onClick={onProbe} className="rounded-md bg-zinc-800 px-2.5 py-1 text-[11px] text-zinc-300 hover:bg-zinc-700">{t('Check', '检查')}</button><button type="button" onClick={onRemove} className="rounded-md px-2.5 py-1 text-[11px] text-zinc-500 hover:bg-red-950 hover:text-red-200">{t('Remove', '移除')}</button></div></article>
}

function isUsefulEndpoint(endpoint: Endpoint): boolean {
  return endpoint.status !== 'discovered' || endpoint.instanceIdentity !== undefined || endpoint.nativeConfiguration !== undefined
}

function endpointIdentityKey(endpoint: Endpoint): string {
  const identity = endpoint.instanceIdentity
  if (identity?.stableInstanceKey !== undefined) return 'identity:' + (identity.provider?.rawValue ?? endpoint.runtimeTypeID) + ':' + identity.stableInstanceKey
  const executable = endpoint.nativeConfiguration?.executable
  if (executable !== undefined) return 'executable:' + endpoint.runtimeTypeID + ':' + executable
  return 'unidentified:' + endpoint.runtimeTypeID + ':' + endpoint.displayName.trim().toLowerCase()
}

function duplicateDiscoveredEndpointIDs(endpoints: Endpoint[]): string[] {
  const groups = new Map<string, Endpoint[]>()
  for (const endpoint of endpoints.filter((candidate) => candidate.status === 'discovered' && !isUsefulEndpoint(candidate))) {
    const key = endpointIdentityKey(endpoint)
    groups.set(key, [...(groups.get(key) ?? []), endpoint])
  }
  return [...groups.values()].flatMap((items) => items.sort((left, right) => right.lastProbedAt.localeCompare(left.lastProbedAt)).slice(1).map((endpoint) => endpoint.id))
}

function runtimeSummary(endpoint: Endpoint, language: 'en' | 'zh-Hans' = 'en'): string {
  const type = endpoint.runtimeTypeID.toLowerCase()
  if (type.includes('codex')) return text(language, 'Codex is available locally; check once to verify the account.', '本机已找到 Codex；检查一次即可验证账号。')
  if (type.includes('claude')) return text(language, 'Claude Code was found locally; check once to verify the terminal.', '本机已找到 Claude Code；检查一次即可验证 terminal。')
  if (type.includes('openworker')) return text(language, 'OpenWorker was found locally; check once to connect its desktop session.', '本机已找到 OpenWorker；检查一次即可连接桌面会话。')
  if (endpoint.provenance === 'artifact_only') return text(language, 'Evidence-only source; it cannot run a Task.', '仅证据来源；不能执行任务。')
  return endpoint.status === 'active' ? text(language, 'Verified local Runtime ready for Tasks.', '已验证的本地 Runtime，可以执行任务。') : text(language, 'A Runtime candidate found on this Mac.', '在这台 Mac 上发现的 Runtime 候选。')
}
