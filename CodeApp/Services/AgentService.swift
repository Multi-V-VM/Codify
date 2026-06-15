//
//  AgentService.swift
//  Code
//
//  Created by Claude on 23/10/2025.
//

import Combine
import Foundation

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
    private var aneLLMService: ANELLMService
    private var currentTask: Task<Void, Never>?
    private let codeFence = "```"

    /// Returns whichever LLM backend currently has a model loaded (ANE preferred)
    var activeLLMService: CoreMLLLMService {
        // ANE is used via sendMessageViaActiveLLM; CoreML is the fallback
        return llmService
    }

    /// Whether ANE backend is available and loaded
    var isANEActive: Bool {
        return aneLLMService.modelLoaded
    }

    private init() {
        self.llmService = CoreMLLLMService.shared
        self.aneLLMService = ANELLMService.shared
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

        guard await ensureLocalModelLoaded(session: session) else {
            await MainActor.run {
                isProcessing = false
            }
            return
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

    /// Ensure edit mode has a real local model before asking for code changes.
    private func ensureLocalModelLoaded(session: AgentSession) async -> Bool {
        if aneLLMService.modelLoaded || llmService.modelLoaded {
            return true
        }

        if aneLLMService.isLoading {
            while aneLLMService.isLoading {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        } else {
            do {
                try await aneLLMService.loadBundledModel()
            } catch {
                await MainActor.run {
                    session.status = .failed
                    session.error = "Failed to load local ANE model: \(error.localizedDescription)"
                }
                return false
            }
        }

        if aneLLMService.modelLoaded || llmService.modelLoaded {
            return true
        }

        await MainActor.run {
            session.status = .failed
            session.error = "No local AI model is loaded for Edit Code"
        }
        return false
    }

    /// Send a message via whichever LLM backend is active (ANE preferred)
    private func sendMessageViaActiveLLM(_ prompt: String) async -> String {
        if aneLLMService.modelLoaded {
            return await aneLLMService.sendMessage(prompt)
        }
        return await llmService.sendMessage(prompt)
    }

    /// Create local planning steps without consuming model context.
    private func analyzeAndPlan(session: AgentSession) async {
        await MainActor.run {
            session.thinkingSteps = [
                "1. Read \(session.filePath) and identify the requested edit",
                "2. Ask the local ANE model for one complete updated file",
                "3. Convert the model output into a reviewable replacement action",
            ]
        }
    }

    /// Generate specific code actions
    private func generateActions(session: AgentSession) async {
        await MainActor.run {
            session.status = .proposingActions
        }

        let prompt = """
            You are a code editing engine. Apply the user's requested change to the file.

            File: \(session.filePath)
            Current content:
            \(codeFence)
            \(session.fileContent)
            \(codeFence)

            Instruction: \(session.instruction)

            Return only the complete updated file in one fenced code block. Do not include explanations, markdown outside the code block, diffs, or line numbers.
            """

        let response = await sendMessageViaActiveLLM(prompt)

        // Prefer a full-file replacement because small local models are much more reliable
        // with one concrete output contract than with line-number patch formats.
        let actions = parseActions(
            from: response,
            filePath: session.filePath,
            fileContent: session.fileContent
        )

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
    private func parseActions(from response: String, filePath: String, fileContent: String)
        -> [CodeAction]
    {
        let originalLineCount = max(1, fileContent.components(separatedBy: .newlines).count)

        if let updatedFile = extractFirstFencedCodeBlock(from: response), !updatedFile.isEmpty,
            updatedFile != fileContent
        {
            return [
                CodeAction(
                    type: .replace,
                    description: "Apply requested edit",
                    filePath: filePath,
                    lineStart: 1,
                    lineEnd: originalLineCount,
                    oldContent: fileContent,
                    newContent: updatedFile
                )
            ]
        }

        return parseLegacyActions(from: response, filePath: filePath, fileContent: fileContent)
    }

    private func parseLegacyActions(from response: String, filePath: String, fileContent: String)
        -> [CodeAction]
    {
        var actions: [CodeAction] = []
        let lines = fileContent.components(separatedBy: .newlines)

        let actionBlocks = response.components(separatedBy: "ACTION:").dropFirst()
        for block in actionBlocks {
            let blockLines = block.components(separatedBy: .newlines)

            guard
                let actionType = blockLines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                let type = actionTypeFromLLMLabel(actionType)
            else {
                continue
            }

            let descriptionLine = blockLines.first { $0.contains("DESCRIPTION:") }
            let description =
                descriptionLine?
                .replacingOccurrences(of: "DESCRIPTION:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Code modification"

            let linesLine = blockLines.first { $0.contains("LINES:") }
            var lineStart = 1
            var lineEnd = 1

            if let linesContent = linesLine?.replacingOccurrences(of: "LINES:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            {
                let rangeParts = linesContent.components(separatedBy: "-")
                if rangeParts.count == 2,
                    let start = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                    let end = Int(rangeParts[1].trimmingCharacters(in: .whitespaces))
                {
                    lineStart = max(1, start)
                    lineEnd = max(lineStart, end)
                }
            }

            let oldContent = extractCodeBlock(from: block, marker: "OLD:")
            let newContent = extractCodeBlock(from: block, marker: "NEW:")

            let actualOldContent =
                lines.indices.contains(lineStart - 1) && lines.indices.contains(lineEnd - 1)
                ? lines[(lineStart - 1)...(lineEnd - 1)].joined(separator: "\n")
                : oldContent

            actions.append(
                CodeAction(
                    type: type,
                    description: description,
                    filePath: filePath,
                    lineStart: lineStart,
                    lineEnd: lineEnd,
                    oldContent: actualOldContent,
                    newContent: newContent
                )
            )
        }

        return actions
    }

    private func actionTypeFromLLMLabel(_ label: String) -> CodeAction.ActionType? {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "replace": return .replace
        case "insert": return .insert
        case "delete": return .delete
        default: return nil
        }
    }

    private func extractFirstFencedCodeBlock(from text: String) -> String? {
        guard let startBlock = text.range(of: codeFence),
            let endBlock = text[startBlock.upperBound...].range(of: codeFence)
        else {
            return nil
        }

        let code = String(text[startBlock.upperBound..<endBlock.lowerBound])
        return stripOptionalFenceLanguage(from: code)
    }

    private func extractCodeBlock(from text: String, marker: String) -> String {
        guard let markerRange = text.range(of: marker) else {
            return ""
        }

        let afterMarker = String(text[markerRange.upperBound...])
        guard let startBlock = afterMarker.range(of: codeFence),
            let endBlock = afterMarker[startBlock.upperBound...].range(of: codeFence)
        else {
            return ""
        }

        let code = String(afterMarker[startBlock.upperBound..<endBlock.lowerBound])
        return stripOptionalFenceLanguage(from: code)
    }

    private func stripOptionalFenceLanguage(from code: String) -> String {
        var lines = code.components(separatedBy: .newlines)
        if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
            !first.isEmpty,
            first.range(of: "^[A-Za-z0-9_+#.-]+$", options: .regularExpression) != nil
        {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Action Application

    /// Apply approved actions to the file
    func applyActions(session: AgentSession, completion: @escaping (Result<String, Error>) -> Void)
    {
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
                return .failure(
                    NSError(
                        domain: "AgentService",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Invalid line range: \(action.lineStart)-\(action.lineEnd)"
                        ]
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

    /// Create a new session with combined instruction for iterative refinement
    func refineSession(
        originalSession: AgentSession,
        feedback: String,
        updatedFileContent: String
    ) -> AgentSession {
        // Mark the original as failed/done
        Task { @MainActor in
            originalSession.status = .failed
        }

        let refinedInstruction = """
            Original instruction: \(originalSession.instruction)

            The previous changes were rejected with this feedback: \(feedback)

            Please try again with the feedback in mind.
            """

        return startSession(
            instruction: refinedInstruction,
            filePath: originalSession.filePath,
            fileContent: updatedFileContent
        )
    }

    /// Remove all sessions and cancel current processing
    func clearAllSessions() {
        currentTask?.cancel()
        Task { @MainActor in
            activeSessions.removeAll()
            isProcessing = false
        }
    }
}
