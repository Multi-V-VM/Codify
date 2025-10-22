//
//  RightPanelManager.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI

struct RightPanel {
    let id: String
    let icon: String
    let label: String
    let mainView: AnyView
    let toolBarView: AnyView?
}

class RightPanelManager: ObservableObject {
    @Published var panels: [RightPanel] = []
    @Published var selectedPanelId: String?

    func registerPanel(panel: RightPanel) {
        panels.append(panel)

        // Select first panel by default
        if selectedPanelId == nil {
            selectedPanelId = panel.id
        }
    }

    func deregisterPanel(id: String) {
        panels.removeAll(where: { $0.id == id })

        // If we removed the selected panel, select another one
        if selectedPanelId == id {
            selectedPanelId = panels.first?.id
        }
    }

    func selectPanel(id: String) {
        selectedPanelId = id
    }

    var selectedPanel: RightPanel? {
        panels.first(where: { $0.id == selectedPanelId })
    }
}
