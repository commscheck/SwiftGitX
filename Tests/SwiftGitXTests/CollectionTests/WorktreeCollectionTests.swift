import Foundation
import SwiftGitX
import Testing

@Suite("Worktree Collection", .tags(.worktree, .collection), .serialized)
final class WorktreeCollectionTests: SwiftGitXTest {
    @Test("Git directories associate linked checkouts and survive relocation")
    func gitDirectoryIdentity() throws {
        let repository = try committedRepository()
        let source = worktreePath(suffix: "-identity")
        let linked = try repository.worktree.add(at: source, creatingBranchNamed: "feature")
        let opened = try Repository.open(at: source)
        #expect(opened.commonDirectory == repository.path.standardizedFileURL)
        #expect(linked.gitDirectory == opened.path.standardizedFileURL)
        #expect(try repository.worktree.main?.gitDirectory == repository.commonDirectory)
        #expect(linked.gitDirectory != repository.commonDirectory)

        let moved = try repository.worktree.move(linked, to: worktreePath(suffix: "-moved"))
        #expect(moved.gitDirectory == linked.gitDirectory)
        try FileManager.default.removeItem(at: moved.path)
        let missing = try repository.worktree.get(at: moved.path)
        #expect(!missing.isValid)
        #expect(missing.gitDirectory == linked.gitDirectory)
    }

    @Test("Main returns the repository's main worktree")
    func mainWorktree() throws {
        let repository = try committedRepository()
        let result = try repository.worktree.main
        let main = try #require(result)
        let workingDirectory = try repository.workingDirectory.standardizedFileURL

        #expect(main.path == workingDirectory)
        #expect(main.isMain)
    }

    @Test("Main is the same when accessed from a linked worktree")
    func mainWorktreeFromLinkedWorktree() throws {
        let repository = try committedRepository()
        let linkedPath = worktreePath()
        try repository.worktree.add(at: linkedPath, creatingBranchNamed: "feature")

        let linkedRepository = try Repository.open(at: linkedPath)
        let result = try linkedRepository.worktree.main
        let main = try #require(result)
        let workingDirectory = try repository.workingDirectory.standardizedFileURL

        #expect(main.path == workingDirectory)
        #expect(main.isMain)
    }

    @Test("Main is nil for a bare repository")
    func mainWorktreeInBareRepository() throws {
        let repository = mockRepository(isBare: true)
        let main = try repository.worktree.main
        #expect(main == nil)
    }

    @Test("List includes the main worktree first")
    func listMainWorktree() throws {
        let repository = mockRepository()
        try repository.mockCommit()

        let worktrees = try repository.worktree.list()
        let workingDirectory = try repository.workingDirectory.standardizedFileURL

        #expect(worktrees.count == 1)
        #expect(worktrees[0].path == workingDirectory)
        #expect(worktrees[0].isMain)
        #expect(worktrees[0].isValid)
        #expect(!worktrees[0].isLocked)
        #expect(worktrees[0].lockReason == nil)
    }

    @Test("Bare repositories do not have a main worktree")
    func listBareRepository() throws {
        let repository = mockRepository(isBare: true)
        #expect(try repository.worktree.list().isEmpty)
    }

