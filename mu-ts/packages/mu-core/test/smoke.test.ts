import { describe, expect, it } from 'vitest'

describe('toolchain smoke', () => {
  it('runs vitest with ESM + TS', () => {
    expect(1 + 1).toBe(2)
  })
})
