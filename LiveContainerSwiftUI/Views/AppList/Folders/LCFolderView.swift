//
//  LCFolderView.swift
//  LiveContainerSwiftUI
//
//  Folder detail view: the apps inside a folder, with the folder's own
//  sorting settings.
//

import SwiftUI
import Combine

struct LCFolderView: View, LCAppBannerDelegate {

    let folderId: String

    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.presentationMode) private var presentationMode

    @ObservedObject private var folderManager = LCFolderManager.shared
    @ObservedObject private var gameController = LCGameControllerManager.shared

    @StateObject private var renameInput = InputHelper()
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()

    @State private var errorShow = false
    @State private var errorInfo = ""

    @State private var appPickerPresented = false
    @State private var customSortViewPresent = false
    @State private var deleteConfirmPresented = false

    @State private var navigateTo: AnyView?
    @State private var isNavigationActive = false
    @State private var controllerActionApp: LCAppModel?
    @State private var quickActionNonce = 0
    @State private var savedHomeFocusIndex = 0

    private var folder: LCFolder? {
        folderManager.folder(withId: folderId)
    }

    private var apps: [LCAppModel] {
        guard let folder else { return [] }
        return folderManager.apps(in: folder, from: sharedModel.apps)
    }

    var body: some View {
        Group {
            if let folder {
                content(for: folder)
            } else {
                Text("lc.folder.deleted".loc)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func content(for folder: LCFolder) -> some View {
        ScrollViewReader { scrollProxy in
        ScrollView {
            NavigationLink(
                destination: navigateTo,
                isActive: $isNavigationActive,
                label: {
                    EmptyView()
                })
            .hidden()

            LazyVStack {
                ForEach(Array(apps.enumerated()), id: \.element) { index, app in
                    LCAppBanner(
                        appModel: app,
                        delegate: self,
                        folderId: folder.id,
                        isControllerFocused: gameController.isFocusRingVisible && gameController.focusedIndex == index,
                        quickActionNonce: controllerActionApp == app ? quickActionNonce : 0
                    )
                    .id(app)
                }
            }
            .padding()

            if apps.isEmpty {
                Text("lc.folder.empty".loc)
                    .foregroundColor(.secondary)
                    .padding(.top, 40)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    gameController.notifyTouchInteraction()
                }
        )
        .onReceive(gameController.commandPublisher) { command in
            handleControllerCommand(command, scrollProxy: scrollProxy)
        }
        .onChange(of: apps.count) { newValue in
            if newValue == 0 {
                gameController.focusedIndex = 0
            } else if gameController.focusedIndex >= newValue {
                gameController.focusedIndex = newValue - 1
            }
        }
        .onAppear {
            if !gameController.isInFolderView {
                savedHomeFocusIndex = gameController.focusedIndex
                gameController.isInFolderView = true
                gameController.focusedIndex = 0
            }
        }
        .onDisappear {
            if !isNavigationActive {
                gameController.isInFolderView = false
                gameController.focusedIndex = savedHomeFocusIndex
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    appPickerPresented = true
                } label: {
                    Label("add", systemImage: "plus")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                sortMenu(for: folder)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await promptRename() }
                    } label: {
                        Label("lc.folder.rename".loc, systemImage: "pencil")
                    }
                    Button {
                        folderManager.togglePin(folderId: folder.id)
                    } label: {
                        Label(folder.pinned ? "lc.folder.unpin".loc : "lc.folder.pin".loc,
                              systemImage: folder.pinned ? "pin.slash" : "pin")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleteConfirmPresented = true
                    } label: {
                        Label("lc.folder.delete".loc, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $appPickerPresented) {
            LCAppPickerView(folderId: folder.id)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView(folderId: folder.id)
        }
        .textFieldAlert(
            isPresented: $renameInput.show,
            title: "lc.folder.rename".loc,
            text: $renameInput.initVal,
            placeholder: "lc.folder.name".loc,
            action: { newText in
                renameInput.close(result: newText)
            },
            actionCancel: { _ in
                renameInput.close(result: nil)
            }
        )
        .alert("lc.folder.delete".loc, isPresented: $deleteConfirmPresented) {
            Button("lc.folder.delete".loc, role: .destructive) {
                deleteFolder()
            }
            Button("lc.common.cancel".loc, role: .cancel) {
            }
        } message: {
            Text("lc.folder.deleteTip".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented: $generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                UIPasteboard.general.string = errorInfo
            })
        } message: {
            Text(errorInfo)
        }
        }
    }

    private func handleControllerCommand(_ command: LCControllerCommand, scrollProxy: ScrollViewProxy) {
        // A pushed settings page owns the controller until it is popped.
        if isNavigationActive {
            if command == .cancel {
                isNavigationActive = false
                navigateTo = nil
            }
            return
        }
        guard !appPickerPresented,
              !customSortViewPresent,
              !deleteConfirmPresented,
              !renameInput.show,
              !generatedIconStyleSelector.show else {
            return
        }
        if command == .cancel {
            presentationMode.wrappedValue.dismiss()
            return
        }
        let items = apps
        guard !items.isEmpty else {
            return
        }
        let index = min(max(gameController.focusedIndex, 0), items.count - 1)

        switch command {
        case .moveUp:
            let next = max(0, index - 1)
            gameController.focusedIndex = next
            withAnimation(.easeInOut(duration: 0.18)) {
                scrollProxy.scrollTo(items[next], anchor: .center)
            }
        case .moveDown:
            let next = min(items.count - 1, index + 1)
            gameController.focusedIndex = next
            withAnimation(.easeInOut(duration: 0.18)) {
                scrollProxy.scrollTo(items[next], anchor: .center)
            }
        case .confirm:
            Task { await launchAppFromController(items[index]) }
        case .contextMenu:
            controllerActionApp = items[index]
            quickActionNonce += 1
        case .openSettings:
            navigateTo = AnyView(LCAppSettingsView(model: items[index]))
            isNavigationActive = true
        case .cancel, .previousTab, .nextTab:
            break
        }
    }

    private func launchAppFromController(_ app: LCAppModel) async {
        if #available(iOS 16.0, *),
           let currentDataFolder = app.uiSelectedContainer?.folderName,
           MultitaskManager.isUsing(container: currentDataFolder) {
            var found = false
            if #available(iOS 16.1, *) {
                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: currentDataFolder)
            }
            if !found {
                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: currentDataFolder)
            }
            if found {
                return
            }
        }
        if app.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        do {
            try await app.runApp()
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    private func sortMenu(for folder: LCFolder) -> some View {
        Menu {
            Picker("Sort by", selection: Binding(get: {
                folder.sortType
            }, set: { newValue in
                folderManager.setSortType(newValue, folderId: folder.id)
                if newValue == .custom {
                    customSortViewPresent = true
                }
            })) {
                ForEach(AppSortType.allCases, id: \.self) { sortType in
                    Label(sortType.displayName, systemImage: sortType.systemImage)
                        .tag(sortType)
                }
            }
            if folder.sortType == .custom {
                Divider()
                Button {
                    customSortViewPresent = true
                } label: {
                    Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                }
            }
        } label: {
            Label("Sort by", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    // MARK: - Actions

    private func promptRename() async {
        guard let folder else { return }
        guard let newName = await renameInput.open(initVal: folder.name),
              !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        folderManager.rename(folderId: folder.id, to: newName)
    }

    private func deleteFolder() {
        folderManager.delete(folderId: folderId)
        presentationMode.wrappedValue.dismiss()
    }

    // MARK: - LCAppBannerDelegate

    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            if let appId = LCAppSortManager.shared.getUniqueIdentifier(for: app) {
                folderManager.removeFromAllFolders(appId: appId)
            }
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
        }
    }

    func installMdm(data: Data) {
        guard let url = URL(string: "data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())") else {
            return
        }
        UIApplication.shared.open(url)
    }

    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }

    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
    }

    func folderContextMenu(app: LCAppModel, folderId: String?) -> UIMenu? {
        guard let appId = LCAppSortManager.shared.getUniqueIdentifier(for: app) else {
            return nil
        }
        var children: [UIMenuElement] = []

        if let folderId {
            children.append(UIAction(title: "lc.folder.remove".loc,
                                     image: UIImage(systemName: "folder.badge.minus")) { _ in
                folderManager.remove(appId: appId, from: folderId)
            })
        }

        for other in folderManager.folders where other.id != folderId {
            children.append(UIAction(title: other.name, image: UIImage(systemName: "folder")) { _ in
                folderManager.add(appId: appId, to: other.id)
            })
        }

        if children.isEmpty {
            return nil
        }

        return UIMenu(title: "lc.folder.manageTitle".loc,
                      image: UIImage(systemName: "folder"),
                      children: children)
    }
}
