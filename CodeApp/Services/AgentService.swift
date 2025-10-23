//
//  AgentService.swift
//  Code
//
//  Created by Claude on 23/10/2025.
//

import Foundation
import Combine

/// Represents a code modification action
struct CodeAction: Identifiable, Equatable {
    let id = UUID()
    let type: ActionType
    let description: String
    let filePath: String
    let lineStart: Int
    let lineEnd: Int
    let oldContent: String
    let newContent: String

    enum ActionType: String {
        case replace = "Replace"
        case insert = "Insert"
        case delete = "Delete"
    }
}

/// Agent session for code modifications
class AgentSession: ObservableObject, Identifiable {
    let id = UUID()
    let instruction: String
    let filePath: String
    let fileContent: String

    @Published var status: Status = .thinking
    @Published var actions: [CodeAction] = []
    @Published var currentActionIndex: Int = 0
    @Published var error: String?
    @Published var thinkingSteps: [String] = []

    enum Status {
        case thinking
        case proposingActions
        case waitingForApproval
        case applying
        case completed
        case failed
    }

    init(instruction: String, filePath: String, fileContent: String) {
        self.instruction = instruction
        self.filePath = filePath
        self.fileContent = fileContent
    }
}

/// Service for agent-based code modifications
class AgentService: ObservableObject {
    static let shared = AgentService()

    @Published var activeSessions: [AgentSession] = []
    @Published var isProcessing: Bool = false

    private var llmService: CoreMLLLMService
    private var currentTask: Task<Void, Never>?

    private init() {
        self.llmService = CoreMLLLMService.shared
    }

    // MARK: - Session Management

    /// Start a new agent session
    func startSession(
        instruction: String,
        filePath: String,
        fileContent: String
    ) -> AgentSession {
        let session = AgentSession(
            instruction: instruction,
            filePath: filePath,
            fileContent: fileContent
        )

        activeSessions.append(session)

        // Start processing the instruction
        Task {
            await processSession(session)
        }

        return session
    }

    /// Cancel an active session
    func cancelSession(_ session: AgentSession) {
        if let index = activeSessions.firstIndex(where: { $0.id == session.id }) {
            activeSessions.remove(at: index)
        }
        currentTask?.cancel()
    }

    // MARK: - Agent Processing

    private func processSession(_ session: AgentSession) async {
        await MainActor.run {
            isProcessing = true
            session.status = .thinking
        }

        // Step 1: Analyze the instruction and plan actions
        await analyzeAndPlan(session: session)

        // Step 2: Generate specific code actions
        if session.status != .failed {
            await generateActions(session: session)
        }

        // Step 3: Wait for user approval
        if session.status != .failed {
            await MainActor.run {
                session.status = .waitingForApproval
                isProcessing = false
            }
        }
    }

    /// Analyze instruction and create a plan
    private func analyzeAndPlan(session: AgentSession) async {
        let prompt = """
        You are a code modification agent. Analyze the following instruction and create a step-by-step plan.

        File: \(session.filePath)
        Current content:
        ```
        \(session.fileContent)
        ```

        Instruction: \(session.instruction)

        Provide a numbered list of specific steps you would take to implement this change. Be concrete and specific.
        """

        let plan = await llmService.sendMessage(prompt)

        // Parse thinking steps from the plan
        let steps = plan.components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("1") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("2") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("3") }