    @Test("Lookup and iteration use filesystem paths")
    func lookupAndIteration() throws {
        let repository = try committedRepository()
        let firstPath = worktreePath(suffix: "-z-linked")
        let secondPath = worktreePath(suffix: "-a-linked")

        try repository.worktree.add(at: firstPath, creatingBranchNamed: "first")
        try repository.worktree.add(at: secondPath, creatingBranchNamed: "second")

        let listed = try repository.worktree.list()
        let workingDirectory = try repository.workingDirectory.standardizedFileURL
        #expect(
            listed.map(\.path) == [
                workingDirectory,
                secondPath.standardizedFileURL,
                firstPath.standardizedFileURL
            ])
        #expect(try repository.worktree.get(at: firstPath).path == firstPath.standardizedFileURL)
        #expect(repository.worktree[firstPath]?.path == firstPath.standardizedFileURL)
        #expect(Array(repository.worktree) == listed)
    }

    @Test("Add creates a branch named after the path")
    func addWithDefaultBranchName() throws {
        let repository = try committedRepository()
        let parent = worktreePath()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent("default-worktree", isDirectory: true)

        let worktree = try repository.worktree.add(at: path)
        let linkedRepository = try Repository.open(at: path)

        #expect(worktree.path == path.standardizedFileURL)
        #expect(!worktree.isMain)
        #expect(worktree.isValid)
        #expect(try linkedRepository.branch.current.name == path.lastPathComponent)
    }

    @Test("Add creates an explicitly named branch")
    func addWithNewBranchName() throws {
        let repository = try committedRepository()
        let path = worktreePath()

        try repository.worktree.add(at: path, creatingBranchNamed: "feature")

        let linkedRepository = try Repository.open(at: path)
        #expect(try linkedRepository.branch.current.name == "feature")
        #expect(repository.branch["feature", type: .local] != nil)
    }

    @Test("Add checks out an existing local branch")
    func addExistingBranch() throws {
        let repository = try committedRepository()
        let path = worktreePath()
        let current = try repository.branch.current
        let branch = try repository.branch.create(named: "existing", from: current)

        try repository.worktree.add(at: path, checkingOut: branch)

        let linkedRepository = try Repository.open(at: path)
        #expect(try linkedRepository.branch.current.name == "existing")
    }

    @Test("Administrative names do not collide for equal basenames")
    func administrativeNameCollision() throws {
        let repository = try committedRepository()
        let parent1 = worktreePath(suffix: "-parent-1")
        let parent2 = worktreePath(suffix: "-parent-2")
        try FileManager.default.createDirectory(at: parent1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent2, withIntermediateDirectories: true)
        let firstPath = parent1.appendingPathComponent("linked", isDirectory: true)
        let secondPath = parent2.appendingPathComponent("linked", isDirectory: true)

        try repository.worktree.add(at: firstPath, creatingBranchNamed: "first")
        try repository.worktree.add(at: secondPath, creatingBranchNamed: "second")

        let linkedPaths = try repository.worktree.list().filter { !$0.isMain }.map(\.path)
        #expect(Set(linkedPaths) == Set([firstPath.standardizedFileURL, secondPath.standardizedFileURL]))
    }

    @Test("Add rejects an existing destination and rolls back a new branch")
    func addExistingDestination() throws {
        let repository = try committedRepository()
        let path = worktreePath(create: true)

        let error = #expect(throws: SwiftGitXError.self) {
            try repository.worktree.add(at: path, creatingBranchNamed: "feature")
        }

        #expect(error?.code == .exists)
        #expect(repository.branch["feature", type: .local] == nil)
    }

    @Test("Add rejects an unborn repository")
    func addUnbornRepository() throws {
        let repository = mockRepository()

        #expect(throws: SwiftGitXError.self) {
            try repository.worktree.add(at: worktreePath())
        }
    }

    @Test("Add rejects a branch checked out elsewhere")
    func addCheckedOutBranch() throws {
        let repository = try committedRepository()
        let current = try repository.branch.current

        #expect(throws: SwiftGitXError.self) {
            try repository.worktree.add(at: worktreePath(), checkingOut: current)
        }
    }

    @Test("Move updates worktree paths and metadata")
    func moveWorktree() throws {
        let repository = try committedRepository()
        let source = worktreePath(suffix: "-source")
        let destination = worktreePath(suffix: "-destination")
        let worktree = try repository.worktree.add(at: source, creatingBranchNamed: "feature")

        // Dirty worktrees are movable, matching `git worktree move`.
        let linkedRepository = try Repository.open(at: source)
        _ = try linkedRepository.mockFile(name: "untracked.txt")

        let moved = try repository.worktree.move(worktree, to: destination)
        let movedRepository = try Repository.open(at: destination)

        #expect(moved.path == destination.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try movedRepository.branch.current.name == "feature")
        #expect(repository.worktree[source] == nil)
        #expect(repository.worktree[destination] != nil)
    }

    @Test("Move rejects an existing destination")
    func moveExistingDestination() throws {
        let repository = try committedRepository()
        let source = worktreePath(suffix: "-source")
        let destination = worktreePath(suffix: "-destination", create: true)
        let worktree = try repository.worktree.add(at: source, creatingBranchNamed: "feature")

        let error = #expect(throws: SwiftGitXError.self) {
            try repository.worktree.move(worktree, to: destination)
        }

        #expect(error?.code == .exists)
        #expect(repository.worktree[source] != nil)
    }

    @Test("Move requires force for a locked worktree")
    func moveLockedWorktree() throws {
        let repository = try committedRepository()
        let source = worktreePath(suffix: "-source")
        let destination = worktreePath(suffix: "-destination")
        let worktree = try repository.worktree.add(at: source, creatingBranchNamed: "feature")
        try lock(worktree, in: repository, reason: "in use")

        let locked = try repository.worktree.get(at: source)
        #expect(locked.isLocked)
        #expect(locked.lockReason == "in use")
        #expect(throws: SwiftGitXError.self) {
            try repository.worktree.move(locked, to: destination)
        }

        let moved = try repository.worktree.move(locked, to: destination, force: true)
        #expect(moved.path == destination.standardizedFileURL)
        #expect(moved.isLocked)
    }

    @Test("Move rejects worktrees containing submodules")
    func moveWorktreeWithSubmodule() throws {
        let repository = try committedRepository()
        let gitmodules = try repository.mockFile(
            name: ".gitmodules",
            content: """
                [submodule "dependency"]
                \tpath = dependency
                \turl = https://example.com/dependency.git
                """
        )
        try repository.add(file: gitmodules)
        try repository.commit(message: "Add submodule metadata")

        let source = worktreePath(suffix: "-source")
        let worktree = try repository.worktree.add(at: source, creatingBranchNamed: "feature")

        let error = #expect(throws: SwiftGitXError.self) {
            try repository.worktree.move(worktree, to: worktreePath(suffix: "-destination"))
        }
        #expect(error?.code == .notSupported)
    }

    @Test("Remove deletes a clean worktree")
    func removeCleanWorktree() throws {
        let repository = try committedRepository()
        let path = worktreePath()
        let worktree = try repository.worktree.add(at: path, creatingBranchNamed: "feature")

        try repository.worktree.remove(worktree)

        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(repository.worktree[path] == nil)
    }

    @Test("Remove requires force for a dirty worktree")
    func removeDirtyWorktree() throws {
        let repository = try committedRepository()
        let path = worktreePath()
        let worktree = try repository.worktree.add(at: path, creatingBranchNamed: "feature")
        let linkedRepository = try Repository.open(at: path)
        _ = try linkedRepository.mockFile(name: "untracked.txt")

        let error = #expect(throws: SwiftGitXError.self) {
            try repository.worktree.remove(worktree)
        }
        #expect(error?.code == .uncommitted)
        #expect(FileManager.default.fileExists(atPath: path.path))

        try repository.worktree.remove(worktree, force: true)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("Remove requires force for a locked worktree")
    func removeLockedWorktree() throws {
        let repository = try committedRepository()
        let path = worktreePath()
        let worktree = try repository.worktree.add(at: path, creatingBranchNamed: "feature")
        try lock(worktree, in: repository, reason: "in use")

        #expect(throws: SwiftGitXError.self) {
            try repository.worktree.remove(worktree)
        }

        try repository.worktree.remove(worktree, force: true)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("Remove prunes stale worktree metadata")
    func removeStaleWorktree() throws {
        let repository = try committedRepository()
        let path = worktreePath()
        let worktree = try repository.worktree.add(at: path, creatingBranchNamed: "feature")
        try FileManager.default.removeItem(at: path)

        let stale = try repository.worktree.get(at: path)
        #expect(!stale.isValid)

        try repository.worktree.remove(stale)
        #expect(repository.worktree[path] == nil)
        #expect(worktree.path.lastPathComponent == stale.path.lastPathComponent)
    }

    @Test("Main worktree cannot be moved or removed")
    func rejectMainWorktreeMutation() throws {
        let repository = try committedRepository()
        let main = try #require(repository.worktree.list().first)

        #expect(throws: SwiftGitXError.self) {
            try repository.worktree.move(main, to: worktreePath())
        }
        #expect(throws: SwiftGitXError.self) {
            try repository.worktree.remove(main)
        }
    }

    private func committedRepository() throws -> Repository {
        let repository = mockRepository()
        try repository.mockCommit()
        return repository
    }

    private func worktreePath(suffix: String = "", create: Bool = false) -> URL {
        mockDirectory(suffix: "-worktree\(suffix)", create: create)
    }

    private func lock(_ worktree: Worktree, in repository: Repository, reason: String) throws {
        let worktreesDirectory = repository.path.appendingPathComponent("worktrees", isDirectory: true)
        let administrativeDirectories = try FileManager.default.contentsOfDirectory(
            at: worktreesDirectory,
            includingPropertiesForKeys: nil
        )

        for directory in administrativeDirectories {
            let gitdirFile = directory.appendingPathComponent("gitdir", isDirectory: false)
            let gitdir = try String(contentsOf: gitdirFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedGitdir = worktree.path.appendingPathComponent(".git", isDirectory: false).path
            let gitdirURL = URL(fileURLWithPath: gitdir).standardizedFileURL.resolvingSymlinksInPath()
            let expectedGitdirURL = URL(fileURLWithPath: expectedGitdir).standardizedFileURL
                .resolvingSymlinksInPath()
            guard gitdirURL == expectedGitdirURL else { continue }

            try Data(reason.utf8).write(
                to: directory.appendingPathComponent("locked", isDirectory: false),
                options: .atomic
            )
            return
        }

        Issue.record("Failed to find administrative directory for worktree")
    }
}
