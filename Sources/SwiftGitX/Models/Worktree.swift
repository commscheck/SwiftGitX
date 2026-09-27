//
//  Worktree.swift
//  SwiftGitX
//
//  Created by Benjamin Lea on 27.09.2026.
//

import Foundation

/// A snapshot of a Git worktree.
public struct Worktree: Equatable, Hashable, Sendable {
    /// The filesystem location of the worktree.
    public let path: URL

    /// Whether this is the repository's main worktree.
    public let isMain: Bool

    /// Whether the worktree's administrative data and working directory are valid.
    public let isValid: Bool

    /// Whether the worktree is locked.
    public let isLocked: Bool

    /// The reason the worktree is locked, if one was provided.
    public let lockReason: String?
}
