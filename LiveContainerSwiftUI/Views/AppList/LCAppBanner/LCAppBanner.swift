//
//  LCAppBanner.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UIKit

protocol LCAppBannerDelegate {
    func removeApp(app: LCAppModel)
    func installMdm(data: Data)
    func openNavigationView(view: AnyView)
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle?
    func folderContextMenu(app: LCAppModel, folderId: String?) -> UIMenu?
}

struct LCAppBanner: UIViewControllerRepresentable {
    var delegate: LCAppBannerDelegate

    @ObservedObject var model: LCAppModel

    /// When the banner is shown inside a folder, the id of that folder.
    private var folderId: String?
    /// Whether the game controller focus ring is on this banner.
    private var isControllerFocused: Bool
    /// Incrementing this value asks the banner to present its quick action menu.
    private var quickActionNonce: Int

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    private let sharedModel = DataManager.shared.model

    init(
        appModel: LCAppModel,
        delegate: LCAppBannerDelegate,
        folderId: String? = nil,
        isControllerFocused: Bool = false,
        quickActionNonce: Int = 0
    ) {
        _model = ObservedObject(wrappedValue: appModel)
        self.delegate = delegate
        self.folderId = folderId
        self.isControllerFocused = isControllerFocused
        self.quickActionNonce = quickActionNonce
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = LCAppBannerViewController(delegate: delegate, config: LCAppBannerConfiguration(model: model, dynamicColors: dynamicColors, darkModeIcon: darkModeIcon, folderId: folderId, isControllerFocused: isControllerFocused, quickActionNonce: quickActionNonce))
        // Prime the content before SwiftUI performs its first measurement,
        // otherwise hidden badges would still count towards the available width.
        viewController.update(model: model, dynamicColors: dynamicColors, darkModeIcon: darkModeIcon, folderId: folderId, isControllerFocused: isControllerFocused, quickActionNonce: quickActionNonce)
        return viewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let viewController = uiViewController as? LCAppBannerViewController else {
            return
        }
        viewController.update(
            model: model,
            dynamicColors: dynamicColors,
            darkModeIcon: darkModeIcon,
            folderId: folderId,
            isControllerFocused: isControllerFocused,
            quickActionNonce: quickActionNonce
        )
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else {
            return nil
        }
        if let bannerVC = uiViewController as? LCAppBannerViewController {
            // Let the banner measure its own content so two-line names or a
            // remark never get clipped by the compact 88pt height.
            return CGSize(width: width, height: bannerVC.preferredBannerHeight(forWidth: width))
        }
        return CGSize(width: width, height: LCAppBannerRootView.bannerHeight)
    }
}
