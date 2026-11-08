//
//  LCDiskSizeCalculator.swift
//  LiveContainerSwiftUI
//
//  Shared on-disk size measurement for app bundles and data containers.
//

import Foundation

struct LCAppDiskUsageResult: Sendable {
    let appBundleBytes: Int64
    let totalDataBytes: Int64
    let perContainerBytes: [String: Int64]
}

/// A container to measure. Kept as a value type so it can cross into the
/// detached measuring task without capturing the observable LCContainer.
struct LCDiskSizeContainerInput: Sendable {
    let folderName: String
    let url: URL
    let bookmarkResolved: Bool
}

enum LCDiskSizeCalculator {
    /// Human readable size (KB / MB / GB).
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// Recursively sums the allocated size of a directory on a background
    /// thread. Symbolic links are never followed: guest containers contain a
    /// link to the host TMPDIR which must not be counted as app data.
    nonisolated static func directorySize(at rootURL: URL) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDir) else {
                return 0
            }

            let resourceKeys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ]

            if !isDir.boolValue {
                guard let values = try? rootURL.resourceValues(forKeys: resourceKeys),
                      values.isSymbolicLink != true else {
                    return 0
                }
                return Int64(values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0)
            }

            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [],
                errorHandler: { _, _ in true } // skip unreadable children and keep going
            ) else {
                return 0
            }

            var total: Int64 = 0
            var iterationCount: UInt = 0
            for case let fileURL as URL in enumerator {
                iterationCount &+= 1
                if (iterationCount & 0x3F) == 0 {
                    try Task.checkCancellation()
                }
                guard let values = try? fileURL.resourceValues(forKeys: resourceKeys) else {
                    continue
                }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true else {
                    continue
                }
                total += Int64(values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0)
            }
            return total
        }.value
    }

    private nonisolated static func measureBundleSize(bundlePath: String?) async -> Int64 {
        guard let bundlePath else {
            return 0
        }
        return (try? await directorySize(at: URL(fileURLWithPath: bundlePath))) ?? 0
    }

    /// Measures the app bundle and every container of an app.
    nonisolated static func calculateAppUsage(
        bundlePath: String?,
        containers: [LCDiskSizeContainerInput]
    ) async throws -> LCAppDiskUsageResult {
        async let bundleSizeTask: Int64 = measureBundleSize(bundlePath: bundlePath)

        var perContainer: [String: Int64] = [:]
        var dataSum: Int64 = 0
        for item in containers {
            try Task.checkCancellation()
            var didAccess = false
            if item.bookmarkResolved {
                didAccess = item.url.startAccessingSecurityScopedResource()
            }
            defer {
                if didAccess {
                    item.url.stopAccessingSecurityScopedResource()
                }
            }
            // An offline external container simply reports 0 instead of
            // failing the whole calculation.
            let containerSize = (try? await directorySize(at: item.url)) ?? 0
            perContainer[item.folderName] = containerSize
            dataSum += containerSize
        }

        let bundleSize = (try? await bundleSizeTask) ?? 0
        return LCAppDiskUsageResult(
            appBundleBytes: bundleSize,
            totalDataBytes: dataSum,
            perContainerBytes: perContainer
        )
    }
}
