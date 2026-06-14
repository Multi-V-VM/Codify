//
//  ChatView.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI

struct ChatView: View {
    @EnvironmentObject var App: MainApp
    @StateObject private var llmService = CoreMLLLMService.shared
    @StateObject private var aneLLMService = ANELLMService.shared
    @StateObject private var agentService = AgentService.shared
    @State private var inputText: String = ""
    @State private var isEditMode: Bool = false
    @State private var showGGUFPicker: Bool = false
    @FocusState private var textFieldFocused: Bool

    var canRunEdit: Bool {
        !inputText.isEmpty && App.activeTextEditor != nil && !agentService.isProcessing
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // Chat messages (from whichever backend is active)
                        let activeMessages =
                            aneLLMService.modelLoaded
                            ? aneLLMService.messages
                            : llmService.messages
                        ForEach(activeMessages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if llmService.isGenerating || aneLLMService.isGenerating {
                            TypingIndicator()
                        }

                        // Agent sessions (vibe coding)
                        if !agentService.activeSessions.isEmpty {
                            AgentSessionsSection(
                                sessions: agentService.activeSessions,
                                onAccept: acceptChanges,
                                onReject: rejectWithFeedback
                            )
                        }
                    }
                    .padding()
                }
                .onChange(of: llmService.messages.count) { _ in
                    if let lastMessage = llmService.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: aneLLMService.messages.count) { _ in
                    if let lastMessage = aneLLMService.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            // ANE Model Loading Bar
            if aneLLMService.isLoading {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(aneLLMService.loadingStatus)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int(aneLLMService.loadingProgress * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    ProgressView(value: aneLLMService.loadingProgress)
                        .tint(.purple)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.purple.opacity(0.05))
            }

            // ANE streaming response indicator
            if aneLLMService.isGenerating && !aneLLMService.currentResponse.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.purple)
                    Text(aneLLMService.currentResponse)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color.init(id: "foreground"))
                        .lineLimit(10)
                    Spacer()
                }
                .padding(8)
                .background(Color.purple.opacity(0.05))
                .cornerRadius(6)
                .padding(.horizontal)
            }

            Divider()

            // Mode toggle + input area
            VStack(spacing: 8) {
                // Mode selector
                HStack(spacing: 0) {
                    ModeButton(label: "Chat", icon: "bubble.left", isActive: !isEditMode) {
                        isEditMode = false
                    }
                    ModeButton(label: "Edit Code", icon: "wand.and.stars", isActive: isEditMode) {
                        isEditMode = true
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // File context (in edit mode)
                if isEditMode {
                    FileContextBar(
                        fileName: App.activeTextEditor?.url.lastPathComponent,
                        language: App.activeTextEditor?.languageIdentifier
                    )
                    .padding(.horizontal)
                }

                // Input
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(
                        isEditMode ? "Describe code changes..." : "Ask me anything...",
                        text: $inputText, axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.init(id: "input.background"))
                    .cornerRadius(8)
                    .lineLimit(1...5)
                    .focused($textFieldFocused)
                    .disabled(
                        (llmService.isGenerating || aneLLMService.isGenerating) && !isEditMode)

                    Button(action: isEditMode ? startEditSession : sendMessage) {
                        Image(systemName: isEditMode ? "play.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(
                                (isEditMode ? canRunEdit : !inputText.isEmpty)
                                    ? Color.init(id: "button.background")
                                    : .gray
                            )
                    }
                    .disabled(
                        isEditMode
                            ? !canRunEdit
                            : (inputText.isEmpty || llmService.isGenerating
                                || aneLLMService.isGenerating))
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .background(Color.init(id: "editor.background"))
        .onReceive(
            NotificationCenter.default.publisher(for: VibeCodingNotification.editSelection)
        ) { notification in
            if let code = notification.userInfo?[VibeCodingNotification.selectedCodeKey] as? String
            {
                isEditMode = true
                inputText = "Edit this code:\n```\n\(code)\n```\n"
            }
        }
    }

    // MARK: - Chat Actions

    private func sendMessage() {
        let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        inputText = ""
        Task {
            // Local inference: load the bundled Qwen model on first use so the
            // chat never silently falls back to the simulated CoreML service.
            if !aneLLMService.modelLoaded {
                if aneLLMService.isLoading {
                    // Another message already kicked off loading — wait for it.
                    while aneLLMService.isLoading {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                } else {
                    try? await aneLLMService.loadBundledModel()
                }
            }
            if aneLLMService.modelLoaded {
                _ = await aneLLMService.sendMessage(message)
            } else {
                _ = await llmService.sendMessage(message)
            }
        }
    }

    // MARK: - Vibe Coding Actions

    private func startEditSession() {
        guard let editor = App.activeTextEditor else { return }
        let content = editor.content
        let filePath = editor.url.lastPathComponent

        let _ = agentService.startSession(
            instruction: inputText,
            filePath: filePath,
            fileContent: content
        )
        inputText = ""
    }

    private func acceptChanges(session: AgentSession) {
        guard let editor = App.activeTextEditor else { return }
        let editorURL = editor.url.absoluteString

        agentService.applyActions(session: session) { result in
            switch result {
            case .success(let newContent):
                Task {
                    await App.monacoInstance.setValueForModel(url: editorURL, value: newContent)
                }
            case .failure(let error):
                App.notificationManager.showErrorMessage(
                    "Failed to apply changes: \(error.localizedDescription)")
            }
        }
    }

    private func rejectWithFeedback(session: AgentSession, feedback: String) {
        guard let editor = App.activeTextEditor else { return }
        let _ = agentService.refineSession(
            originalSession: session,
            feedback: feedback,
            updatedFileContent: editor.content
        )
    }
}

// MARK: - Mode Button

private struct ModeButton: View {
    let label: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundColor(
                isActive
                    ? Color.init(id: "tab.activeForeground")
                    : Color.init(id: "tab.inactiveForeground")
            )
            .background(
                isActive ? Color.init(id: "tab.activeBackground") : Color.clear
            )
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - File Context Bar

private struct FileContextBar: View {
    let fileName: String?
    let language: String?

    var body: some View {
        HStack(spacing: 6) {
            if let fileName = fileName {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundColor(Color.init(id: "foreground"))
                Text(fileName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.init(id: "foreground"))
                if let language = language {
                    Text(language)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(3)
                }
            } else {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                Text("Open a file to edit")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(6)
        .background(Color.init(id: "list.hoverBackground").opacity(0.3))
        .cornerRadius(6)
    }
}

// MARK: - Agent Sessions Section

private struct AgentSessionsSection: View {
    let sessions: [AgentSession]
    let onAccept: (AgentSession) -> Void
    let onReject: (AgentSession, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                    .foregroundColor(.purple)
                Text("Code Edits")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.purple)
            }

            ForEach(sessions) { session in
                InlineCodingSessionView(
                    session: session,
                    onAccept: { onAccept(session) },
                    onReject: { feedback in onReject(session, feedback) }
                )
            }
        }
    }
}

// MARK: - Inline Coding Session View

private struct InlineCodingSessionView: View {
    @ObservedObject var session: AgentSession
    @State private var showDetails: Bool = true
    @State private var feedbackText: String = ""
    @State private var showFeedback: Bool = false

    let onAccept: () -> Void
    let onReject: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                SessionStatusIndicator(status: session.status)
                Spacer()
                Button(action: { showDetails.toggle() }) {
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Instruction
            Text(session.instruction)
                .font(.system(size: 12))
                .foregroundColor(Color.init(id: "foreground"))
                .lineLimit(showDetails ? nil : 2)

            if showDetails {
                // Thinking steps
                if !session.thinkingSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(session.thinkingSteps.enumerated()), id: \.offset) {
                            _, step in
                            Text(step)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color.init(id: "editor.lineHighlightBackground").opacity(0.4)
                                )
                                .cornerRadius(4)
                        }
                    }
                }

                // Proposed diffs
                if !session.actions.isEmpty {
                    ForEach(session.actions) { action in
                        InlineDiffView(action: action)
                    }
                }

                // Action buttons
                if session.status == .waitingForApproval {
                    if showFeedback {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What should be different?")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("Feedback...", text: $feedbackText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .padding(6)
                                .background(Color.init(id: "input.background"))
                                .cornerRadius(6)
                                .lineLimit(1...3)

                            HStack(spacing: 6) {
                                Button("Cancel") {
                                    showFeedback = false
                                    feedbackText = ""
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)

                                Spacer()

                                Button(action: {
                                    onReject(feedbackText)
                                    showFeedback = false
                                    feedbackText = ""
                                }) {
                                    Text("Refine")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(
                                            feedbackText.isEmpty
                                                ? Color.gray.opacity(0.3) : Color.orange
                                        )
                                        .foregroundColor(.white)
                                        .cornerRadius(4)
                                }
                                .disabled(feedbackText.isEmpty)
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Button(action: onAccept) {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark")
                                    Text("Accept")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(5)
                            }

                            Button(action: { showFeedback = true }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Revise")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(5)
                            }

                            Button(action: {
                                AgentService.shared.rejectActions(session: session)
                            }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "xmark")
                                    Text("Reject")
                                }
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(5)
                            }
                        }
                    }
                }

                // Error
                if let error = session.error {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                        Text(error)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.red)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
                }
            }
        }
        .padding(10)
        .background(Color.init(id: "list.hoverBackground").opacity(0.3))
        .cornerRadius(8)
    }
}

