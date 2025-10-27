//
//  DebuggerExtension.swift
//  Code
//

import SwiftUI

@available(iOS 18.0, *)
class DebuggerExtension: CodeAppExtension {
    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        let panel = RightPanel(
            id: "DEBUGGER",
            icon: "ladybug.fill",
            label: "Debugger",
            mainView: AnyView(DebuggerSidebarView()),
            toolBarView: nil
        )
        app.rightPanelManager.registerPanel(panel: panel)
    }
}

