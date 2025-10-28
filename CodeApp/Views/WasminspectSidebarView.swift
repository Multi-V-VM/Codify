//
//  WasminspectSidebarView.swift
//  Code
//
//  UI for Wasminspect WebAssembly debugger
//

import SwiftUI

struct WasminspectSidebarView: View {
    @ObservedObject private var service = WasminspectService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and state
            headerView

            Divider()

            // Configuration section
            configurationSection

            Divider()

            // Control buttons
            controlButtons

            Divider()

            // Tab view for different debug info
            TabView {
                consoleView
                    .tabItem {
                        Label("Console", systemImage: "terminal")
                    }

                stackView
                    .tabItem {
                        Label("Stack", systemImage: "list.bullet")
                    }

                variablesView
                    .tabItem {
                        Label("Variables", systemImage: "cube.box")
                    }

                breakpointsView
                    .tabItem {
                        Label("Breakpoints", systemImage: "circle.fill")
                    }
            }
        }
        .onAppear {
            service.configureDefaultsIfNeeded()
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: "ant.fill")
                .foregroundColor(.blue)
            Text("Wasminspect Debugger")
                .font(.headline)
            Spacer()
            stateIndicator
        }
        .padding()
    }

    private var stateIndicator: some View {
        Group {
            switch service.state {
            case .disconnected:
                Circle()
                    .fill(Color.gray)
                    .frame(width: 12, height: 12)
            case .launching:
                ProgressView()
                    .scaleEffect(0.5)
            case .connected, .stopped:
                Circle()
                    .fill(Color.orange)
                    .frame(width: 12, height: 12)
            case .running:
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
            case .error:
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
            }
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Text("Wasminspect WASM:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Path to wasminspect.wasm", text: $service.wasminspectWasmPath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(.caption, design: .monospaced))

                Text("Target WASM:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Path to target .wasm file", text: $service.targetWasmPath)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(.caption, design: .monospaced))

                Text("Arguments:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Command line arguments", text: $service.targetArgs)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding()
    }

    private var controlButtons: some View {
        VStack(spacing: 8) {
            // Primary controls
            HStack(spacing: 12) {
                Button(action: {
                    if case .disconnected = service.state {
                        service.launch()
                    } else {
                        service.terminate()
                    }
                }) {
                    HStack {
                        Image(systemName: service.state == .disconnected ? "play.fill" : "stop.fill")
                        Text(service.state == .disconnected ? "Launch" : "Stop")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(service.state == .disconnected ? .green : .red)

                Button(action: {
                    if case .stopped = service.state {
                        service.execContinue()
                    }
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Continue")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(service.state != .stopped)
            }

            // Step controls
            HStack(spacing: 8) {
                Button(action: { service.stepIn() }) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                        Text("Step In")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(service.state != .stopped)

                Button(action: { service.stepOver() }) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                        Text("Step Over")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(service.state != .stopped)

                Button(action: { service.stepOut() }) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                        Text("Step Out")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(service.state != .stopped)
            }

            // Additional actions
            HStack(spacing: 8) {
                Button(action: { service.requestBacktrace() }) {
                    HStack {
                        Image(systemName: "list.bullet.rectangle")
                        Text("Backtrace")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(service.state != .stopped)

                Button(action: { service.requestLocalVariables() }) {
                    HStack {
                        Image(systemName: "cube")
                        Text("Locals")
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(service.state != .stopped)
            }
        }
        .padding()
    }

    private var consoleView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(service.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .onChange(of: service.logLines.count) { _ in
                if let lastIndex = service.logLines.indices.last {
                    proxy.scrollTo(lastIndex, anchor: .bottom)
                }
            }
        }
    }

    private var stackView: some View {
        List {
            if service.stackFrames.isEmpty {
                Text("No stack frames available")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(service.stackFrames, id: \.id) { frame in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(frame.id): \(frame.name)")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)

                        if let file = frame.file {
                            Text("\(file):\(frame.line):\(frame.column)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var variablesView: some View {
        List {
            if !service.localVariables.isEmpty {
                Section(header: Text("Locals")) {
                    ForEach(service.localVariables, id: \.name) { variable in
                        variableRow(variable)
                    }
                }
            }

            if !service.globalVariables.isEmpty {
                Section(header: Text("Globals")) {
                    ForEach(service.globalVariables, id: \.name) { variable in
                        variableRow(variable)
                    }
                }
            }

            if service.localVariables.isEmpty && service.globalVariables.isEmpty {
                Text("No variables available")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
    }

    private func variableRow(_ variable: WasminspectService.Variable) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(variable.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Spacer()
                Text(variable.type)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(variable.value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.blue)
        }
        .padding(.vertical, 2)
    }

    private var breakpointsView: some View {
        List {
            if service.breakpoints.isEmpty {
                Text("No breakpoints set")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                ForEach(service.breakpoints, id: \.id) { bp in
                    HStack {
                        Image(systemName: bp.verified ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(bp.verified ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(bp.file):\(bp.line)")
                                .font(.system(.body, design: .monospaced))
                            Text("ID: \(bp.id)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(action: {
                            service.deleteBreakpoint(file: bp.file, line: bp.line)
                        }) {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct WasminspectSidebarView_Previews: PreviewProvider {
    static var previews: some View {
        WasminspectSidebarView()
            .frame(width: 350, height: 600)
    }
}
