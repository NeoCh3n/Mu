import { COMPLETION_TOAST_DURATIONS, useMuUISettings } from '../hooks.ts'
import { text } from '../i18n.ts'
import { Page } from './ProjectsPage.tsx'

export function SettingsPage() {
  const { settings, updateSettings } = useMuUISettings()
  const t = (english: string, simplifiedChinese: string) => text(settings.language, english, simplifiedChinese)

  return (
    <Page title={t('Settings', '设置')} subtitle={t("Configure Mu's local control plane and task completion notifications.", '配置 Mu 的本地控制平面和任务完成通知。')}>
      <div className="space-y-4">
        <section className="mu-panel">
          <PanelHeading title={t('Language', '语言')} subtitle={t("Choose the language used for Mu's guidance and settings.", '选择 Mu 提示和设置使用的语言。')} />
          <div className="flex items-center justify-between gap-5 py-2">
            <div>
              <div className="text-sm font-medium text-zinc-200">{t('Interface language', '界面语言')}</div>
              <div className="mt-1 text-xs leading-5 text-zinc-500">{t('Only Simplified Chinese and English are available.', '目前仅支持简体中文和英文。')}</div>
            </div>
            <select
              aria-label={t('Interface language', '界面语言')}
              value={settings.language}
              onChange={(event) => updateSettings({ language: event.target.value === 'zh-Hans' ? 'zh-Hans' : 'en' })}
              className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm text-zinc-200"
            >
              <option value="zh-Hans">简体中文</option>
              <option value="en">English</option>
            </select>
          </div>
        </section>

        <section className="mu-panel">
          <PanelHeading title={t('Local control plane', '本地控制平面')} subtitle={t('This installation owns the state; no hosted relay is required.', '状态由本机管理，无需托管中继。')} />
          <div className="divide-y divide-zinc-800/80">
            <SettingRow label={t('Status', '状态')} value={t('Running locally', '本机运行中')} tone="mint" />
            <SettingRow label={t('Persistence', '持久化')} value={t('SQLite + content-addressed storage', 'SQLite + 内容寻址存储')} tone="violet" />
            <SettingRow label={t('State', '状态保存')} value={t('Saved continuously', '持续自动保存')} tone="coral" />
            <SettingRow label={t('Runtime boundary', '运行时边界')} value={t('Endpoint-scoped Codex, Claude Code, and native compatibility paths', '按 endpoint 区分的 Codex、Claude Code 和原生兼容路径')} tone="blue" />
          </div>
        </section>

        <section className="mu-panel">
          <PanelHeading title={t('Task completion notifications', '任务完成通知')} subtitle={t('Show a bottom-right confirmation after a runtime finishes a Project Task.', '运行时完成 Project 任务后，在右下角显示确认提示。')} />
          <div className="flex items-start justify-between gap-5 border-b border-zinc-800/80 py-3">
            <div>
              <div className="text-sm font-medium text-zinc-200">{t('Show task completion notifications', '显示任务完成通知')}</div>
              <div className="mt-1 text-xs leading-5 text-zinc-500">{t('The notification can be dismissed immediately or disappears automatically.', '通知可以立即关闭，也会按设定时间自动消失。')}</div>
            </div>
            <button
              type="button"
              role="switch"
              aria-label={t('Show task completion notifications', '显示任务完成通知')}
              aria-checked={settings.completionNotificationsEnabled}
              onClick={() => updateSettings({ completionNotificationsEnabled: !settings.completionNotificationsEnabled })}
              className={`relative h-6 w-11 shrink-0 rounded-full transition ${settings.completionNotificationsEnabled ? 'bg-emerald-500' : 'bg-zinc-700'}`}
            >
              <span className={`absolute top-1 h-4 w-4 rounded-full bg-white transition ${settings.completionNotificationsEnabled ? 'left-6' : 'left-1'}`} />
            </button>
          </div>
          <div className="flex items-center justify-between gap-5 py-3">
            <div>
              <div className="text-sm font-medium text-zinc-200">{t('Display time', '显示时长')}</div>
              <div className="mt-1 text-xs leading-5 text-zinc-500">{t('How long the bottom-right completion notice stays visible.', '右下角完成通知显示多久。')}</div>
            </div>
            <select
              value={settings.completionToastDuration}
              disabled={!settings.completionNotificationsEnabled}
              onChange={(event) => updateSettings({ completionToastDuration: Number(event.target.value) })}
              className="rounded-lg border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm text-zinc-200 disabled:opacity-40"
            >
              {COMPLETION_TOAST_DURATIONS.map((seconds) => <option key={seconds} value={seconds}>{t(`${seconds} seconds`, `${seconds} 秒`)}</option>)}
            </select>
          </div>
        </section>

        <section className="mu-panel">
          <PanelHeading title={t('Runtime configuration', '运行时配置')} subtitle={t('Configure a local LLM host from Agents, then select it below the Project chat composer.', '先在 Agents 中配置本地 LLM host，再在 Project 聊天输入框下方选择它。')} />
          <div className="divide-y divide-zinc-800/80">
            <SettingRow label="Codex" value={t('Auto-detected Desktop or CLI endpoint; select the exact instance in Project chat', '自动发现 Desktop 或 CLI endpoint；在 Project 聊天中选择具体实例。')} tone="violet" />
            <SettingRow label="Claude Code" value={t('Auto-detected local terminal endpoint; select the exact terminal in Project chat', '自动发现本地 terminal endpoint；在 Project 聊天中选择具体 terminal。')} tone="coral" />
            <SettingRow label="Pi" value={t('Choose the local CLI path in Agents, then select it in Project chat', '在 Agents 中选择本地 CLI 路径，再在 Project 聊天中选择。')} tone="mint" />
            <SettingRow label="OpenCode" value={t('Choose the local CLI path in Agents, then select it in Project chat', '在 Agents 中选择本地 CLI 路径，再在 Project 聊天中选择。')} tone="blue" />
          </div>
        </section>

        <p className="text-xs text-zinc-600">{t('These preferences are stored locally in this browser. Project state and runtime records continue to save automatically in the local control plane.', '这些偏好保存在本浏览器中。Project 状态和运行时记录会继续自动保存到本地控制平面。')}</p>
      </div>
    </Page>
  )
}

function PanelHeading({ title, subtitle }: { title: string; subtitle: string }) {
  return <div className="mb-3"><h2 className="text-sm font-semibold text-zinc-200">{title}</h2><p className="mt-1 text-xs text-zinc-500">{subtitle}</p></div>
}

function SettingRow({ label, value, tone }: { label: string; value: string; tone: 'violet' | 'coral' | 'mint' | 'blue' }) {
  return <div className="flex items-center gap-3 py-3"><span className={`mu-icon-chip mu-icon-${tone} text-[10px]`}>●</span><div className="min-w-0 flex-1"><div className="text-sm font-medium text-zinc-200">{label}</div><div className="mt-1 text-xs leading-5 text-zinc-500">{value}</div></div></div>
}
