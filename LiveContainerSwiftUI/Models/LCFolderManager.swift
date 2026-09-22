//
//  LCFolderManager.swift
//  LiveContainerSwiftUI
//
//  UI-only app folders.
//
//  Folder assignments are intentionally kept out of the guest app database
//  (LCAppInfo / the "Apps" json) and live in a standalone file
//  `Documents/LCUIFolders.json` instead:
//   * the official LiveContainer build simply ignores that file, so installing
//     it over this build loses only the folder feature - nothing breaks,
//     every app stays visible in the normal list;
//   * no guest app metadata is modified, so uninstalling the tweak/build can
//     never leave a guest app in a broken state.
//

import Foundation
import Combine

struct LCFolder: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var pinned: Bool = false
    /// Membership, in the order apps were added.
    var appIds: [String] = []
    /// Per folder sort settings - independent from the root app list.
    var sortTypeRaw: String = AppSortType.defaultOrder.rawValue
    var customSortOrder: [String] = []

    var sortType: AppSortType {
        get { AppSortType(rawValue: sortTypeRaw) ?? .defaultOrder }
        set { sortTypeRaw = newValue.rawValue }
    }
}

private struct LCFolderDatabase: Codable {
    var version: Int = 1
    var folders: [LCFolder] = []
}

final class LCFolderManager: ObservableObject {

    static let shared = LCFolderManager()

    static let fileName = "LCUIFolders.json"

    @Published private(set) var folders: [LCFolder] = []

    private let fileURL: URL

    init(fileURL: URL = LCPath.docPath.appendingPathComponent(LCFolderManager.fileName)) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            folders = []
            return
        }
        do {
            folders = try JSONDecoder().decode(LCFolderDatabase.self, from: data).folders
        } catch {
            // A corrupt or foreign file must never break the app list.
            NSLog("[LCFolderManager] cannot read \(Self.fileName): \(error)")
            folders = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(LCFolderDatabase(version: 1, folders: folders))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[LCFolderManager] cannot write \(Self.fileName): \(error)")
        }
    }

    // MARK: - Lookup

    /// Pinned folders first, everything else keeps its insertion order.
    var foldersForDisplay: [LCFolder] {
        folders.filter { $0.pinned } + folders.filter { !$0.pinned }
    }

    func folder(withId id: String) -> LCFolder? {
        folders.first { $0.id == id }
    }

    func folderContaining(appId: String) -> LCFolder? {
        folders.first { $0.appIds.contains(appId) }
    }

    func appIdsInFolders() -> Set<String> {
        Set(folders.flatMap { $0.appIds })
    }

    /// Apps of a folder, sorted with the folder's own settings.
    func apps(in folder: LCFolder, from apps: [LCAppModel]) -> [LCAppModel] {
        let members = apps.filter { app in
            guard let appId = LCAppSortManager.shared.getUniqueIdentifier(for: app) else {
                return false
            }
            return folder.appIds.contains(appId)
        }
        return LCAppSortManager.shared.getSortedApps(members, sortType: folder.sortType, customSortOrder: folder.customSortOrder)
    }

    func appCount(in folder: LCFolder, from apps: [LCAppModel]) -> Int {
        apps.filter { app in
            guard let appId = LCAppSortManager.shared.getUniqueIdentifier(for: app) else {
                return false
            }
            return folder.appIds.contains(appId)
        }.count
    }

    // MARK: - Folder management

    @discardableResult
    func createFolder(named name: String) -> LCFolder {
        let folder = LCFolder(name: Self.sanitizedName(name))
        folders.append(folder)
        save()
        return folder
    }

    func rename(folderId: String, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderId }) else { return }
        folders[index].name = Self.sanitizedName(name)
        save()
    }

    func delete(folderId: String) {
        guard folders.contains(where: { $0.id == folderId }) else { return }
        folders.removeAll { $0.id == folderId }
        save()
    }

    func togglePin(folderId: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderId }) else { return }
        folders[index].pinned.toggle()
        save()
    }

    func setSortType(_ sortType: AppSortType, folderId: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderId }) else { return }
        folders[index].sortType = sortType
        save()
    }

    func setCustomSortOrder(_ order: [String], folderId: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderId }) else { return }
        folders[index].customSortOrder = order
        folders[index].sortType = .custom
        save()
    }

    // MARK: - Membership

    /// Adds an app to a folder. An app can only be in one folder, so it is
    /// removed from every other folder first ("move into folder").
    func add(appId: String, to folderId: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderId }) else { return }
        for i in folders.indices where i != index {
            folders[i].appIds.removeAll { $0 == appId }
        }
        if !folders[index].appIds.contains(appId) {
            folders[index].appIds.append(appId)
        }
        save()
    }

    func remove(appId: String, from folderId: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderId }) else { return }
        guard folders[index].appIds.contains(appId) else { return }
        folders[index].appIds.removeAll { $0 == appId }
        save()
    }

    func removeFromAllFolders(appId: String) {
        var changed = false
        for index in folders.indices where folders[index].appIds.contains(appId) {
            folders[index].appIds.removeAll { $0 == appId }
            changed = true
        }
        if changed {
            save()
        }
    }

    /// Drops ids of apps that do not exist anymore (uninstalled, updated, ...)
    func prune(validAppIds: Set<String>) {
        var changed = false
        for index in folders.indices {
            let kept = folders[index].appIds.filter { validAppIds.contains($0) }
            if kept.count != folders[index].appIds.count {
                folders[index].appIds = kept
                changed = true
            }
            let keptOrder = folders[index].customSortOrder.filter { validAppIds.contains($0) }
            if keptOrder.count != folders[index].customSortOrder.count {
                folders[index].customSortOrder = keptOrder
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    private static func sanitizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "lc.folder.unnamed".loc : trimmed
    }
}

extension LCAppBannerDelegate {
    /// Extra context menu section for folder handling. Default: no folder menu.
    func folderContextMenu(app: LCAppModel, folderId: String?) -> UIMenu? {
        return nil
    }
}
