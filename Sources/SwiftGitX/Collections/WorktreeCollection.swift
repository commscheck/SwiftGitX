//
//  WorktreeCollection.swift
//  SwiftGitX
//
//  Created by Benjamin Lea on 27.09.2026.
//

import Foundation
import libgit2

/// A collection of worktrees and their operations.
///
/// Access this collection through ``Repository/worktree``.
///
/// ```swift
/// let mainWorktree = try repository.worktree.main
/// let worktrees = try repository.worktree.list()
/// let feature = try repository.branch.get(named: "feature")
/// let path = URL(fileURLWithPath: "/path/to/feature")
/// let worktree = try repository.worktree.add(at: path, checkingOut: feature)
/// let destination = URL(fileURLWithPath: "/new/path/to/feature")
/// let movedWorktree = try repository.worktree.move(worktree, to: destination)
/// try repository.worktree.remove(movedWorktree)
/// ```
public struct WorktreeCollection: Sequence, Sendable {
    nonisolated(unsafe) private let repositoryPointer: OpaquePointer

    init(repositoryPointer: OpaquePointer) {
        self.repositoryPointer = repositoryPointer
    }

    /// The repository's main worktree, or `nil` for a bare repository.
    public var main: Worktree? {
        get throws(SwiftGitXError) {
            try mainWorktree()
        }
    }

    /// Retrieves a worktree by its filesystem path.
    ///
    /// - Parameter path: The path of the worktree.
    ///
    /// - Returns: The worktree at the specified path, or `nil` if it doesn't exist.
    public subscript(path: URL) -> Worktree? {
        try? get(at: path)
    }

    /// Returns a worktree by its filesystem path.
    ///
    /// - Parameter path: The path of the worktree.
    ///
    /// - Returns: The worktree at the specified path.
    public func get(at path: URL) throws(SwiftGitXError) -> Worktree {
        let standardizedPath = path.standardizedFileURL

        guard let worktree = try list().first(where: { pathsAreEqual($0.path, standardizedPath) }) else {
            throw SwiftGitXError(
                code: .notFound, operation: .worktreeList, category: .worktree,
                message: "Worktree not found at \(standardizedPath.path)"
            )
        }

        return worktree
    }

    /// Returns all worktrees in the repository.
    ///
    /// The main worktree is returned first, followed by linked worktrees sorted by path.
    public func list() throws(SwiftGitXError) -> [Worktree] {
        var worktrees = [Worktree]()

        if let mainWorktree = try mainWorktree() {
            worktrees.append(mainWorktree)
        }

        let linkedWorktrees = try worktreeNames.map { name throws(SwiftGitXError) -> Worktree in
            let worktreePointer = try lookup(named: name, operation: .worktreeList)
            defer { git_worktree_free(worktreePointer) }
            return try worktree(from: worktreePointer)
        }

        worktrees.append(contentsOf: linkedWorktrees.sorted { $0.path.path < $1.path.path })
        return worktrees
    }

    /// Adds a linked worktree and creates a new branch named after the final path component.
    ///
    /// - Parameter path: The path where the worktree should be created.
    ///
    /// - Returns: The newly created worktree.
    @discardableResult
    public func add(at path: URL) throws(SwiftGitXError) -> Worktree {
        let branchName = path.standardizedFileURL.lastPathComponent
        return try add(at: path, creatingBranchNamed: branchName)
    }

    /// Adds a linked worktree and creates a new branch from the current `HEAD`.
    ///
    /// - Parameters:
    ///   - path: The path where the worktree should be created.
    ///   - branchName: The name of the branch to create.
    ///
    /// - Returns: The newly created worktree.
    @discardableResult
    public func add(at path: URL, creatingBranchNamed branchName: String) throws(SwiftGitXError) -> Worktree {
        let headPointer = try git(operation: .worktreeAdd) {
            var headPointer: OpaquePointer?
            let status = git_repository_head(&headPointer, repositoryPointer)
            return (headPointer, status)
        }
        defer { git_reference_free(headPointer) }

        guard let target = git_reference_target(headPointer) else {
            throw SwiftGitXError(
                code: .invalid, operation: .worktreeAdd, category: .worktree,
                message: "HEAD does not point to a commit"
            )
        }

        let branchCollection = BranchCollection(repositoryPointer: repositoryPointer)
        let commit = try ObjectFactory.lookupCommit(oid: target.pointee, repositoryPointer: repositoryPointer)
        let branch = try branchCollection.create(named: branchName, target: commit)

        do {
            return try add(at: path, checkingOut: branch)
        } catch {
            try? branchCollection.delete(branch)
            throw error
        }
    }

