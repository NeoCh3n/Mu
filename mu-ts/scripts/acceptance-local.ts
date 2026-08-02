#!/usr/bin/env -S node --experimental-strip-types
// macOS P0 acceptance: REAL Codex / Claude Code CLI verification.
//
//   node scripts/acceptance-local.ts [--turn]
//
// Without --turn: probe only (executable presence, version, login state).
// With --turn: additionally runs one REAL read-only turn against each
// installed runtime (a small file-reading task in a temp workspace), using
// the exact production client paths (ClaudeCodeClient / CodexAppServerClient).

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { uuid } from '../packages/mu-core/src/identity.ts'
import { createTaskRecord } from '../packages/mu-core/src/models.ts'
import { createProjectContextPackRecord } from '../packages/mu-core/src/project-kernel/index.ts'
import {
  ClaudeCodeClient,
  claudeCodeExecutableURL,
} from '../packages/mu-core/src/runtime-clients/claude-code.ts'
import {
  CodexAppServerClient,
  codexExecutableURL,
} from '../packages/mu-core/src/runtime-clients/codex.ts'

const PROBE_TOKEN = `frame-rate-${Math.floor(Math.random() * 100000)}`

interface RuntimeReport {
  readonly runtime: string
  readonly executable: string
  readonly version: string
  readonly loggedIn: boolean
  readonly probeOK: boolean
  readonly turn: 'not_run' | 'passed' | 'failed'
  readonly turnOutput?: string
  readonly turnError?: string
  readonly turnMilliseconds?: number
}

function packFor(task: ReturnType<typeof createTaskRecord>) {
  return createProjectContextPackRecord({
    projectID: uuid(),
    taskID: task.id,
    workspaceID: uuid(),
    objective: task.objective,
    constraints: ['Stay read-only.'],
    contentSHA256: '0'.repeat(64),
  })
}

async function acceptClaude(
  executable: string,
  workspace: string,
  runTurn: boolean,
): Promise<RuntimeReport> {
  const client = new ClaudeCodeClient({ executableURL: executable })
  const probe = client.probe()
  const report: RuntimeReport = {
    runtime: 'Claude Code',
    executable,
    version: probe.version,
    loggedIn: probe.loggedIn,
    probeOK: true,
    turn: 'not_run',
  }
  if (!runTurn || !probe.loggedIn) return report

  const task = createTaskRecord({
    title: 'Acceptance probe',
    objective: `Read README.md and quote the line containing "${PROBE_TOKEN}".`,
    repositoryPath: workspace,
  })
  const started = Date.now()
  try {
    const result = await client.runReadOnlyTask({
      task,
      contextPack: packFor(task),
      promptOverride: `Read README.md in this workspace and reply with the exact line containing "${PROBE_TOKEN}". Keep the reply to one sentence.`,
    })
    report.turn = result.output.includes(PROBE_TOKEN) ? 'passed' : 'failed'
    report.turnOutput = result.output.slice(0, 200)
    report.turnError = result.output.includes(PROBE_TOKEN) ? undefined : 'Reply did not contain the probe token.'
  } catch (error) {
    report.turn = 'failed'
    report.turnError = error instanceof Error ? error.message : String(error)
  } finally {
    report.turnMilliseconds = Date.now() - started
  }
  return report
}

async function acceptCodex(
  executable: string,
  workspace: string,
  runTurn: boolean,
): Promise<RuntimeReport> {
  const client = new CodexAppServerClient({ executableURL: executable })
  const probe = await client.probe()
  const report: RuntimeReport = {
    runtime: 'Codex',
    executable,
    version: probe.userAgent,
    loggedIn: probe.signedIn,
    probeOK: true,
    turn: 'not_run',
  }
  // The app-server child holds stdio; always stop it so the process can exit.
  if (!runTurn || !probe.signedIn) {
    client.stop()
    return report
  }

  const task = createTaskRecord({
    title: 'Acceptance probe',
    objective: `Read README.md and quote the line containing "${PROBE_TOKEN}".`,
    repositoryPath: workspace,
  })
  const started = Date.now()
  try {
    const result = await client.runReadOnlyTask({
      task,
      contextPack: packFor(task),
      clientUserMessageID: `acceptance-${uuid()}`,
      timeoutMs: 180_000,
    })
    report.turn = result.output.includes(PROBE_TOKEN) ? 'passed' : 'failed'
    report.turnOutput = result.output.slice(0, 200)
    report.turnError = result.output.includes(PROBE_TOKEN) ? undefined : 'Reply did not contain the probe token.'
  } catch (error) {
    report.turn = 'failed'
    report.turnError = error instanceof Error ? error.message : String(error)
  } finally {
    report.turnMilliseconds = Date.now() - started
    client.stop()
  }
  return report
}

function printReport(reports: readonly RuntimeReport[]): void {
  console.log('')
  console.log('macOS P0 acceptance report')
  console.log('='.repeat(64))
  for (const report of reports) {
    console.log(`\n[${report.runtime}] ${report.probeOK ? 'probe OK' : 'probe FAIL'}`)
    console.log(`  executable : ${report.executable}`)
    console.log(`  version    : ${report.version}`)
    console.log(`  logged in  : ${report.loggedIn}`)
    console.log(`  real turn  : ${report.turn}${report.turnMilliseconds !== undefined ? ` (${report.turnMilliseconds} ms)` : ''}`)
    if (report.turnOutput !== undefined) console.log(`  output     : ${report.turnOutput}`)
    if (report.turnError !== undefined) console.log(`  error      : ${report.turnError}`)
  }
  const allProbeOK = reports.every((r) => r.probeOK)
  const turnsRun = reports.filter((r) => r.turn === 'passed').length
  const turnsFailed = reports.filter((r) => r.turn === 'failed').length
  console.log('\n' + '='.repeat(64))
  console.log(`Probe: ${allProbeOK ? 'ALL PASS' : 'FAILURES PRESENT'} · Real turns: ${turnsRun} passed, ${turnsFailed} failed`)
}

async function main(): Promise<void> {
  const runTurn = process.argv.includes('--turn')
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-acceptance-'))
  fs.writeFileSync(path.join(workspace, 'README.md'), `Mu acceptance probe: ${PROBE_TOKEN}\nSecond line.\n`)
  const step = (message: string): void => console.error(`[acceptance] ${message}`)

  const reports: RuntimeReport[] = []
  const claudeExe = process.env['MU_CLAUDE_EXECUTABLE'] ?? claudeCodeExecutableURL()
  if (claudeExe !== undefined && fs.existsSync(claudeExe)) {
    step(`probing Claude Code at ${claudeExe}`)
    reports.push(await acceptClaude(claudeExe, workspace, runTurn))
  } else {
    reports.push({
      runtime: 'Claude Code',
      executable: claudeExe ?? 'not found',
      version: '—',
      loggedIn: false,
      probeOK: false,
      turn: 'not_run',
    })
  }

  const codexExe = process.env['MU_CODEX_EXECUTABLE'] ?? codexExecutableURL()
  if (codexExe !== undefined && fs.existsSync(codexExe)) {
    step(`probing Codex at ${codexExe}`)
    reports.push(await acceptCodex(codexExe, workspace, runTurn))
  } else {
    reports.push({
      runtime: 'Codex',
      executable: codexExe ?? 'not found',
      version: '—',
      loggedIn: false,
      probeOK: false,
      turn: 'not_run',
    })
  }

  printReport(reports)
  fs.rmSync(workspace, { recursive: true, force: true })
}

void main()
