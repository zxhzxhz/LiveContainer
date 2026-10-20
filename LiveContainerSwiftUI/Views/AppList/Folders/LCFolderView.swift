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

    @StateObject private var renameInput = InputHelper()
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()

    @State private var errorShow = false
    @State private var errorInfo = ""

    @State private var appPickerPresented = false
    @State private var customSortViewPresent = false
    @State private var deleteConfirmPresented = false

    @State private var navigateTo: AnyView?
    @State private var isNavigationActive = false

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
        ScrollView {
            NavigationLink(
                destination: navigateTo,
                isActive: $isNavigationActive,
                label: {
                    EmptyView()
                })
            .hidden()

            LazyVStack {
                ForEach(apps, id: \.self) { app in
                    LCAppBanner(appModel: app, delegate: self, folderId: folder.id)
                }
            }
            .padding()

            if apps.isEmpty {
                Text("lc.folder.empty".loc)
                    .foregroundColor(.secondary)
                    .padding(.top, 40)
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
