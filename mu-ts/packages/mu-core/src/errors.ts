/** MuError equivalents, mirroring `enum MuError` from Models.swift. */
export type MuErrorKind =
  | 'database'
  | 'invalidRepository'
  | 'commandFailed'
  | 'recordNotFound'
  | 'invalidTransition'
  | 'capabilityMissing'
  | 'artifactWriteFailed'

export class MuError extends Error {
  readonly kind: MuErrorKind

  constructor(kind: MuErrorKind, message: string) {
    super(prefix(kind, message))
    this.name = 'MuError'
    this.kind = kind
  }

  static database(message: string): MuError {
    return new MuError('database', message)
  }
  static invalidRepository(message: string): MuError {
    return new MuError('invalidRepository', message)
  }
  static commandFailed(message: string): MuError {
    return new MuError('commandFailed', message)
  }
  static recordNotFound(message: string): MuError {
    return new MuError('recordNotFound', message)
  }
  static invalidTransition(message: string): MuError {
    return new MuError('invalidTransition', message)
  }
  static capabilityMissing(message: string): MuError {
    return new MuError('capabilityMissing', message)
  }
  static artifactWriteFailed(message: string): MuError {
    return new MuError('artifactWriteFailed', message)
  }
}

function prefix(kind: MuErrorKind, message: string): string {
  switch (kind) {
    case 'database':
      return `Database error: ${message}`
    case 'invalidRepository':
      return `Repository is not ready: ${message}`
    case 'commandFailed':
      return `Command failed: ${message}`
    case 'recordNotFound':
      return `Record not found: ${message}`
    case 'invalidTransition':
      return `Invalid transition: ${message}`
    case 'capabilityMissing':
      return `Capability requirement failed: ${message}`
    case 'artifactWriteFailed':
      return `Could not write evidence: ${message}`
  }
}

/** ContextKernelValidationError, mirroring the Swift enum of the same name. */
export type ContextKernelValidationErrorKind =
  | 'nonFiniteNumber'
  | 'invalidConfidence'
  | 'invalidValidityInterval'
  | 'immutableFingerprintMismatch'
  | 'unsupportedCanonicalizationVersion'

export class ContextKernelValidationError extends Error {
  readonly kind: ContextKernelValidationErrorKind

  constructor(kind: ContextKernelValidationErrorKind, version?: string) {
    super(describe(kind, version))
    this.name = 'ContextKernelValidationError'
    this.kind = kind
  }

  static nonFiniteNumber(): ContextKernelValidationError {
    return new ContextKernelValidationError('nonFiniteNumber')
  }
  static invalidConfidence(): ContextKernelValidationError {
    return new ContextKernelValidationError('invalidConfidence')
  }
  static invalidValidityInterval(): ContextKernelValidationError {
    return new ContextKernelValidationError('invalidValidityInterval')
  }
  static immutableFingerprintMismatch(): ContextKernelValidationError {
    return new ContextKernelValidationError('immutableFingerprintMismatch')
  }
  static unsupportedCanonicalizationVersion(version: string): ContextKernelValidationError {
    return new ContextKernelValidationError('unsupportedCanonicalizationVersion', version)
  }
}

function describe(kind: ContextKernelValidationErrorKind, version?: string): string {
  switch (kind) {
    case 'nonFiniteNumber':
      return 'Project Context values cannot contain NaN or infinity.'
    case 'invalidConfidence':
      return 'Context confidence must be a finite number from 0 through 1.'
    case 'invalidValidityInterval':
      return 'Context validity must use a non-empty [from, until) interval.'
    case 'immutableFingerprintMismatch':
      return 'Context immutable fingerprint does not match its payload.'
    case 'unsupportedCanonicalizationVersion':
      return `Unsupported Context canonicalization version: ${version ?? ''}`
  }
}