        await MainActor.run {
            session.thinkingSteps = steps.isEmpty ? [plan] : steps
        }
    }

    /// Generate specific code actions
    private func generateActions(session: AgentSession) async {
        await MainActor.run {
            session.status = .proposingActions
        }

        let prompt = """
        You are a code modification agent. Generate the exact code changes needed.

        File: \(session.filePath)
        Current content:
        ```
        \(session.fileContent)
        ```

        Instruction: \(session.instruction)

        Provide the changes in this EXACT format:

        ACTION: <REPLACE|INSERT|DELETE>
        LINES: <start_line>-<end_line>
        DESCRIPTION: <what this change does>
        OLD:
        ```
        <exact old content>
        ```
        NEW:
        ```
        <exact new content>
        ```

        You can specify multiple actions. Be precise with line numbers (1-indexed).
        """

        let response = await llmService.sendMessage(prompt)

        // Parse actions from response
        let actions = parseActions(from: response, fileContent: session.fileContent)

        await MainActor.run {
            if actions.isEmpty {
                session.status = .failed
                session.error = "Could not generate valid code actions"
            } else {
                session.actions = actions
                session.status = .waitingForApproval
            }
        }
    }

    /// Parse code actions from LLM response
    private func parseActions(from response: String, fileContent: String) -> [CodeAction] {
        var actions: [CodeAction] = []
        let lines = fileContent.components(separatedBy: .newlines)

        // Simple parsing - in production, you'd want more robust parsing
        let actionBlocks = response.components(separatedBy: "ACTION:")
            .dropFirst()  // Skip text before first ACTION

        for block in actionBlocks {
            let blockLines = block.components(separatedBy: .newlines)

            guard let actionType = blockLines.first?.trimmingCharacters(in: .whitespaces),
                  let type = CodeAction.ActionType(rawValue: actionType.uppercased()) else {
                continue
            }

            // Extract description
            let descriptionLine = blockLines.first { $0.contains("DESCRIPTION:") }
            let description = descriptionLine?
                .replacingOccurrences(of: "DESCRIPTION:", with: "")
                .trimmingCharacters(in: .whitespaces) ?? "Code modification"

            // Extract line range
            let linesLine = blockLines.first { $0.contains("LINES:") }
            var lineStart = 1
            var lineEnd = 1

            if let linesContent = linesLine?.replacingOccurrences(of: "LINES:", with: "").trimmingCharacters(in: .whitespaces) {
                let rangeParts = linesContent.components(separatedBy: "-")
                if rangeParts.count == 2,
                   let start = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                   let end = Int(rangeParts[1].trimmingCharacters(in: .whitespaces)) {
                    lineStart = start
                    lineEnd = end
                }
            }

            // Extract old and new content
            let oldContent = extractCodeBlock(from: block, marker: "OLD:")
            let newContent = extractCodeBlock(from: block, marker: "NEW:")

            // Get actual old content from file
            let actualOldContent = lines.indices.contains(lineStart - 1) && lines.indices.contains(lineEnd - 1)
                ? lines[(lineStart - 1)...(lineEnd - 1)].joined(separator: "\n")
                : oldContent

            let action = CodeAction(
                type: type,
                description: description,
                filePath: "",
                lineStart: lineStart,
                lineEnd: lineEnd,
                oldContent: actualOldContent,
                newContent: newContent
            )

            actions.append(action)
        }

        return actions
    }

    private func extractCodeBlock(from text: String, marker: String) -> String {
        guard let markerRange = text.range(of: marker) else {
            return ""
        }

        let afterMarker = String(text[markerRange.upperBound...])

        // Find the code block
        if let startBlock = afterMarker.range(of: "```"),
           let endBlock = afterMarker[startBlock.upperBound...].range(of: "```") {
            let code = afterMarker[startBlock.upperBound..<endBlock.lowerBound]
            // Remove the language identifier if present
            let lines = code.components(separatedBy: .newlines).dropFirst()
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ""
    }

    // MARK: - Action Application

    /// Apply approved actions to the file
    func applyActions(session: AgentSession, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            await MainActor.run {
                session.status = .applying
                isProcessing = true
            }

            let result = applyActionsToContent(
                actions: session.actions,
                originalContent: session.fileContent
            )

            await MainActor.run {
                isProcessing = false

                switch result {
                case .success(let newContent):
                    session.status = .completed
                    completion(.success(newContent))

                case .failure(let error):
                    session.status = .failed
                    session.error = error.localizedDescription
                    completion(.failure(error))
                }
            }
        }
    }

    private func applyActionsToContent(
        actions: [CodeAction],
        originalContent: String
    ) -> Result<String, Error> {
        var lines = originalContent.components(separatedBy: .newlines)

        // Apply actions in reverse order (bottom to top) to preserve line numbers
        let sortedActions = actions.sorted { $0.lineStart > $1.lineStart }

        for action in sortedActions {
            let startIndex = max(0, action.lineStart - 1)
            let endIndex = min(lines.count - 1, action.lineEnd - 1)

            guard startIndex <= endIndex, startIndex < lines.count else {
                return .failure(NSError(
                    domain: "AgentService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid line range: \(action.lineStart)-\(action.lineEnd)"]
                ))
            }

            switch action.type {
            case .replace:
                let newLines = action.newContent.components(separatedBy: .newlines)
                lines.replaceSubrange(startIndex...endIndex, with: newLines)

            case .insert:
                let newLines = action.newContent.components(separatedBy: .newlines)
                lines.insert(contentsOf: newLines, at: startIndex)

            case .delete:
                lines.removeSubrange(startIndex...endIndex)
            }
        }

        return .success(lines.joined(separator: "\n"))
    }

    /// Reject and discard actions
    func rejectActions(session: AgentSession) {
        Task { @MainActor in
            session.status = .failed
            cancelSession(session)
        }
    }
}