// MARK: - Session Status Indicator

private struct SessionStatusIndicator: View {
    let status: AgentSession.Status

    var body: some View {
        HStack(spacing: 4) {
            if status == .thinking || status == .proposingActions || status == .applying {
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                Circle()
                    .fill(colorForStatus)
                    .frame(width: 7, height: 7)
            }
            Text(labelForStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(colorForStatus)
        }
    }

    private var colorForStatus: Color {
        switch status {
        case .thinking, .proposingActions, .applying: return .orange
        case .waitingForApproval: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }

    private var labelForStatus: String {
        switch status {
        case .thinking: return "Thinking..."
        case .proposingActions: return "Planning..."
        case .waitingForApproval: return "Review"
        case .applying: return "Applying..."
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Inline Diff View

private struct InlineDiffView: View {
    let action: CodeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: iconForType)
                    .font(.system(size: 10))
                    .foregroundColor(colorForType)
                Text(action.type.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(colorForType)
                Text("L\(action.lineStart)-\(action.lineEnd)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer()
            }

            Text(action.description)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            if !action.oldContent.isEmpty {
                Text(
                    action.oldContent.components(separatedBy: .newlines).map { "- \($0)" }.joined(
                        separator: "\n")
                )
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.red)
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(3)
            }

            if !action.newContent.isEmpty {
                Text(
                    action.newContent.components(separatedBy: .newlines).map { "+ \($0)" }.joined(
                        separator: "\n")
                )
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.green)
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08))
                .cornerRadius(3)
            }
        }
        .padding(6)
        .background(Color.init(id: "editor.background"))
        .cornerRadius(5)
    }

    private var iconForType: String {
        switch action.type {
        case .replace: return "arrow.triangle.2.circlepath"
        case .insert: return "plus.circle"
        case .delete: return "trash"
        }
    }

    private var colorForType: Color {
        switch action.type {
        case .replace: return .blue
        case .insert: return .green
        case .delete: return .red
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: LLMMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.role == .user ? "person.circle.fill" : "cpu")
                .font(.system(size: 20))
                .foregroundColor(message.role == .user ? .blue : .green)

            VStack(alignment: .leading, spacing: 4) {
                Text(message.role.rawValue.capitalized)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.init(id: "foreground"))

                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundColor(Color.init(id: "foreground"))
                    .textSelection(.enabled)

                Text(formatTimestamp(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Spacer()
        }
        .padding(12)
        .background(
            message.role == .user
                ? Color.init(id: "list.hoverBackground").opacity(0.5)
                : Color.init(id: "editor.lineHighlightBackground").opacity(0.5)
        )
        .cornerRadius(8)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Typing Indicator

private struct TypingIndicator: View {
    @State private var dotCount = 0

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 20))
                .foregroundColor(.green)

            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 6, height: 6)
                        .opacity(index < dotCount ? 1.0 : 0.3)
                }
            }
            .onAppear {
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    dotCount = (dotCount + 1) % 4
                }
            }

            Spacer()
        }
        .padding(12)
        .background(Color.init(id: "editor.lineHighlightBackground").opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Chat Toolbar

@available(iOS 18.0, *)
struct ChatToolbarView: View {
    @EnvironmentObject var App: MainApp
    @StateObject private var llmService = CoreMLLLMService.shared
    @StateObject private var aneLLMService = ANELLMService.shared
    @StateObject private var agentService = AgentService.shared

    var body: some View {
        HStack(spacing: 12) {
            // Model status indicator
            HStack(spacing: 4) {
                if aneLLMService.modelLoaded {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.purple)
                    Text("ANE Model")
                        .font(.system(size: 10))
                        .foregroundColor(.purple)
                } else {
                    Circle()
                        .fill(llmService.modelLoaded ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(llmService.modelLoaded ? "CoreML Model" : "No Model")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            // Menu
            Menu {
                Section("ANE (GGUF)") {
                    Button(action: loadGGUFModel) {
                        Label("Load GGUF Model", systemImage: "bolt.circle")
                    }

                    if aneLLMService.modelLoaded {
                        Button(action: unloadANEModel) {
                            Label("Unload ANE Model", systemImage: "bolt.slash")
                        }
                    }
                }

                Section("CoreML") {
                    Button(action: loadModel) {
                        Label("Load CoreML Model", systemImage: "arrow.down.circle")
                    }
                }

                Divider()

                Button(action: exportConversation) {
                    Label("Export as Markdown", systemImage: "square.and.arrow.up")
                }

                Button(action: clearConversation) {
                    Label("Clear Conversation", systemImage: "trash")
                }

                if !agentService.activeSessions.isEmpty {
                    Button(action: clearSessions) {
                        Label("Clear Edit Sessions", systemImage: "xmark.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func exportConversation() {
        let markdown =
            aneLLMService.modelLoaded
            ? aneLLMService.exportConversation()
            : llmService.exportConversation()
        UIPasteboard.general.string = markdown
        App.notificationManager.showInformationMessage("Conversation exported to clipboard")
    }

    private func clearConversation() {
        llmService.clearConversation()
        aneLLMService.clearConversation()
        App.notificationManager.showInformationMessage("Conversation cleared")
    }

    private func clearSessions() {
        agentService.clearAllSessions()
        App.notificationManager.showInformationMessage("Edit sessions cleared")
    }

    private func loadModel() {
        Task {
            do {
                try await llmService.loadModel(named: "default")
                await MainActor.run {
                    App.notificationManager.showInformationMessage("Model loaded successfully")
                }
            } catch {
                await MainActor.run {
                    App.notificationManager.showErrorMessage(
                        "Failed to load model: \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadGGUFModel() {
        Task {
            do {
                try await aneLLMService.loadBundledModel()
                await MainActor.run {
                    App.notificationManager.showInformationMessage("ANE model loaded: Qwen3.5-0.8B")
                }
            } catch {
                await MainActor.run {
                    App.notificationManager.showErrorMessage(
                        "Failed to load GGUF: \(error.localizedDescription)")
                }
            }
        }
    }

    private func unloadANEModel() {
        aneLLMService.unloadModel()
        App.notificationManager.showInformationMessage("ANE model unloaded")
    }
}

// MARK: - Preview

struct ChatView_Previews: PreviewProvider {
    static var previews: some View {
        ChatView()
            .frame(width: 300)
    }
}
