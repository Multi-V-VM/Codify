//
//  EditorContextMenu.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI
import UIKit

class EditorContextMenu {
    weak var editorImplementation: (any EditorImplementation)?
    var onExplainCode: ((String) -> Void)?
    var onGenerateCode: (() -> Void)?
    var onAddToChat: ((String) -> Void)?

    init(editorImplementation: any EditorImplementation) {
        self.editorImplementation = editorImplementation
    }

    @MainActor
    func buildContextMenu(hasSelection: Bool) -> UIMenu {
        var menuItems: [UIMenuElement] = []

        // AI Features Section (if has selection)
        if hasSelection {
            let aiSection = buildAISection()
            menuItems.append(aiSection)
        }

        // Basic Editing Section
        let editingSection = buildEditingSection(hasSelection: hasSelection)
        menuItems.append(editingSection)

        // Code Actions Section
        if hasSelection {
            let codeActionsSection = buildCodeActionsSection()
            menuItems.append(codeActionsSection)
        }

        // Refactoring Section
        let refactoringSection = buildRefactoringSection(hasSelection: hasSelection)
        menuItems.append(refactoringSection)

        return UIMenu(children: menuItems)
    }

    @MainActor
    private func buildAISection() -> UIMenu {
        let explainAction = UIAction(
            title: NSLocalizedString("Explain", comment: ""),
            image: UIImage(systemName: "lightbulb")
        ) { [weak self] _ in
            guard let self = self else { return }
            Task {
                let selection = await self.editorImplementation?.getSelectedValue() ?? ""
                self.onExplainCode?(selection)
            }
        }

        let generateAction = UIAction(
            title: NSLocalizedString("Generate Code", comment: ""),
            image: UIImage(systemName: "wand.and.stars")
        ) { [weak self] _ in
            self?.onGenerateCode?()
        }

        let addToChatAction = UIAction(
            title: NSLocalizedString("Add Selection to Chat", comment: ""),
            image: UIImage(systemName: "bubble.left.and.text.bubble.right")
        ) { [weak self] _ in
            guard let self = self else { return }
            Task {
                let selection = await self.editorImplementation?.getSelectedValue() ?? ""
                self.onAddToChat?(selection)
            }
        }

        return UIMenu(
            title: "",
            options: .displayInline,
            children: [addToChatAction, explainAction, generateAction]
        )
    }

    @MainActor
    private func buildEditingSection(hasSelection: Bool) -> UIMenu {
        var actions: [UIAction] = []

        if hasSelection {
            let cutAction = UIAction(
                title: NSLocalizedString("Cut", comment: ""),
                image: UIImage(systemName: "scissors")
            ) { [weak self] _ in
                Task {
                    await self?.editorImplementation?.cutSelection()
                }
            }
            actions.append(cutAction)

            let copyAction = UIAction(
                title: NSLocalizedString("Copy", comment: ""),
                image: UIImage(systemName: "doc.on.doc")
            ) { [weak self] _ in
                Task {
                    if let text = await self?.editorImplementation?.copySelection() {
                        UIPasteboard.general.string = text
                    }
                }
            }
            actions.append(copyAction)
        }

        let pasteAction = UIAction(
            title: NSLocalizedString("Paste", comment: ""),
            image: UIImage(systemName: "doc.on.clipboard")
        ) { [weak self] _ in
            if let text = UIPasteboard.general.string {
                Task {
                    await self?.editorImplementation?.pasteText(text: text)
                }
            }
        }
        actions.append(pasteAction)

        if hasSelection {
            let deleteAction = UIAction(
                title: NSLocalizedString("Delete", comment: ""),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                Task {
                    await self?.editorImplementation?.deleteSelection()
                }
            }
            actions.append(deleteAction)
        }

        return UIMenu(
            title: "",
            options: .displayInline,
            children: actions
        )
    }

    @MainActor
    private func buildCodeActionsSection() -> UIMenu {
        let formatSelectionAction = UIAction(
            title: NSLocalizedString("Format Selection", comment: ""),
            image: UIImage(systemName: "text.alignleft")
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?.formatSelection()
            }
        }

        return UIMenu(
            title: "",
            options: .displayInline,
            children: [formatSelectionAction]
        )
    }

    @MainActor
    private func buildRefactoringSection(hasSelection: Bool) -> UIMenu {
        var actions: [UIAction] = []

        if hasSelection {
            let changeAllAction = UIAction(
                title: NSLocalizedString("Change All Occurrences", comment: ""),
                image: UIImage(systemName: "arrow.triangle.2.circlepath")
            ) { [weak self] _ in
                Task {
                    await self?.editorImplementation?.findAllOccurrences()
                }
            }
            actions.append(changeAllAction)
        }

        let renameAction = UIAction(
            title: NSLocalizedString("Rename Symbol", comment: ""),
            image: UIImage(systemName: "character.cursor.ibeam")
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?.renameSymbol()
            }
        }
        actions.append(renameAction)

        let formatDocumentAction = UIAction(
            title: NSLocalizedString("Format Document", comment: ""),
            image: UIImage(systemName: "doc.text")
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?.formatDocument()
            }
        }
        actions.append(formatDocumentAction)

        let commandPaletteAction = UIAction(
            title: NSLocalizedString("Command Palette...", comment: ""),
            image: UIImage(systemName: "command")
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?._toggleCommandPalatte()
            }
        }
        actions.append(commandPaletteAction)

        return UIMenu(
            title: "",
            options: .displayInline,
            children: actions
        )
    }
}
