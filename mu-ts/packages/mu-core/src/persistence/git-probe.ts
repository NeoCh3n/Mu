import fs from 'node:fs'
import path from 'node:path'
import { MuError } from '../errors.ts'
import type { RepositorySnapshot } from '../models.ts'
import type { ArtifactStore } from './artifact-store.ts'
import { runGitData } from './process-capture.ts'

/** Git repository probing, mirroring GitRepositoryProbe.swift. */
export class GitRepositoryProbe {
  private readonly artifactStore: ArtifactStore

  constructor(artifactStore: ArtifactStore) {
    this.artifactStore = artifactStore
  }

  baseRevision(path_: string): string | undefined {
    try {
      const value = runGitData(['rev-parse', 'HEAD'], path_)
        .toString('utf8')
        .replace(/^\s+|\s+$/g, '')
      return value === '' ? undefined : value
    } catch {
      return undefined
    }
  }

  capture(path_: string): RepositorySnapshot {
    let stat: fs.Stats
    try {
      stat = fs.statSync(path_)
    } catch {
      throw MuError.invalidRepository('The selected directory does not exist.')
    }
    if (!stat.isDirectory()) {
      throw MuError.invalidRepository('The selected directory does not exist.')
    }

    const inside = runGitData(['rev-parse', '--is-inside-work-tree'], path_)
      .toString('utf8')
      .replace(/^\s+|\s+$/g, '')
    if (inside !== 'true') {
      throw MuError.invalidRepository('Select a directory inside a Git worktree.')
    }

    const branch = safeTrim(runGitData(['branch', '--show-current'], path_)) ?? ''
    const head = safeTrim(runGitData(['rev-parse', 'HEAD'], path_)) ?? 'unborn'
    const statusData = runGitData(['status', '--porcelain=v1', '-z'], path_)
    const untrackedData = runGitData(['ls-files', '--others', '--exclude-standard', '-z'], path_)

    const patchParts: Buffer[] = []
    if (head !== 'unborn') {
      patchParts.push(runGitData(['diff', '--binary', 'HEAD'], path_))
    } else {
      patchParts.push(runGitData(['diff', '--binary'], path_))
      patchParts.push(runGitData(['diff', '--binary', '--cached'], path_))
    }
    const patch = Buffer.concat(patchParts)

    const patchReference = patch.length === 0
      ? undefined
      : this.artifactStore.put(patch)
    const untrackedReference = untrackedData.length === 0
      ? undefined
      : this.artifactStore.put(untrackedData)

    const untrackedFiles = untrackedData
      .toString('utf8')
      .split('\0')
      .filter((s) => s !== '')
      .sort()

    return {
      path: path.resolve(path_),
      isGitRepository: true,
      branch: branch === '' ? 'detached' : branch,
      baseCommit: head,
      headCommit: head,
      isDirty: statusData.length !== 0,
      trackedPatchURI: patchReference?.uri,
      trackedPatchSHA256: patchReference?.sha256,
      untrackedManifestURI: untrackedReference?.uri,
      untrackedManifestSHA256: untrackedReference?.sha256,
      untrackedFiles,
    }
  }
}

function safeTrim(data: Buffer): string | undefined {
  const value = data.toString('utf8').replace(/^\s+|\s+$/g, '')
  return value === '' ? undefined : value
}
