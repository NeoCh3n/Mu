import { execSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MuError } from '../src/errors.ts'
import { ArtifactStore } from '../src/persistence/artifact-store.ts'
import { GitRepositoryProbe } from '../src/persistence/git-probe.ts'

let tmpDir: string
let repoDir: string

function git(args: string): string {
  return execSync(`git ${args}`, { cwd: repoDir, encoding: 'utf8' }).trim()
}

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'mu-git-'))
  repoDir = path.join(tmpDir, 'repo')
  fs.mkdirSync(repoDir)
  execSync('git init -q -b main', { cwd: repoDir })
  execSync('git config user.email test@example.com && git config user.name Test', { cwd: repoDir })
  fs.writeFileSync(path.join(repoDir, 'a.txt'), 'alpha\n')
  git('add a.txt')
  git('commit -q -m init')
})

afterEach(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true })
})

describe('GitRepositoryProbe', () => {
  it('reads the base revision', () => {
    const probe = new GitRepositoryProbe(new ArtifactStore({ dataDirectory: tmpDir }))
    const revision = probe.baseRevision(repoDir)
    expect(revision).toMatch(/^[0-9a-f]{40}$/)
    expect(revision).toBe(git('rev-parse HEAD'))
  })

  it('captures a clean repository snapshot', () => {
    const probe = new GitRepositoryProbe(new ArtifactStore({ dataDirectory: tmpDir }))
    const snapshot = probe.capture(repoDir)
    expect(snapshot.isGitRepository).toBe(true)
    expect(snapshot.branch).toBe('main')
    expect(snapshot.baseCommit).toBe(git('rev-parse HEAD'))
    expect(snapshot.headCommit).toBe(snapshot.baseCommit)
    expect(snapshot.isDirty).toBe(false)
    expect(snapshot.trackedPatchURI).toBeUndefined()
    expect(snapshot.untrackedFiles).toEqual([])
  })

  it('captures a dirty repository with patch and untracked files', () => {
    fs.writeFileSync(path.join(repoDir, 'a.txt'), 'alpha\nbeta\n')
    fs.writeFileSync(path.join(repoDir, 'new.txt'), 'untracked\n')
    const probe = new GitRepositoryProbe(new ArtifactStore({ dataDirectory: tmpDir }))
    const snapshot = probe.capture(repoDir)
    expect(snapshot.isDirty).toBe(true)
    expect(snapshot.trackedPatchURI).toBeDefined()
    expect(snapshot.trackedPatchSHA256).toMatch(/^[0-9a-f]{64}$/)
    expect(snapshot.untrackedFiles).toEqual(['new.txt'])
    expect(snapshot.untrackedManifestURI).toBeDefined()
  })

  it('rejects a non-repository directory', () => {
    const plain = path.join(tmpDir, 'plain')
    fs.mkdirSync(plain)
    const probe = new GitRepositoryProbe(new ArtifactStore({ dataDirectory: tmpDir }))
    expect(() => probe.capture(plain)).toThrow(MuError)
  })

  it('rejects a missing directory', () => {
    const probe = new GitRepositoryProbe(new ArtifactStore({ dataDirectory: tmpDir }))
    expect(() => probe.capture(path.join(tmpDir, 'nope'))).toThrow(MuError)
  })
})
