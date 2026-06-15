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

        let editingSection = buildEditingSection(hasSelection: hasSelection)
        menuItems.append(editingSection)

        let commandSection = buildCommandSection()
        menuItems.append(commandSection)

        let aiSection = buildAISection(hasSelection: hasSelection)
        menuItems.append(aiSection)

        let codeActionsSection = buildCodeActionsSection(hasSelection: hasSelection)
        menuItems.append(codeActionsSection)

        // Refactoring Section
        let refactoringSection = buildRefactoringSection(hasSelection: hasSelection)
        menuItems.append(refactoringSection)

        return UIMenu(children: menuItems)
    }

    private func buildAISection(hasSelection: Bool) -> UIMenu {
        let selectionAttributes: UIMenuElement.Attributes = hasSelection ? [] : .disabled

        let explainAction = UIAction(
            title: NSLocalizedString("Explain", comment: ""),
            image: UIImage(systemName: "lightbulb"),
            attributes: selectionAttributes
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
            image: UIImage(systemName: "bubble.left.and.text.bubble.right"),
            attributes: selectionAttributes
        ) { [weak self] _ in
            guard let self = self else { return }
            Task {
                let selection = await self.editorImplementation?.getSelectedValue() ?? ""
                self.onAddToChat?(selection)
            }
        }

        let editWithAIAction = UIAction(
            title: NSLocalizedString("Edit with AI", comment: ""),
            image: UIImage(systemName: "wand.and.stars"),
            attributes: selectionAttributes
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

    private func buildEditingSection(hasSelection: Bool) -> UIMenu {
        var actions: [UIAction] = []
        let selectionAttributes: UIMenuElement.Attributes = hasSelection ? [] : .disabled
        let pasteAttributes: UIMenuElement.Attributes =
            UIPasteboard.general.hasStrings ? [] : .disabled

        let cutAction = UIAction(
            title: NSLocalizedString("Cut", comment: ""),
            image: UIImage(systemName: "scissors"),
            attributes: selectionAttributes
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

        let pasteAction = UIAction(
            title: NSLocalizedString("Paste", comment: ""),
            image: UIImage(systemName: "doc.on.clipboard"),
            attributes: pasteAttributes
        ) { [weak self] _ in
            guard let text = UIPasteboard.general.string else { return }
            Task {
                await self?.editorImplementation?.pasteText(text: text)
            }
        }
        actions.append(pasteAction)

        var deleteAttributes: UIMenuElement.Attributes = .destructive
        if !hasSelection {
            deleteAttributes.insert(.disabled)
        }
        let deleteAction = UIAction(
            title: NSLocalizedString("Delete", comment: ""),
            image: UIImage(systemName: "trash"),
            attributes: deleteAttributes
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?.deleteSelection()
            }
        }
        actions.append(deleteAction)

        return UIMenu(
            title: "",
            options: .displayInline,
            children: actions
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

        let findAction = UIAction(
            title: NSLocalizedString("Find...", comment: ""),
            image: UIImage(systemName: "doc.text.magnifyingglass")
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?.openSearchWidget()
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
            children: [commandPaletteAction, findAction, goToLineAction, formatDocumentAction]
        )
    }

    private func buildCodeActionsSection(hasSelection: Bool) -> UIMenu {
        let selectionAttributes: UIMenuElement.Attributes = hasSelection ? [] : .disabled

        let formatSelectionAction = UIAction(
            title: NSLocalizedString("Format Selection", comment: ""),
            image: UIImage(systemName: "text.alignleft"),
            attributes: selectionAttributes
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
        let selectionAttributes: UIMenuElement.Attributes = hasSelection ? [] : .disabled

        let changeAllAction = UIAction(
            title: NSLocalizedString("Change All Occurrences", comment: ""),
            image: UIImage(systemName: "arrow.triangle.2.circlepath"),
            attributes: selectionAttributes
        ) { [weak self] _ in
            Task {
                await self?.editorImplementation?.findAllOccurrences()
            }
        }
        actions.append(changeAllAction)

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
