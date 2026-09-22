//
//  LCCustomSortView.swift
//  LiveContainerSwiftUI
//
//  Created by boa-z on 2025/6/21.
//
import SwiftUI
import Combine

struct LCCustomSortView: View {
    /// When set, the custom order is edited for the given folder instead of
    /// the root app list.
    var folderId: String? = nil

    @EnvironmentObject private var sharedModel: SharedModel
    @Environment(\.presentationMode) var presentationMode
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    @ObservedObject private var folderManager = LCFolderManager.shared

    // Local state for editing without modifying shared model
    @State private var localApps: [LCAppModel] = []
    @State private var localHiddenApps: [LCAppModel] = []

    private var isFolderMode: Bool {
        folderId != nil
    }
    
    var body: some View {
        NavigationView {
            Form {
                // Visible apps section
                if !localApps.isEmpty {
                        ForEach(localApps, id: \.self) { app in
                            HStack {
                                IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.appInfo.displayName())
                                        .font(.system(size: 16, weight: .bold))
                                        .lineLimit(1)
                                    Text("\(app.appInfo.version() ?? "?") - \(app.appInfo.bundleIdentifier() ?? "?")")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Text(app.uiSelectedContainer?.name ?? "lc.appBanner.noDataFolder".loc)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .onMove { source, destination in
                            localApps.move(fromOffsets: source, toOffset: destination)
                        }
                }
                
                // Hidden apps section
                if !isFolderMode && sharedModel.isHiddenAppUnlocked && !localHiddenApps.isEmpty {
                    Section("lc.appList.hiddenApps".loc) {
                        ForEach(localHiddenApps, id: \.self) { app in
                             HStack {
                                 IconImageView(icon: app.appInfo.iconIsDarkIcon(darkModeIcon))
                                    .frame(width: 60, height: 60)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.appInfo.displayName())
                                        .font(.system(size: 16, weight: .bold))
                                        .lineLimit(1)
                                    Text("\(app.appInfo.version() ?? "?") - \(app.appInfo.bundleIdentifier() ?? "?")")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Text(app.uiSelectedContainer?.name ?? "lc.appBanner.noDataFolder".loc)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .onMove { source, destination in
                            localHiddenApps.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                }
                
                Section {
                    Button("lc.common.reset".loc) {
                        // Reset only affects local state
                        resetToAlphabetical()
                    }
                    .foregroundColor(.orange)
                } footer: {
                    Text("lc.appList.sort.customSortResetTip".loc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("lc.appList.sort.custom".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Cancel button
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) {
                        cancelChanges()
                    }
                }
                // Done button
                ToolbarItem(placement: .confirmationAction) {
                    Button("lc.common.done".loc) {
                        saveChanges()
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
        }
        .onAppear {
            // Initialize local state when view appears
            initializeLocalState()
        }
    }
    
    // MARK: - Private Methods

    private func initializeLocalState() {
        let manager = LCAppSortManager.shared
        if let folderId, let folder = folderManager.folder(withId: folderId) {
            self.localApps = manager.getSortedApps(folderManager.apps(in: folder, from: sharedModel.apps), sortType: .custom, customSortOrder: folder.customSortOrder)
            self.localHiddenApps = []
            return
        }
        self.localApps = manager.getSortedApps(sharedModel.apps, sortType: .custom, customSortOrder: manager.customSortOrder)
        self.localHiddenApps = manager.getSortedApps(sharedModel.hiddenApps, sortType: .custom, customSortOrder: manager.customSortOrder)
    }
    
    private func resetToAlphabetical() {
        self.localApps.sort { $0.appInfo.displayName().localizedStandardCompare($1.appInfo.displayName()) == .orderedAscending }
        self.localHiddenApps.sort { $0.appInfo.displayName().localizedStandardCompare($1.appInfo.displayName()) == .orderedAscending }
    }
    
    private func cancelChanges() {
        presentationMode.wrappedValue.dismiss()
    }
    
    private func saveChanges() {
        let manager = LCAppSortManager.shared
        
        if let folderId {
            let newCustomOrder = localApps.compactMap { manager.getUniqueIdentifier(for: $0) }
            folderManager.setCustomSortOrder(newCustomOrder, folderId: folderId)
            presentationMode.wrappedValue.dismiss()
            return
        }
        
        let newCustomOrder = (localApps + localHiddenApps)
            .compactMap { manager.getUniqueIdentifier(for: $0) }
        
        manager.customSortOrder = newCustomOrder
        manager.appSortType = .custom
        
        presentationMode.wrappedValue.dismiss()
    }
}
