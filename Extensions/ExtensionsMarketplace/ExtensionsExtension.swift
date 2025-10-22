//
//  ExtensionsExtension.swift
//  Code
//
//  Extension that provides the Extensions marketplace/manager UI
//

import SwiftUI

class ExtensionsExtension: CodeAppExtension {

    override func onInitialize(
        app: MainApp,
        contribution: CodeAppExtension.Contribution
    ) {
        // Register Extensions tab in Activity Bar
        let extensionsItem = ActivityBarItem(
            itemID: "EXTENSIONS",
            iconSystemName: "puzzlepiece.extension.fill",
            title: "Extensions",
            shortcutKey: KeyEquivalent("x"),
            modifiers: [.command, .shift],
            view: AnyView(
                ExtensionsContainer()
                    .environmentObject(app)
                    .environmentObject(app.extensionManager)
            ),
            contextMenuItems: {
                [
                    ContextMenuItem(
                        action: {
                            // TODO: Open marketplace browser
                            NSLog("Browse Extensions clicked")
                        },
                        text: "Browse Marketplace",
                        imageSystemName: "safari"
                    ),
                    ContextMenuItem(
                        action: {
                            // TODO: Refresh installed extensions
                            NSLog("Refresh Extensions clicked")
                        },
                        text: "Refresh Extensions",
                        imageSystemName: "arrow.clockwise"
                    ),
                    ContextMenuItem(
                        action: {
                            // TODO: Open settings
                            NSLog("Extension Settings clicked")
                        },
                        text: "Extension Settings",
                        imageSystemName: "gear"
                    )
                ]
            },
            positionPrecedence: 400, // After SOURCE_CONTROL (500) and before REMOTE (300)
            bubble: {
                // TODO: Show update count when extensions have updates available
                return nil
            },
            isVisible: { true }
        )

        contribution.activityBar.registerItem(item: extensionsItem)

        // Optional: Register a panel for extension output/logs
        let extensionLogsPanel = Panel(
            labelId: "EXTENSION_OUTPUT",
            mainView: AnyView(
                ExtensionOutputView()
                    .environmentObject(app)
            ),
            toolBarView: AnyView(
                ExtensionOutputToolbar()
                    .environmentObject(app)
            )
        )
        contribution.panel.registerPanel(panel: extensionLogsPanel)
    }
}

/// Toolbar for the Extension Output panel
private struct ExtensionOutputToolbar: View {
    @EnvironmentObject var App: MainApp

    var body: some View {
        HStack(spacing: 12) {
            Button(action: {
                // TODO: Clear output
                NSLog("Clear extension output")
            }) {
                Image(systemName: "trash")
            }
            .keyboardShortcut("k", modifiers: [.command])

            Spacer()

            Menu {
                Button("All Extensions") { /* TODO */ }
                Divider()
                // TODO: Add menu items for each extension
            } label: {
                HStack {
                    Text("Filter")
                    Image(systemName: "chevron.down")
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

/// View for extension output/logs panel
private struct ExtensionOutputView: View {
    @EnvironmentObject var App: MainApp

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Extension Output")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)

                // TODO: Display actual extension logs
                Text("No output available")
                    .foregroundColor(.secondary)
                    .padding(8)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