    /// Adds a linked worktree that checks out an existing local branch.
    ///
    /// - Parameters:
    ///   - path: The path where the worktree should be created.
    ///   - branch: The local branch to check out.
    ///
    /// - Returns: The newly created worktree.
    @discardableResult
    public func add(at path: URL, checkingOut branch: Branch) throws(SwiftGitXError) -> Worktree {
        guard branch.type == .local else {
            throw SwiftGitXError(
                code: .invalid, operation: .worktreeAdd, category: .worktree,
                message: "Worktrees can only check out local branches"
            )
        }

        let standardizedPath = path.standardizedFileURL
        guard standardizedPath.isFileURL, !standardizedPath.lastPathComponent.isEmpty else {
            throw SwiftGitXError(
                code: .invalid, operation: .worktreeAdd, category: .worktree,
                message: "Worktree path must be a valid file URL"
            )
        }

        guard !FileManager.default.fileExists(atPath: standardizedPath.path) else {
            throw SwiftGitXError(
                code: .exists, operation: .worktreeAdd, category: .filesystem,
                message: "A file or directory already exists at \(standardizedPath.path)"
            )
        }

        let branchPointer = try ReferenceFactory.lookupBranchPointer(
            name: branch.name,
            type: GIT_BRANCH_LOCAL,
            repositoryPointer: repositoryPointer
        )
        defer { git_reference_free(branchPointer) }

        var options = git_worktree_add_options()
        try git(operation: .worktreeAdd) {
            git_worktree_add_options_init(&options, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION))
        }
        options.ref = branchPointer

        let administrativeName = try availableAdministrativeName(for: standardizedPath)
        let worktreePointer = try git(operation: .worktreeAdd) {
            var worktreePointer: OpaquePointer?
            let status = git_worktree_add(
                &worktreePointer,
                repositoryPointer,
                administrativeName,
                standardizedPath.path,
                &options
            )
            return (worktreePointer, status)
        }
        defer { git_worktree_free(worktreePointer) }

