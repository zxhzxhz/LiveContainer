//
//  LCSandboxFileManager.swift
//  LiveContainerSwiftUI
//
//  Whitelisted access to the LiveContainer sandbox for the HTTP API.
//

import Foundation

enum LCSandboxFSException: LocalizedError {
    case invalidVirtualPath(String)
    case accessDeniedPathTraversal(String)
    case rootModificationForbidden
    case targetAlreadyExists(String)
    case fileNotFound(String)
    case isDirectory(String)
    case symbolicLinkOutsideRoot(String)

    var errorDescription: String? {
        switch self {
        case .invalidVirtualPath(let path):
            return "Invalid virtual path '\(path)'. Must start with /private or /shared."
        case .accessDeniedPathTraversal(let path):
            return "Access denied: path '\(path)' escapes the sandbox whitelist."
        case .rootModificationForbidden:
            return "Cannot delete or rename root mount points."
        case .targetAlreadyExists(let path):
            return "Target already exists at '\(path)' and overwrite is false."
        case .fileNotFound(let path):
            return "File or directory not found: '\(path)'."
        case .isDirectory(let path):
            return "Path '\(path)' is a directory, not a regular file."
        case .symbolicLinkOutsideRoot(let path):
            return "Refusing to follow symbolic link '\(path)' outside the sandbox."
        }
    }
}

struct LCFileItemDTO: Encodable {
    let name: String
    let virtualPath: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modificationDate: TimeInterval
}

final class LCSandboxFileManager {
    static let shared = LCSandboxFileManager()
    private init() {}

    private static let privatePrefix = "/private"
    private static let sharedPrefix = "/shared"

    /// Maps a virtual path (/private/... or /shared/...) to a physical URL that
    /// is guaranteed to stay inside the matching whitelist root.
    func resolveSafeURL(
        for virtualPath: String,
        allowRoot: Bool = true
    ) throws -> (url: URL, rootURL: URL, virtualPrefix: String) {
        let trimmed = virtualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw LCSandboxFSException.invalidVirtualPath(virtualPath)
        }

        let rootURL: URL
        let prefix: String
        let subPath: String

        if trimmed == Self.privatePrefix || trimmed.hasPrefix(Self.privatePrefix + "/") {
            rootURL = LCPath.docPath.standardizedFileURL
            prefix = Self.privatePrefix
            subPath = String(trimmed.dropFirst(Self.privatePrefix.count))
        } else if trimmed == Self.sharedPrefix || trimmed.hasPrefix(Self.sharedPrefix + "/") {
            rootURL = LCPath.lcGroupDocPath.standardizedFileURL
            prefix = Self.sharedPrefix
            subPath = String(trimmed.dropFirst(Self.sharedPrefix.count))
        } else {
            throw LCSandboxFSException.invalidVirtualPath(virtualPath)
        }

        let relativeClean = subPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relativeClean.isEmpty && !allowRoot {
            throw LCSandboxFSException.rootModificationForbidden
        }

        let candidateURL = relativeClean.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(relativeClean).standardizedFileURL

