import { MuError } from '../errors.ts'
import {
  createLocalHarness,
  LocalChildProcessHarness,
  type LocalChildProcessHarnessOptions,
} from './local-child-process.ts'
import {
  createQMHarness,
  QMHTTPHarness,
  type QMHTTPHarnessOptions,
} from './qm-http.ts'
import type { Harness, HarnessMode } from './types.ts'

export * from './types.ts'
export * from './local-child-process.ts'
export * from './qm-http.ts'
export * from './qm-mapping.ts'

export interface HarnessConfiguration {
  readonly mode: HarnessMode
  readonly local?: LocalChildProcessHarnessOptions
  readonly qm?: QMHTTPHarnessOptions
}

/**
 * Config-driven harness selection, per the plan:
 *   const harness = config.mode === 'qm'
 *     ? createQMHarness({ baseUrl, sourceSecret })
 *     : createLocalHarness({ claudeExe, codexExe });
 */
export function createHarness(config: HarnessConfiguration): Harness {
  if (config.mode === 'qm') {
    if (config.qm === undefined) {
      throw MuError.invalidTransition('HarnessConfiguration: QM mode requires `qm` options.')
    }
    return createQMHarness(config.qm)
  }
  return createLocalHarness(config.local ?? {})
}

export type { LocalChildProcessHarness, QMHTTPHarness }