        return try worktree(from: worktreePointer)
    }

    /// Moves a linked worktree to a new filesystem path.
    ///
    /// - Parameters:
    ///   - worktree: The worktree to move.
    ///   - destination: The destination path.
    ///   - force: Whether to move a locked worktree. Default is `false`.
    ///
    /// - Returns: The worktree at its new path.
    @discardableResult
    public func move(
        _ worktree: Worktree,
        to destination: URL,
        force: Bool = false
    ) throws(SwiftGitXError) -> Worktree {
        guard !worktree.isMain else {
            throw mainWorktreeError(operation: .worktreeMove)
        }

        let worktreePointer = try linkedWorktreePointer(at: worktree.path, operation: .worktreeMove)
        defer { git_worktree_free(worktreePointer) }

        let currentWorktree = try self.worktree(from: worktreePointer)
        guard currentWorktree.isValid else {
            throw SwiftGitXError(
                code: .invalid, operation: .worktreeMove, category: .worktree,
                message: "Cannot move an invalid worktree"
            )
        }

        if currentWorktree.isLocked && !force {
            throw lockedWorktreeError(currentWorktree, operation: .worktreeMove)
        }

        let standardizedDestination = destination.standardizedFileURL
        guard standardizedDestination.isFileURL, !standardizedDestination.lastPathComponent.isEmpty else {
            throw SwiftGitXError(
                code: .invalid, operation: .worktreeMove, category: .worktree,
                message: "Worktree destination must be a valid file URL"
            )
        }

        guard !FileManager.default.fileExists(atPath: standardizedDestination.path) else {
            throw SwiftGitXError(
                code: .exists, operation: .worktreeMove, category: .filesystem,
                message: "A file or directory already exists at \(standardizedDestination.path)"
            )
        }

        let repository = try openRepository(for: worktreePointer, operation: .worktreeMove)
        defer { git_repository_free(repository) }

        guard try !containsSubmodules(repository) else {
            throw SwiftGitXError(
                code: .notSupported, operation: .worktreeMove, category: .submodule,
                message: "Worktrees containing submodules cannot be moved"
            )
        }

        guard let rawAdministrativePath = git_repository_path(repository) else {
            throw SwiftGitXError(
                code: .error, operation: .worktreeMove, category: .worktree,
                message: "Failed to get the worktree administrative path"
            )
        }

        let source = currentWorktree.path
        let administrativePath = URL(
            fileURLWithPath: String(cString: rawAdministrativePath),
            isDirectory: true
        ).standardizedFileURL
        let sourceGitFile = source.appendingPathComponent(".git", isDirectory: false)
        let administrativeGitFile = administrativePath.appendingPathComponent("gitdir", isDirectory: false)

        let sourceGitData: Data
        let administrativeGitData: Data
        do {
            sourceGitData = try Data(contentsOf: sourceGitFile)
            administrativeGitData = try Data(contentsOf: administrativeGitFile)
        } catch {
            throw filesystemError(operation: .worktreeMove, action: "read worktree metadata", error: error)
        }

        do {
            try FileManager.default.moveItem(at: source, to: standardizedDestination)

            let destinationGitFile = standardizedDestination.appendingPathComponent(".git", isDirectory: false)
            try Data("gitdir: \(administrativePath.path)\n".utf8).write(to: destinationGitFile, options: .atomic)
            try Data("\(destinationGitFile.path)\n".utf8).write(to: administrativeGitFile, options: .atomic)
        } catch {
            let rollbackError = rollbackMove(
                from: standardizedDestination,
                to: source,
                sourceGitData: sourceGitData,
                administrativeGitFile: administrativeGitFile,
                administrativeGitData: administrativeGitData
            )

            let rollbackMessage = rollbackError.map { "; rollback failed: \($0.localizedDescription)" } ?? ""
            throw SwiftGitXError(
                code: .error, operation: .worktreeMove, category: .filesystem,
                message: "Failed to move worktree: \(error.localizedDescription)\(rollbackMessage)"
            )
        }

        return try get(at: standardizedDestination)
    }

    /// Removes a linked worktree.
    ///
    /// - Parameters:
    ///   - worktree: The worktree to remove.
    ///   - force: Whether to remove a dirty or locked worktree. Default is `false`.
    public func remove(_ worktree: Worktree, force: Bool = false) throws(SwiftGitXError) {
        guard !worktree.isMain else {
            throw mainWorktreeError(operation: .worktreeRemove)
        }

        let worktreePointer = try linkedWorktreePointer(at: worktree.path, operation: .worktreeRemove)
        defer { git_worktree_free(worktreePointer) }

        let currentWorktree = try self.worktree(from: worktreePointer)
        if currentWorktree.isLocked && !force {
            throw lockedWorktreeError(currentWorktree, operation: .worktreeRemove)
        }

        if currentWorktree.isValid && !force {
            let repository = try openRepository(for: worktreePointer, operation: .worktreeRemove)
            defer { git_repository_free(repository) }

            guard try !isDirty(repository) else {
                throw SwiftGitXError(
                    code: .uncommitted, operation: .worktreeRemove, category: .worktree,
                    message: "Worktree contains uncommitted changes"
                )
            }
        }

        var options = git_worktree_prune_options()
        try git(operation: .worktreeRemove) {
            git_worktree_prune_options_init(&options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION))
        }

        if currentWorktree.isValid {
            options.flags |= UInt32(GIT_WORKTREE_PRUNE_VALID.rawValue)
            options.flags |= UInt32(GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue)
        }
        if force {
            options.flags |= UInt32(GIT_WORKTREE_PRUNE_LOCKED.rawValue)
        }

        try git(operation: .worktreeRemove) {
            git_worktree_prune(worktreePointer, &options)
        }
    }

    public func makeIterator() -> IndexingIterator<[Worktree]> {
        ((try? list()) ?? []).makeIterator()
    }
}

