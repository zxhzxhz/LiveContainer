//
//  LCAppPickerView.swift
//  LiveContainerSwiftUI
//
//  Picker used to move apps into a folder.
//

import SwiftUI

struct LCAppPickerView: View {
    let folderId: String

    @Environment(\.presentationMode) private var presentationMode
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var folderManager = LCFolderManager.shared
    @ObservedObject private var sortManager = LCAppSortManager.shared
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    @State private var selection: Set<String> = []

    private var folder: LCFolder? {
        folderManager.folder(withId: folderId)
    }

    private var candidateApps: [LCAppModel] {
        sortManager.sortedApps
    }

    var body: some View {
        NavigationView {
            List {
                ForEach(candidateApps, id: \.self) { app in
                    let appId = LCAppSortManager.shared.getUniqueIdentifier(for: app) ?? ""
                    let currentFolder = folderManager.folderContaining(appId: appId)

                    Button {
                        toggle(appId)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selection.contains(appId) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(selection.contains(appId) ? .accentColor : Color(uiColor: .tertiaryLabel))

                            IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.appInfo.displayName())
                                    .font(.system(size: 15, weight: .bold))
                                    .lineLimit(1)
                                if let currentFolder, currentFolder.id != folderId {
                                    Text("lc.folder.moveFromFolder %@".localizeWithFormat(currentFolder.name))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else if currentFolder?.id == folderId {
                                    Text("lc.folder.alreadyInFolder".loc)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(folder?.name ?? "lc.folder.addApps".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) {
                        save()
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func toggle(_ appId: String) {
        guard appId != "" else { return }
        if selection.contains(appId) {
            selection.remove(appId)
        } else {
            selection.insert(appId)
        }
    }

    private func save() {
        for appId in selection {
            folderManager.add(appId: appId, to: folderId)
        }
        presentationMode.wrappedValue.dismiss()
    }
}
