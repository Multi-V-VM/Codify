//
//  DebuggerSidebarView.swift
//  Code
//

import SwiftUI

struct DebuggerSidebarView: View {
    @StateObject private var dbg = DebuggerService.shared

    var body: some View {
        VStack(spacing: 8) {
            // Connection/config row
            HStack {
                Text("gdb.wasm:")
                TextField("/path/to/gdb.wasm", text: $dbg.gdbWasmPath)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Target:")
                TextField("/path/to/program.wasm", text: $dbg.targetWasmPath)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Args:")
                TextField("--flags", text: $dbg.targetArgs)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button(action: { dbg.configureDefaultsIfNeeded(); dbg.launch() }) {
                    Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button(action: { dbg.terminate() }) {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)

            // Controls
            HStack {
                Button { if !dbg.targetWasmPath.isEmpty { dbg.fileExecAndSymbols(dbg.targetWasmPath) } } label: {
                    Image(systemName: "folder.badge.plus")
                }.help("Load Symbols")
                Button { dbg.execRun() } label: { Image(systemName: "play.fill") }.help("Run")
                Button { dbg.execContinue() } label: { Image(systemName: "forward.end.fill") }.help("Continue")
                Button { dbg.execNext() } label: { Image(systemName: "arrow.turn.down.right") }.help("Step Over")
                Button { dbg.execStep() } label: { Image(systemName: "arrow.down.right.circle") }.help("Step Into")
                Button { dbg.execFinish() } label: { Image(systemName: "arrow.uturn.left.circle") }.help("Step Out")
                Spacer()
            }

            // Current location
            if let loc = dbg.currentLocation {
                HStack {
                    Image(systemName: "location.fill")
                        .foregroundColor(.green)
                    Text("\(loc.file):\(loc.line)")
                        .font(.caption)
                }
                .padding(6)
                .background(Color.green.opacity(0.1))
                .cornerRadius(6)
            }

            // Breakpoints & Stack
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Breakpoints").font(.headline)
                        Spacer()
                    }
                    List(dbg.breakpoints, id: \.self) { bp in Text(bp) }
                }
                VStack(alignment: .leading) {
                    HStack { Text("Stack").font(.headline); Spacer() }
                    List(dbg.stackFrames, id: \.self) { fr in Text(fr) }
                }
            }
            .frame(maxHeight: 220)

            // MI Console
            VStack(alignment: .leading, spacing: 4) {
                Text("MI Console").font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(dbg.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
                HStack {
                    TextField("-exec-run", text: Binding(get: { "" }, set: { cmd in if !cmd.isEmpty { dbg.sendMI(cmd) } }))
                        .textFieldStyle(.roundedBorder)
                    Button("Send") { /* handled via onCommit */ }
                }
            }

            Spacer()
        }
        .padding(8)
        .onAppear { dbg.configureDefaultsIfNeeded() }
    }

    private var statusText: String {
        switch dbg.state {
        case .disconnected: return "Disconnected"
        case .launching: return "Launching…"
        case .connected: return "Connected"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

struct DebuggerSidebarView_Previews: PreviewProvider {
    static var previews: some View {
        DebuggerSidebarView()
    }
}

