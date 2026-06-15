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
    var onEditWithAI: ((String) -> Void)?

    init(editorImplementation: any EditorImplementation) {
        self.editorImplementation = editorImplementation
    }

    func buildContextMenu(hasSelection: Bool) -> UIMenu {
        var menuItems: [UIMenuElement] = []

        let commandSection = buildCommandSection()
        menuItems.append(commandSection)

        // AI Features Section (if has selection)
        if hasSelection {
            let aiSection = buildAISection()
            menuItems.append(aiSection)
        }

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

        let editWithAIAction = UIAction(
            title: NSLocalizedString("Edit with AI", comment: ""),
            image: UIImage(systemName: "wand.and.stars")
        ) { [weak self] _ in
            guard let self = self else { return }
            Task {
                let selection = await self.editorImplementation?.getSelectedValue() ?? ""
                self.onEditWithAI?(selection)
            }
        }

        return UIMenu(
            title: "",
            options: .displayInline,
            children: [editWithAIAction, addToChatAction, explainAction, generateAction]
        )
    }

    private func buildCommandSection() -> UIMenu {
        let commandPaletteAction = UIAction(
            title: NSLocalizedString("Command Palette...", comment: ""),
            image: UIImage(systemName: "command")
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?._toggleCommandPalatte()
            }
        }

        let goToLineAction = UIAction(
            title: NSLocalizedString("Go to Line...", comment: ""),
            image: UIImage(systemName: "number")
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?._toggleGoToLineWidget()
            }
        }

        let formatDocumentAction = UIAction(
            title: NSLocalizedString("Format Document", comment: ""),
            image: UIImage(systemName: "doc.text")
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?.formatDocument()
            }
        }

        return UIMenu(
            title: "",
            options: .displayInline,
            children: [commandPaletteAction, goToLineAction, formatDocumentAction]
        )
    }

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

        return UIMenu(
            title: "",
            options: .displayInline,
            children: actions
        )
    }
}