        let rootPath = rootURL.path
        let candidatePath = candidateURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw LCSandboxFSException.accessDeniedPathTraversal(virtualPath)
        }

        // A container may contain symlinks (for example tmp -> host TMPDIR);
        // refuse to resolve anything that leaves the whitelist root.
        let parentResolved = candidateURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        let rootResolved = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        if candidatePath != rootPath, !(parentResolved == rootResolved || parentResolved.hasPrefix(rootResolved + "/")) {
            throw LCSandboxFSException.accessDeniedPathTraversal(virtualPath)
        }

        return (candidateURL, rootURL, prefix)
    }

    private func requireNotSymlinkOutsideRoot(_ url: URL, rootURL: URL, virtualPath: String) throws {
        let fm = FileManager.default
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true else {
            return
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootResolved = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == rootResolved || resolved.hasPrefix(rootResolved + "/") else {
            throw LCSandboxFSException.symbolicLinkOutsideRoot(virtualPath)
        }
    }

    func listDirectory(virtualPath: String) throws -> [LCFileItemDTO] {
        let (targetURL, rootURL, prefix) = try resolveSafeURL(for: virtualPath, allowRoot: true)
        try requireNotSymlinkOutsideRoot(targetURL, rootURL: rootURL, virtualPath: virtualPath)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LCSandboxFSException.fileNotFound(virtualPath)
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let contents = try fm.contentsOfDirectory(
            at: targetURL,
            includingPropertiesForKeys: keys,
            options: []
        )
        return try contents.map { itemURL -> LCFileItemDTO in
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            let relative = Self.relativePath(of: itemURL, under: rootURL)
            return LCFileItemDTO(
                name: itemURL.lastPathComponent,
                virtualPath: prefix + relative,
                isDirectory: values?.isDirectory ?? false,
                isSymbolicLink: values?.isSymbolicLink ?? false,
                size: Int64(values?.fileSize ?? 0),
                modificationDate: (values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Resolves a file path for download, making sure a symlink cannot expose
    /// data outside the sandbox.
    func fileForDownload(virtualPath: String) throws -> URL {
        let (targetURL, rootURL, _) = try resolveSafeURL(for: virtualPath, allowRoot: false)
        try requireNotSymlinkOutsideRoot(targetURL, rootURL: rootURL, virtualPath: virtualPath)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            throw LCSandboxFSException.fileNotFound(virtualPath)
        }
        guard !isDir.boolValue else {
            throw LCSandboxFSException.isDirectory(virtualPath)
        }
        return targetURL
    }

    /// Writes an uploaded file next to its destination and atomically moves it
    /// into place, so an interrupted upload never corrupts existing data.
    func storeUploadedFile(from tempURL: URL, toVirtualPath: String, overwrite: Bool) throws {
        let (destinationURL, _, _) = try resolveSafeURL(for: toVirtualPath, allowRoot: false)
        let fm = FileManager.default

        if fm.fileExists(atPath: destinationURL.path) {
            guard overwrite else {
                throw LCSandboxFSException.targetAlreadyExists(toVirtualPath)
            }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: destinationURL.path, isDirectory: &isDir)
            guard !isDir.boolValue else {
                throw LCSandboxFSException.isDirectory(toVirtualPath)
            }
        } else {
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: destinationURL)
        }
    }

    func moveOrRename(fromVirtual: String, toVirtual: String, overwrite: Bool) throws {
        let (sourceURL, sourceRoot, _) = try resolveSafeURL(for: fromVirtual, allowRoot: false)
        let (destinationURL, _, _) = try resolveSafeURL(for: toVirtual, allowRoot: false)
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourceURL.path) else {
            throw LCSandboxFSException.fileNotFound(fromVirtual)
        }
        // Moving a symlink itself is safe, but never follow it out of bounds.
        try requireNotSymlinkOutsideRoot(sourceURL, rootURL: sourceRoot, virtualPath: fromVirtual)

        let sourceStandardPath = sourceURL.standardizedFileURL.path
        let destinationStandardPath = destinationURL.standardizedFileURL.path
        if sourceStandardPath == destinationStandardPath {
            return
        }
        if destinationStandardPath.hasPrefix(sourceStandardPath + "/") {
            throw LCSandboxFSException.accessDeniedPathTraversal(toVirtual)
        }

        if fm.fileExists(atPath: destinationURL.path) {
            guard overwrite else {
                throw LCSandboxFSException.targetAlreadyExists(toVirtual)
            }
            try fm.removeItem(at: destinationURL)
        } else {
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try fm.moveItem(at: sourceURL, to: destinationURL)
    }

    func deleteItem(virtualPath: String) throws {
        let (targetURL, rootURL, _) = try resolveSafeURL(for: virtualPath, allowRoot: false)
        let fm = FileManager.default
        guard fm.fileExists(atPath: targetURL.path) else {
            throw LCSandboxFSException.fileNotFound(virtualPath)
        }
        // Removing a symlink only unlinks it, but a resolved-out target would
        // still be surprising, so validate first.
        try requireNotSymlinkOutsideRoot(targetURL, rootURL: rootURL, virtualPath: virtualPath)
        try fm.removeItem(at: targetURL)
    }

    static func relativePath(of url: URL, under rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else {
            return "/" + url.lastPathComponent
        }
        let suffix = String(path.dropFirst(rootPath.count))
        return suffix.isEmpty ? "/" : suffix
    }
}
