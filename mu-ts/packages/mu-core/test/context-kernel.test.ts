import { describe, expect, it } from 'vitest'
import { ContextKernelValidationError } from '../src/errors.ts'
import { uuid } from '../src/identity.ts'
import {
  canonicalData,
  containsText,
  contextBundleIssuesInRaw,
  contextBundleIssuesInValue,
  contextRecordStatusAllowsTransition,
  CONTEXT_CANONICALIZATION_VERSION,
  createContextAccessPolicyRecord,
  createContextConflictRecord,
  createContextPackItemRecord,
  createContextRecord,
  createContextScope,
  pcvArray,
  pcvBool,
  pcvNull,
  pcvNumber,
  pcvObject,
  pcvString,
  renderedText,
  scopeOverlaps,
  stableConflictID,
  validateImmutableReceipt,
  validatePolicyImmutableReceipt,
} from '../src/context-kernel/index.ts'

const P = uuid('a1b2c3d4-e5f6-4789-abcd-ef0123456789')
const S = uuid('9f8e7d6c-5b4a-4321-8f0e-dcba98765432')
const A = uuid('d9f4d3f2-1a2b-4c3d-8e5f-60718293a4b5')
const T = uuid('01234567-89ab-4cde-8f01-23456789abcd')

describe('ProjectContextValue canonical encoding', () => {
  it('produces deterministic sorted-key JSON', () => {
    const value = pcvObject({
      z_last: pcvArray([pcvNumber(1), pcvNumber(0.5), pcvString('a/b'), pcvNull, pcvBool(true)]),
      a_first: pcvObject({ nested: pcvString('héllo'), flag: pcvBool(false) }),
    })
    const a = canonicalData(value)
    const b = canonicalData(value)
    expect(a).toBe(b)
    expect(a).toContain('"a_first"')
    expect(a.indexOf('"a_first"')).toBeLessThan(a.indexOf('"z_last"'))
  })

  it('normalizes -0 to 0 and rejects non-finite numbers', () => {
    expect(canonicalData(pcvNumber(-0))).toBe('0')
    expect(() => canonicalData(pcvNumber(Number.NaN))).toThrow(
      ContextKernelValidationError,
    )
    expect(() => canonicalData(pcvNumber(Infinity))).toThrow(
      ContextKernelValidationError,
    )
  })

  it('renders strings as-is and other values as canonical JSON', () => {
    expect(renderedText(pcvString('hello'))).toBe('hello')
    expect(renderedText(pcvBool(true))).toBe('true')
  })

  it('containsText folds case and diacritics', () => {
    expect(containsText(pcvString('Café menu'), 'cafe')).toBe(true)
    expect(containsText(pcvString('HELLO'), 'hello')).toBe(true)
    expect(containsText(pcvString('hello'), 'goodbye')).toBe(false)
  })
})

describe('ContextRecord lifecycle', () => {
  it('computes immutable fingerprints and validates receipts', () => {
    const record = createContextRecord({
      projectID: P,
      sourceID: S,
      externalID: 'msg-42',
      kind: 'fact',
      subject: 'API Rate Limit',
      value: pcvObject({
        limit: pcvNumber(100),
        window: pcvString('minute'),
      }),
      authority: 'agent_claim',
      scope: createContextScope({ environment: 'prod' }),
      sensitivity: 'restricted',
      confidence: 0.95,
      createdByActorID: A,
    })
    expect(record.subject).toBe('api rate limit')
    expect(record.externalID).toBe('msg-42')
    expect(record.canonicalizationVersion).toBe(CONTEXT_CANONICALIZATION_VERSION)
    expect(record.contentSHA256).toMatch(/^[0-9a-f]{64}$/)
    expect(record.immutableFingerprint).toMatch(/^[0-9a-f]{64}$/)
    expect(() => validateImmutableReceipt(record)).not.toThrow()

    // Tampering with the value breaks the receipt.
    const tampered = { ...record, value: pcvObject({ limit: pcvNumber(999), window: pcvString('minute') }) }
    expect(() => validateImmutableReceipt(tampered)).toThrow(
      ContextKernelValidationError,
    )
  })

  it('validates confidence and validity intervals', () => {
    expect(() =>
      createContextRecord({
        projectID: P,
        sourceID: S,
        kind: 'fact',
        value: pcvString('x'),
        confidence: 1.5,
        createdByActorID: A,
      }),
    ).toThrow(ContextKernelValidationError)
    expect(() =>
      createContextRecord({
        projectID: P,
        sourceID: S,
        kind: 'fact',
        value: pcvString('x'),
        validFrom: new Date('2026-01-02'),
        validUntil: new Date('2026-01-01'),
        createdByActorID: A,
      }),
    ).toThrow(ContextKernelValidationError)
  })

  it('enforces controlled status transitions', () => {
    expect(contextRecordStatusAllowsTransition('candidate', 'accepted')).toBe(true)
    expect(contextRecordStatusAllowsTransition('candidate', 'rejected')).toBe(true)
    expect(contextRecordStatusAllowsTransition('accepted', 'superseded')).toBe(true)
    expect(contextRecordStatusAllowsTransition('accepted', 'rejected')).toBe(false)
    expect(contextRecordStatusAllowsTransition('rejected', 'accepted')).toBe(false)
  })
})

