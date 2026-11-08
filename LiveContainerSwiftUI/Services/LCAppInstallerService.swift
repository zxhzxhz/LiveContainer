//
//  LCAppInstallerService.swift
//  LiveContainerSwiftUI
//
//  Headless install / uninstall pipeline shared by the UI and the HTTP API.
//

import Foundation

struct LCInstalledAppDTO: Encodable {
    let displayName: String
    let bundleIdentifier: String
    let relativeBundlePath: String
    let version: String
    let isShared: Bool
    let isHidden: Bool
    let isJITNeeded: Bool
    let containers: [String]
    let signWarning: String?
}

enum LCInstallerError: LocalizedError {
    case subContainerReadOnly
    case installInProgress
    case containerInUse(String)
    case appNotFound
    case notAnIPA
    case bundleNotFound
    case infoPlistUnreadable
    case builtInAppNotRemovable
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case .subContainerReadOnly:
            return "lc.appList.manageInPrimaryTip".loc
        case .installInProgress:
            return "Another installation is currently in progress."
        case .containerInUse(let scheme):
            return "lc.container.inUseBy %@".localizeWithFormat(scheme)
        case .appNotFound:
            return "lc.appList.appNotFoundError".loc
        case .notAnIPA:
            return "lc.appList.urlFileIsNotIpaError".loc
        case .bundleNotFound:
            return "lc.appList.bundleNotFondError".loc
        case .infoPlistUnreadable:
            return "lc.appList.infoPlistCannotReadError".loc
        case .builtInAppNotRemovable:
            return "The built-in SideStore app cannot be modified."
        case .signingFailed(let message):
            return message
        }
    }
}

struct LCFinalizedInstallResult {
    let model: LCAppModel
    let signSucceeded: Bool
    let signError: String?
}

@MainActor
final class LCAppInstallerService {
    static let shared = LCAppInstallerService()
    private var isInstalling = false
    /// Delegate attached to newly installed LCAppModels so headless HTTP API
    /// installs can still present JIT prompts when launched from the UI.
    var defaultAppDelegate: LCAppModelDelegate?
    private init() {}

    // MARK: - Queries

    func installedApps(includeHidden: Bool) -> [LCInstalledAppDTO] {
        let sharedModel = DataManager.shared.model
        var models = sharedModel.apps
        if includeHidden {
            models.append(contentsOf: hiddenAppsForQueries)
        }
        return models.map { dto(for: $0, signWarning: nil) }
    }

    /// DataManager moves apps between arrays; query both to stay consistent.
    private var hiddenAppsForQueries: [LCAppModel] {
        return DataManager.shared.model.hiddenApps
    }

    private func dto(for model: LCAppModel, signWarning: String? = nil) -> LCInstalledAppDTO {
        return LCInstalledAppDTO(
            displayName: model.displayName,
            bundleIdentifier: model.bundleIdentifier,
            relativeBundlePath: model.appInfo.relativeBundlePath ?? "",
            version: model.version,
            isShared: model.uiIsShared,
            isHidden: model.uiIsHidden,
            isJITNeeded: model.uiIsJITNeeded,
            containers: model.uiContainers.map { $0.folderName },
            signWarning: signWarning
        )
    }

    // MARK: - Install

    /// Installs an IPA without any UI interaction.
    func installIPA(from ipaFileURL: URL, overwrite: Bool) async throws -> LCInstalledAppDTO {
        guard DataManager.shared.model.multiLCStatus != 2 else {
            throw LCInstallerError.subContainerReadOnly
        }
        guard !isInstalling else {
            throw LCInstallerError.installInProgress
        }
        isInstalling = true
        defer { isInstalling = false }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("APIInstall_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        let extractStatus = await Task.detached(priority: .userInitiated) {
            extract(ipaFileURL.path, workDir.path, decompressProgress)
        }.value
        guard extractStatus == 0 else {
            throw LCInstallerError.notAnIPA
        }

        let payloadPath = workDir.appendingPathComponent("Payload")
        guard let payloadContents = try? fm.contentsOfDirectory(atPath: payloadPath.path),
              let appBundleName = payloadContents.first(where: { $0.hasSuffix(".app") }) else {
            throw LCInstallerError.bundleNotFound
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path),
              let bundleId = newAppInfo.bundleIdentifier() else {
            throw LCInstallerError.infoPlistUnreadable
        }

        let sharedModel = DataManager.shared.model
        let existingApps = (sharedModel.apps + sharedModel.hiddenApps).filter {
            $0.appInfo.bundleIdentifier() == bundleId
        }

        var appRelativePath = "\(bundleId.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace: LCAppModel? = nil

        if let existing = existingApps.first, overwrite {
            for container in existing.appInfo.containers {
                if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
                    throw LCInstallerError.containerInUse(runningLC)
                }
            }
            appToReplace = existing
            appRelativePath = existing.appInfo.relativeBundlePath ?? appRelativePath
            outputFolder = (existing.uiIsShared ? LCPath.lcGroupBundlePath : LCPath.bundlePath)
                .appendingPathComponent(appRelativePath)
        } else if fm.fileExists(atPath: outputFolder.path) || !existingApps.isEmpty {
            appRelativePath = "\(bundleId.sanitizeNonACSII())_\(Int(CFAbsoluteTimeGetCurrent())).app"
            outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        }

