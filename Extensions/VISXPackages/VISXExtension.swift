//
//  VISXExtension.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI

class VISXExtension: CodeAppExtension {
    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        // Register the VISX package manager in the right panel
        let visxPanel = RightPanel(
            id: "VISX_PACKAGES",
            icon: "shippingbox",
            label: "VISX Packages",
            mainView: AnyView(VISXPackageManagerView()),
            toolBarView: nil
        )

        app.rightPanelManager.registerPanel(panel: visxPanel)
    }
}