describe('ContextScope', () => {
  it('normalizes dimensions and overlaps', () => {
    const prod = createContextScope({ environment: '  Prod ', component: 'api' })
    expect(prod.environment).toBe('prod')
    expect(scopeOverlaps(prod, createContextScope({ environment: 'prod', component: 'api' }))).toBe(true)
    expect(scopeOverlaps(prod, createContextScope({ environment: 'prod', component: 'web' }))).toBe(false)
    expect(scopeOverlaps(prod, createContextScope({ environment: 'staging' }))).toBe(false)
    expect(scopeOverlaps(prod, createContextScope({}))).toBe(true)
    // taskID must overlap when both set
    expect(
      scopeOverlaps(
        createContextScope({ taskID: T }),
        createContextScope({ taskID: T }),
      ),
    ).toBe(true)
    expect(
      scopeOverlaps(
        createContextScope({ taskID: T }),
        createContextScope({ taskID: S }),
      ),
    ).toBe(false)
  })
})

describe('ContextConflictRecord', () => {
  it('normalizes subject and sorts record IDs', () => {
    const conflict = createContextConflictRecord({
      projectID: P,
      subject: '  API Rate Limit ',
      recordIDs: [S, T, S],
    })
    expect(conflict.subject).toBe('api rate limit')
    expect(conflict.recordIDs).toEqual([...new Set([S, T].map((x) => x))].sort())
    expect(conflict.acceptedRecordIDs).toEqual([])
  })

  it('derives a stable conflict ID', () => {
    const id1 = stableConflictID(P, 'api rate limit', [S, T])
    const id2 = stableConflictID(P, 'API Rate Limit', [T, S])
    expect(id1).toBe(id2)
    expect(id1[14]).toBe('5')
  })
})

describe('ContextAccessPolicyRecord', () => {
  it('computes family ID and policy fingerprint', () => {
    const policy = createContextAccessPolicyRecord({
      projectID: P,
      subjectKind: 'record',
      subjectID: S,
      version: 2,
      namespace: 'Project/Shared',
      allowedActorIDs: [T, A],
      createdByActorID: A,
    })
    expect(policy.namespace).toBe('project/shared')
    expect(policy.familyID[14]).toBe('5')
    expect(policy.allowedActorIDs).toEqual([T, A])
    expect(() => validatePolicyImmutableReceipt(policy)).not.toThrow()
    expect(() =>
      validatePolicyImmutableReceipt({ ...policy, policySHA256: '0'.repeat(64) }),
    ).toThrow(ContextKernelValidationError)
  })
})

describe('ContextPackItemRecord', () => {
  it('derives a stable item ID and sorts policy receipts', () => {
    const p1 = createContextAccessPolicyRecord({
      projectID: P,
      subjectKind: 'record',
      subjectID: S,
      createdByActorID: A,
    })
    const p2 = createContextAccessPolicyRecord({
      projectID: P,
      subjectKind: 'source',
      subjectID: S,
      createdByActorID: A,
    })
    const item = createContextPackItemRecord({
      projectID: P,
      packID: P,
      itemKind: 'record',
      referencedID: S,
      inclusionReason: 'relevant',
      ordinal: 1,
      renderedSHA256: 'a'.repeat(64),
      referencedSHA256: 'b'.repeat(64),
      policyReceipts: [
        { policyID: p1.id, subjectKind: 'record', subjectID: S, version: 1, policySHA256: p1.policySHA256, sensitivity: p1.sensitivity },
        { policyID: p2.id, subjectKind: 'source', subjectID: S, version: 1, policySHA256: p2.policySHA256, sensitivity: p2.sensitivity },
      ],
    })
    expect(item.id[14]).toBe('5')
    // Swift sorts by subjectKind rawValue: 'record' < 'source'
    expect(item.policyReceipts.map((r) => r.subjectKind)).toEqual(['record', 'source'])
  })
})

describe('ContextBundleSafety', () => {
  it('flags forbidden fields and secret material', () => {
    const issues = contextBundleIssuesInRaw(
      JSON.stringify({
        chain_of_thought: 'private',
        config: { api_key: 'sk-abcdefghijklmnopqrstuvwxyz1234' },
        ok: true,
      }),
    )
    const codes = issues.map((i) => i.code)
    expect(codes).toContain('forbidden_field')
    expect(codes).toContain('secret_material')
    expect(issues.some((i) => i.message.includes('config.api_key'))).toBe(true)
  })

  it('rejects invalid JSON with an invalid_json issue', () => {
    const issues = contextBundleIssuesInRaw('{not json')
    expect(issues).toHaveLength(1)
    expect(issues[0]?.code).toBe('invalid_json')
  })

  it('detects PEM private keys in values', () => {
    const issues = contextBundleIssuesInValue(
      pcvObject({
        key: pcvString('-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----'),
      }),
    )
    expect(issues.some((i) => i.code === 'secret_material')).toBe(true)
  })

  it('accepts clean values', () => {
    const issues = contextBundleIssuesInValue(
      pcvObject({ title: pcvString('A normal fact'), count: pcvNumber(3) }),
    )
    expect(issues).toEqual([])
  })
})
