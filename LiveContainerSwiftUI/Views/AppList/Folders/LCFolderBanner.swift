//
//  LCFolderBanner.swift
//  LiveContainerSwiftUI
//
//  Folder row shown in the root app list.
//

import SwiftUI

struct LCFolderBanner: View {
    let folder: LCFolder
    let appCount: Int
    var onRename: () -> Void
    var onTogglePin: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                                         startPoint: .top, endPoint: .bottom))
                Image(systemName: "folder.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(folder.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    if folder.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
                Text("lc.folder.appCount %lld".localizeWithFormat(appCount))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 88)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contextMenu {
            Button(action: onRename) {
                Label("lc.folder.rename".loc, systemImage: "pencil")
            }
            Button(action: onTogglePin) {
                Label(folder.pinned ? "lc.folder.unpin".loc : "lc.folder.pin".loc,
                      systemImage: folder.pinned ? "pin.slash" : "pin")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("lc.folder.delete".loc, systemImage: "trash")
            }
        }
    }
}
