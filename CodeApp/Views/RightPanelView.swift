//
//  RightPanelView.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI

private let PANEL_MINIMUM_WIDTH: CGFloat = 200
private let PANEL_DEFAULT_WIDTH: CGFloat = 320
private let PANEL_MAXIMUM_WIDTH: CGFloat = 600

struct RightPanelView: View {
    @EnvironmentObject var rightPanelManager: RightPanelManager
    @SceneStorage("rightPanel.visible") var isVisible: Bool = false
    @SceneStorage("rightPanel.width") var panelWidth: Double = PANEL_DEFAULT_WIDTH
    @GestureState private var translation: CGFloat?

    var maxWidth: CGFloat {
        PANEL_MAXIMUM_WIDTH
    }

    func evaluateProposedWidth(proposal: CGFloat) {
        if proposal < PANEL_MINIMUM_WIDTH {
            panelWidth = PANEL_MINIMUM_WIDTH
        } else if proposal > maxWidth {
            panelWidth = maxWidth
        } else {
            panelWidth = proposal
        }
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 0) {
                // Resize handle
                Rectangle()
                    .fill(Color.init(id: "panel.border"))
                    .frame(width: 1)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let proposedNewWidth = panelWidth - value.translation.width
                                evaluateProposedWidth(proposal: proposedNewWidth)
                            }
                    )

                VStack(spacing: 0) {
                    // Panel tabs
                    PanelTabBar()
                        .environmentObject(rightPanelManager)
                        .frame(height: 40)

                    // Panel content
                    if let selectedPanel = rightPanelManager.selectedPanel {
                        VStack(spacing: 0) {
                            // Toolbar if available
                            if let toolbarView = selectedPanel.toolBarView {
                                HStack {
                                    toolbarView
                                        .padding(.horizontal)
                                }
                                .frame(height: 30)
                                .background(Color.init(id: "sideBar.background"))

                                Divider()
                            }

                            // Main content
                            selectedPanel.mainView
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        Text("No panel selected")
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: CGFloat(panelWidth))
                .background(Color.init(id: "sideBar.background"))
            }
        }
    }
}

// MARK: - Panel Tab Bar

private struct PanelTabBar: View {
    @EnvironmentObject var rightPanelManager: RightPanelManager

    var body: some View {
        HStack(spacing: 0) {
            ForEach(rightPanelManager.panels, id: \.id) { panel in
                PanelTab(panel: panel)
                    .environmentObject(rightPanelManager)
            }

            Spacer()

            // Close button
            Button(action: {
                withAnimation {
                    // Toggle visibility through SceneStorage binding would be ideal
                    // For now, we'll use a notification
                    NotificationCenter.default.post(
                        name: Notification.Name("rightPanel.toggle"),
                        object: nil
                    )
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(Color.init(id: "foreground"))
                    .padding(8)
            }
        }
        .background(Color.init(id: "sideBar.background"))
        .overlay(
            Rectangle()
                .fill(Color.init(id: "panel.border"))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Panel Tab

private struct PanelTab: View {
    let panel: RightPanel
    @EnvironmentObject var rightPanelManager: RightPanelManager

    var isSelected: Bool {
        rightPanelManager.selectedPanelId == panel.id
    }

    var body: some View {
        Button(action: {
            rightPanelManager.selectPanel(id: panel.id)
        }) {
            HStack(spacing: 6) {
                Image(systemName: panel.icon)
                    .font(.system(size: 14))

                Text(panel.label)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundColor(
                isSelected
                    ? Color.init(id: "tab.activeForeground")
                    : Color.init(id: "tab.inactiveForeground")
            )
            .background(
                isSelected
                    ? Color.init(id: "tab.activeBackground")
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Toggle Button (for Activity Bar)

struct RightPanelToggleButton: View {
    @Binding var isVisible: Bool

    var body: some View {
        Button(action: {
            withAnimation {
                isVisible.toggle()
            }
        }) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 20))
                .foregroundColor(
                    isVisible
                        ? Color.init(id: "activityBar.activeForeground")
                        : Color.init(id: "activityBar.inactiveForeground")
                )
                .frame(width: 50, height: 50)
        }
        .buttonStyle(.plain)
    }
}