        let result = try await finalizeInstalledApp(
            appBundleURL: appFolderPath,
            appRelativePath: appRelativePath,
            outputFolder: outputFolder,
            appToReplace: appToReplace,
            progress: nil
        )
        return dto(for: result.model, signWarning: result.signError)
    }

    /// Moves an extracted bundle into place, signs it, copies the previous
    /// configuration when replacing, and registers the new app model.
    func finalizeInstalledApp(
        appBundleURL: URL,
        appRelativePath: String,
        outputFolder: URL,
        appToReplace: LCAppModel?,
        progress: Progress?
    ) async throws -> LCFinalizedInstallResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputFolder.path) {
            try fm.removeItem(at: outputFolder)
        }
        try fm.createDirectory(at: outputFolder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: appBundleURL, to: outputFolder)

        guard let finalNewApp = LCAppInfo(bundlePath: outputFolder.path) else {
            throw LCInstallerError.infoPlistUnreadable
        }
        finalNewApp.relativeBundlePath = appRelativePath

        if (appToReplace?.uiDontSign ?? false) || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
            finalNewApp.dontSign = true
        }

        var signSucceeded = false
        var signError: String? = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signSucceeded = success
                signError = error
                continuation.resume()
            }, progressHandler: { signProgress in
                if let signProgress, let progress {
                    progress.addChild(signProgress, withPendingUnitCount: 20)
                }
            }, forceSign: false)
        }

        if let appToReplace {
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.fixBackgroundTaskIdentifiers = appToReplace.appInfo.fixBackgroundTaskIdentifiers
            finalNewApp.enableBackgroundKeepAlive = appToReplace.appInfo.enableBackgroundKeepAlive
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            finalNewApp.spoofSDKVersion = true
        }
        finalNewApp.installationDate = Date.now

        let sharedModel = DataManager.shared.model
        let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: defaultAppDelegate)
        if let appToReplace {
            if let oldSchemes = appToReplace.appInfo.urlSchemes(), !oldSchemes.isEmpty {
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: oldSchemes as [Any])
            }
            if appToReplace.uiIsHidden {
                sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                sharedModel.hiddenApps.append(newAppModel)
            } else {
                sharedModel.apps.removeAll { $0 == appToReplace }
                sharedModel.apps.append(newAppModel)
                if let urlSchemes = finalNewApp.urlSchemes(), !urlSchemes.isEmpty {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as [Any])
                }
            }
        } else {
            sharedModel.apps.append(newAppModel)
            if let urlSchemes = finalNewApp.urlSchemes(), !urlSchemes.isEmpty {
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: urlSchemes as [Any])
            }
        }

        return LCFinalizedInstallResult(
            model: newAppModel,
            signSucceeded: signSucceeded,
            signError: signError
        )
    }

    // MARK: - Uninstall

    /// Removes an app bundle and, unless keepData is set, its containers and
    /// keychain entries.
    func uninstallApp(identifier: String, keepData: Bool) async throws {
        let sharedModel = DataManager.shared.model
        guard sharedModel.multiLCStatus != 2 else {
            throw LCInstallerError.subContainerReadOnly
        }
        let allApps = sharedModel.apps + sharedModel.hiddenApps
        guard let targetModel = allApps.first(where: {
            $0.appInfo.relativeBundlePath == identifier || $0.appInfo.bundleIdentifier() == identifier
        }) else {
            throw LCInstallerError.appNotFound
        }
        guard !(targetModel.appInfo is BuiltInSideStoreAppInfo) else {
            throw LCInstallerError.builtInAppNotRemovable
        }

        let appInfo = targetModel.appInfo
        for container in appInfo.containers {
            if let runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
                throw LCInstallerError.containerInUse(runningLC)
            }
        }

        guard let bundlePath = appInfo.bundlePath() else {
            throw LCInstallerError.appNotFound
        }

        let fm = FileManager.default
        try fm.removeItem(atPath: bundlePath)

        if let appId = LCAppSortManager.shared.getUniqueIdentifier(for: targetModel) {
            LCFolderManager.shared.removeFromAllFolders(appId: appId)
        }
        if let urlSchemes = appInfo.urlSchemes(), !urlSchemes.isEmpty {
            UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                .removeObjects(in: urlSchemes as [Any])
        }
        sharedModel.apps.removeAll { $0 == targetModel }
        sharedModel.hiddenApps.removeAll { $0 == targetModel }

        if !keepData {
            let remainingApps = sharedModel.apps + sharedModel.hiddenApps
            for container in appInfo.containers {
                let dataUUID = container.folderName
                let sharedByOtherApp = remainingApps.contains { other in
                    other.appInfo.containers.contains { $0.folderName == dataUUID }
                }
                guard !sharedByOtherApp else {
                    continue
                }
                let dataURL = container.isShared
                    ? LCPath.lcGroupDataPath.appendingPathComponent(dataUUID)
                    : LCPath.dataPath.appendingPathComponent(dataUUID)
                if fm.fileExists(atPath: dataURL.path) {
                    try? fm.removeItem(at: dataURL)
                }
                LCUtils.removeAppKeychain(dataUUID: dataUUID)
                sharedModel.appDataFolderNames.removeAll { $0 == dataUUID }
            }
        }
    }
}