// MARK: - Private Helpers

extension WorktreeCollection {
    private var worktreeNames: [String] {
        get throws(SwiftGitXError) {
            var array = git_strarray()
            defer { git_strarray_free(&array) }

            try git(operation: .worktreeList) {
                git_worktree_list(&array, repositoryPointer)
            }

            return try (0..<array.count).map { index throws(SwiftGitXError) -> String in
                guard let name = array.strings.advanced(by: index).pointee else {
                    throw SwiftGitXError(
                        code: .notFound, operation: .worktreeList, category: .worktree,
                        message: "Failed to get worktree name at index \(index)"
                    )
                }
                return String(cString: name)
            }
        }
    }

    private func mainWorktree() throws(SwiftGitXError) -> Worktree? {
        guard let commonDirectory = git_repository_commondir(repositoryPointer) else {
            throw SwiftGitXError(
                code: .error, operation: .worktreeList, category: .repository,
                message: "Failed to get the common repository directory"
            )
        }

        let mainRepository = try git(operation: .worktreeList) {
            var mainRepository: OpaquePointer?
            let status = git_repository_open(&mainRepository, commonDirectory)
            return (mainRepository, status)
        }
        defer { git_repository_free(mainRepository) }

        guard let workingDirectory = git_repository_workdir(mainRepository) else {
            return nil
        }

        return Worktree(
            path: URL(fileURLWithPath: String(cString: workingDirectory), isDirectory: true).standardizedFileURL,
            isMain: true,
            isValid: true,
            isLocked: false,
            lockReason: nil
        )
    }

    private func worktree(from pointer: OpaquePointer) throws(SwiftGitXError) -> Worktree {
        guard let rawPath = git_worktree_path(pointer) else {
            throw SwiftGitXError(
                code: .error, operation: .worktreeList, category: .worktree,
                message: "Failed to get worktree path"
            )
        }

        var reason = git_buf()
        defer { git_buf_free(&reason) }

        let lockStatus = git_worktree_is_locked(&reason, pointer)
        try SwiftGitXError.check(lockStatus < 0 ? lockStatus : 0, operation: .worktreeList)

        let validationStatus = git_worktree_validate(pointer)
        let isValid = validationStatus == 0
        if validationStatus < 0 {
            git_error_clear()
        }

        let lockReason: String? =
            if lockStatus > 0, let rawReason = reason.ptr, reason.size > 0 {
                String(cString: rawReason)
            } else {
                nil
            }

        return Worktree(
            path: URL(fileURLWithPath: String(cString: rawPath), isDirectory: true).standardizedFileURL,
            isMain: false,
            isValid: isValid,
            isLocked: lockStatus > 0,
            lockReason: lockReason
        )
    }

    private func lookup(named name: String, operation: SwiftGitXError.Operation) throws(SwiftGitXError) -> OpaquePointer
    {
        try git(operation: operation) {
            var worktreePointer: OpaquePointer?
            let status = git_worktree_lookup(&worktreePointer, repositoryPointer, name)
            return (worktreePointer, status)
        }
    }

    private func linkedWorktreePointer(
        at path: URL,
        operation: SwiftGitXError.Operation
    ) throws(SwiftGitXError) -> OpaquePointer {
        let standardizedPath = path.standardizedFileURL

        for name in try worktreeNames {
            let pointer = try lookup(named: name, operation: operation)
            guard let rawPath = git_worktree_path(pointer) else {
                git_worktree_free(pointer)
                continue
            }

            let candidatePath = URL(
                fileURLWithPath: String(cString: rawPath),
                isDirectory: true
            ).standardizedFileURL
            if pathsAreEqual(candidatePath, standardizedPath) {
                return pointer
            }

            git_worktree_free(pointer)
        }

        throw SwiftGitXError(
            code: .notFound, operation: operation, category: .worktree,
            message: "Linked worktree not found at \(standardizedPath.path)"
        )
    }

