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
}

struct LCAppBanner: UIViewControllerRepresentable {
    var delegate: LCAppBannerDelegate

    @ObservedObject var model: LCAppModel

    /// When the banner is shown inside a folder, the id of that folder.
    private var folderId: String?

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) private var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    private let sharedModel = DataManager.shared.model

    init(appModel: LCAppModel, delegate: LCAppBannerDelegate, folderId: String? = nil) {
        _model = ObservedObject(wrappedValue: appModel)
        self.delegate = delegate
        self.folderId = folderId
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = LCAppBannerViewController(delegate: delegate, config: LCAppBannerConfiguration(model: model, dynamicColors: dynamicColors, darkModeIcon: darkModeIcon, folderId: folderId))
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
            folderId: folderId
        )
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIViewController, context: Context) -> CGSize? {
        guard let width = proposal.width else {
            return nil
        }
        return CGSize(width: width, height: LCAppBannerRootView.bannerHeight)
    }
}
