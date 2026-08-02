/** The two interface languages currently supported by Mu. */
export type UILanguage = 'en' | 'zh-Hans'

/**
 * Keep translation at the UI boundary. Runtime/provider names and values from
 * the local control plane are intentionally not translated here.
 */
export function text(language: UILanguage, english: string, simplifiedChinese: string): string {
  return language === 'zh-Hans' ? simplifiedChinese : english
}

export function statusText(language: UILanguage, status: string): string {
  const labels: Record<string, [string, string]> = {
    ready: ['Ready', '就绪'],
    running: ['Running', '运行中'],
    blocked: ['Blocked', '已阻塞'],
    completed: ['Completed', '已完成'],
    failed: ['Failed', '失败'],
    cancelled: ['Cancelled', '已取消'],
    active: ['Active', '活跃'],
    discovered: ['Found', '已发现'],
    proposed: ['Proposed', '待确认'],
    accepted: ['Accepted', '已接受'],
    rejected: ['Rejected', '已拒绝'],
  }
  const label = labels[status]
  return label === undefined ? status : text(language, label[0], label[1])
}