    private func availableAdministrativeName(for path: URL) throws(SwiftGitXError) -> String {
        let baseName = path.lastPathComponent
        guard !baseName.isEmpty, baseName != ".", baseName != ".." else {
            throw SwiftGitXError(
                code: .invalid, operation: .worktreeAdd, category: .worktree,
                message: "Worktree path must have a valid final component"
            )
        }

        let existingNames = Set(try worktreeNames)
        if !existingNames.contains(baseName) {
            return baseName
        }

        var suffix = 1
        while existingNames.contains("\(baseName)\(suffix)") {
            suffix += 1
        }
        return "\(baseName)\(suffix)"
    }

    private func pathsAreEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private func canonicalPath(_ path: URL) -> URL {
        var existingAncestor = path.standardizedFileURL
        var missingComponents = [String]()

        while !FileManager.default.fileExists(atPath: existingAncestor.path),
            existingAncestor.path != "/"
        {
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor.deleteLastPathComponent()
        }

        return missingComponents.reversed().reduce(existingAncestor.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }
    }

    private func openRepository(
        for worktreePointer: OpaquePointer,
        operation: SwiftGitXError.Operation
    ) throws(SwiftGitXError) -> OpaquePointer {
        try git(operation: operation) {
            var repositoryPointer: OpaquePointer?
            let status = git_repository_open_from_worktree(&repositoryPointer, worktreePointer)
            return (repositoryPointer, status)
        }
    }

    private func containsSubmodules(_ repositoryPointer: OpaquePointer) throws(SwiftGitXError) -> Bool {
        var containsSubmodules = false
        let status = withUnsafeMutablePointer(to: &containsSubmodules) { payload in
            git_submodule_foreach(
                repositoryPointer,
                { _, _, payload in
                    payload?.assumingMemoryBound(to: Bool.self).pointee = true
                    return 0
                },
                payload
            )
        }
        try SwiftGitXError.check(status, operation: .worktreeMove)
        return containsSubmodules
    }

    private func isDirty(_ repositoryPointer: OpaquePointer) throws(SwiftGitXError) -> Bool {
        var options = git_status_options()
        try git(operation: .worktreeRemove) {
            git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        }
        options.flags = StatusOption.default.rawValue

        let statusList = try git(operation: .worktreeRemove) {
            var statusList: OpaquePointer?
            let status = git_status_list_new(&statusList, repositoryPointer, &options)
            return (statusList, status)
        }
        defer { git_status_list_free(statusList) }

        return git_status_list_entrycount(statusList) > 0
    }

    private func rollbackMove(
        from destination: URL,
        to source: URL,
        sourceGitData: Data,
        administrativeGitFile: URL,
        administrativeGitData: Data
    ) -> Error? {
        do {
            if FileManager.default.fileExists(atPath: destination.path),
                !FileManager.default.fileExists(atPath: source.path)
            {
                try FileManager.default.moveItem(at: destination, to: source)
            }

            try sourceGitData.write(
                to: source.appendingPathComponent(".git", isDirectory: false),
                options: .atomic
            )
            try administrativeGitData.write(to: administrativeGitFile, options: .atomic)
            return nil
        } catch {
            return error
        }
    }

    private func mainWorktreeError(operation: SwiftGitXError.Operation) -> SwiftGitXError {
        SwiftGitXError(
            code: .invalid, operation: operation, category: .worktree,
            message: "The main worktree cannot be moved or removed"
        )
    }

    private func lockedWorktreeError(
        _ worktree: Worktree,
        operation: SwiftGitXError.Operation
    ) -> SwiftGitXError {
        let reason = worktree.lockReason.map { ": \($0)" } ?? ""
        return SwiftGitXError(
            code: .locked, operation: operation, category: .worktree,
            message: "Worktree is locked\(reason)"
        )
    }

    private func filesystemError(
        operation: SwiftGitXError.Operation,
        action: String,
        error: Error
    ) -> SwiftGitXError {
        SwiftGitXError(
            code: .error, operation: operation, category: .filesystem,
            message: "Failed to \(action): \(error.localizedDescription)"
        )
    }
}

extension SwiftGitXError.Operation {
    public static let worktreeList = Self(rawValue: "worktreeList")
    public static let worktreeAdd = Self(rawValue: "worktreeAdd")
    public static let worktreeMove = Self(rawValue: "worktreeMove")
    public static let worktreeRemove = Self(rawValue: "worktreeRemove")
}
