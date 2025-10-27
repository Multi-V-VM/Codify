//
//  ChatExtension.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI

@available(iOS 18.0, *)
class ChatExtension: CodeAppExtension {
    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        // Register the chat panel in the right panel
        let chatPanel = RightPanel(
            id: "CHAT",
            icon: "bubble.left.and.bubble.right",
            label: "AI Chat",
            mainView: AnyView(ChatView()),
            toolBarView: AnyView(ChatToolbarView())
        )

        app.rightPanelManager.registerPanel(panel: chatPanel)
    }
}
