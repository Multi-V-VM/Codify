//
//  ChatView.swift
//  Code
//
//  Created by Claude on 21/10/2025.
//

import SwiftUI

struct ChatView: View {
    @StateObject private var llmService = CoreMLLLMService.shared
    @State private var inputText: String = ""
    @State private var isInputFocused: Bool = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(llmService.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if llmService.isGenerating {
                            TypingIndicator()
                        }
                    }
                    .padding()
                }
                .onChange(of: llmService.messages.count) { _ in
                    // Scroll to bottom when new message arrives
                    if let lastMessage = llmService.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask me anything...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.init(id: "input.background"))
                    .cornerRadius(8)
                    .lineLimit(1...5)
                    .focused($textFieldFocused)
                    .disabled(llmService.isGenerating)

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(inputText.isEmpty ? .gray : Color.init(id: "button.background"))
                }
                .disabled(inputText.isEmpty || llmService.isGenerating)
            }
            .padding()
        }
        .background(Color.init(id: "editor.background"))
    }

    private func sendMessage() {
        let message = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        inputText = ""

        Task {
            _ = await llmService.sendMessage(message)
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: LLMMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Role icon
            Image(systemName: message.role == .user ? "person.circle.fill" : "cpu")
                .font(.system(size: 20))
                .foregroundColor(message.role == .user ? .blue : .green)

            VStack(alignment: .leading, spacing: 4) {
                // Role label
                Text(message.role.rawValue.capitalized)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(Color.init(id: "foreground"))

                // Message content
                Text(message.content)
                    .font(.system(size: 14))
                    .foregroundColor(Color.init(id: "foreground"))
                    .textSelection(.enabled)

                // Timestamp
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

    var body: some View {
        HStack(spacing: 12) {
            // Model status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(llmService.modelLoaded ? Color.green : Color.red)
                    .frame(width: 6, height: 6)

                Text(llmService.modelLoaded ? "Model Loaded" : "No Model")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }

            Spacer()

            // Export button
            Menu {
                Button(action: exportConversation) {
                    Label("Export as Markdown", systemImage: "square.and.arrow.up")
                }

                Button(action: clearConversation) {
                    Label("Clear Conversation", systemImage: "trash")
                }

                Divider()

                Button(action: loadModel) {
                    Label("Load Model", systemImage: "arrow.down.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func exportConversation() {
        let markdown = llmService.exportConversation()
        UIPasteboard.general.string = markdown

        // Show notification
        App.notificationManager.showInformationMessage("Conversation exported to clipboard")
    }

    private func clearConversation() {
        llmService.clearConversation()
        App.notificationManager.showInformationMessage("Conversation cleared")
    }

    private func loadModel() {
        Task {
            do {
                // Try to load a default model
                try await llmService.loadModel(named: "default")
                await MainActor.run {
                    App.notificationManager.showInformationMessage("Model loaded successfully")
                }
            } catch {
                await MainActor.run {
                    App.notificationManager.showErrorMessage("Failed to load model: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Preview

struct ChatView_Previews: PreviewProvider {
    static var previews: some View {
        ChatView()
            .frame(width: 300)
    }
}
