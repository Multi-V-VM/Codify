//
//  WasminspectExtension.swift
//  Code
//
//  Extension for Wasminspect WebAssembly debugger integration
//

import SwiftUI

class WasminspectExtension: CodeAppExtension {
    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        // Register the Wasminspect panel in the bottom panel area
        let panel = Panel(
            labelId: "WASMINSPECT",
            mainView: AnyView(WasminspectSidebarView()),
            toolBarView: nil
        )
        contribution.panel.registerPanel(panel: panel)
    }
}
