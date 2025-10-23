//
//  AgentView.swift
//  Code
//
//  Created by Claude on 23/10/2025.
//

import SwiftUI

struct AgentView: View {
    @StateObject private var agentService = AgentService.shared
    @State private var instruction: String = ""
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.purple)
                Text("AI Agent")
                    .font(.headline)

                Spacer()

                if agentService.isProcessing {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                Button(action: { isExpanded.toggle() }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Input section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What would you like me to do?")
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            TextEditor(text: $instruction)
                                .frame(minHeight: 80)
                                .padding(8)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .cornerRadius(8)

                            Button(action: startAgent) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Run Agent")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(instruction.isEmpty ? Color.gray : Color.purple)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                            }
                            .disabled(instruction.isEmpty || agentService.isProcessing)
                        }

                        // Active sessions
                        ForEach(agentService.activeSessions) { session in
                            AgentSessionView(session: session)
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Color(UIColor.systemBackground))
    }

    private func startAgent() {
        // Get current file from editor
        // TODO: Integrate with editor to get current file
        let dummyContent = "// Placeholder code"
        let dummyPath = "current_file.swift"

        let _ = agentService.startSession(
            instruction: instruction,
            filePath: dummyPath,
            fileContent: dummyContent
        )

        instruction = ""
    }
}

// MARK: - Agent Session View

struct AgentSessionView: View {
    @ObservedObject var session: AgentSession
    @State private var showingDetails: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Session header
            HStack {
                StatusIndicator(status: session.status)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.instruction)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(session.filePath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { showingDetails.toggle() }) {
                    Image(systemName: showingDetails ? "chevron.up.circle" : "chevron.down.circle")
                }
            }

            if showingDetails {
                // Thinking steps
                if !session.thinkingSteps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plan:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(Array(session.thinkingSteps.enumerated()), id: \.offset) { index, step in
                            Text(step)
                                .font(.caption)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.tertiarySystemBackground))
                                .cornerRadius(6)
                        }
                    }
                }

                // Proposed actions
                if !session.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proposed Changes:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(session.actions) { action in
                            CodeActionView(action: action)
                        }
                    }
                }

                // Action buttons
                if session.status == .waitingForApproval {
                    HStack(spacing: 12) {
                        Button(action: { applyActions() }) {
                            HStack {
                                Image(systemName: "checkmark")
                                Text("Accept")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }

                        Button(action: { rejectActions() }) {
                            HStack {
                                Image(systemName: "xmark")
                                Text("Reject")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }
                    }
                }

                // Error message
                if let error = session.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func applyActions() {
        AgentService.shared.applyActions(session: session) { result in
            switch result {
            case .success(let newContent):
                // TODO: Apply newContent to the editor
                print("New content:\n\(newContent)")

            case .failure(let error):
                print("Failed to apply actions: \(error)")
            }
        }
    }

    private func rejectActions() {
        AgentService.shared.rejectActions(session: session)
    }
}

// MARK: - Code Action View

struct CodeActionView: View {
    let action: CodeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconForActionType(action.type))
                    .foregroundColor(colorForActionType(action.type))

                Text(action.type.rawValue)
                    .font(.caption)
                    .fontWeight(.semibold)

                Text("Lines \(action.lineStart)-\(action.lineEnd)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }

            Text(action.description)
                .font(.caption)
                .foregroundColor(.secondary)

            // Show diff
            if action.type == .replace && !action.oldContent.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("- \(action.oldContent)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.red)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))

                    Text("+ \(action.newContent)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.green)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1))
                }
            } else {
                Text(action.newContent)
                    .font(.system(.caption, design: .monospaced))
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.tertiarySystemBackground))
            }
        }
        .padding(8)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(8)
    }

    private func iconForActionType(_ type: CodeAction.ActionType) -> String {
        switch type {
        case .replace: return "arrow.triangle.2.circlepath"
        case .insert: return "plus.circle"
        case .delete: return "trash"
        }
    }

    private func colorForActionType(_ type: CodeAction.ActionType) -> Color {
        switch type {
        case .replace: return .blue
        case .insert: return .green
        case .delete: return .red
        }
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let status: AgentSession.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForStatus(status))
                .frame(width: 8, height: 8)

            Text(textForStatus(status))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func colorForStatus(_ status: AgentSession.Status) -> Color {
        switch status {
        case .thinking, .proposingActions, .applying:
            return .orange
        case .waitingForApproval:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private func textForStatus(_ status: AgentSession.Status) -> String {
        switch status {
        case .thinking: return "Thinking..."
        case .proposingActions: return "Creating plan..."
        case .waitingForApproval: return "Review changes"
        case .applying: return "Applying..."
        case .completed: return "Complete"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Preview

struct AgentView_Previews: PreviewProvider {
    static var previews: some View {
        AgentView()
    }
}
