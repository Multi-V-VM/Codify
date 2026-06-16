//
//  ProtonDisplayBridge.swift
//  Code
//
//  Routes Proton/WASM RGBA frames into an editor tab instead of the terminal.
//

import Foundation
import SwiftUI
import WebKit

private struct WasmerDisplayFrame {
    let width: UInt32
    let height: UInt32
    let stride: UInt32
    let format: UInt32
    let data: UnsafePointer<UInt8>?
    let dataLen: UInt
    let frameID: UInt64
}

struct ProtonDisplayFrame {
    let width: Int
    let height: Int
    let stride: Int
    let frameID: UInt64
    let data: Data
}

private typealias WasmerDisplayFrameCallback =
    @convention(c) (
        UnsafeRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Void

@_silgen_name("wasmer_set_display_frame_callback")
private func wasmer_set_display_frame_callback(
    _ callback: WasmerDisplayFrameCallback?,
    _ userData: UnsafeMutableRawPointer?
)

@_silgen_name("wasmer_display_enqueue_input_event")
private func wasmer_display_enqueue_input_event(
    _ eventType: UInt32,
    _ code: UInt32,
    _ x: Int32,
    _ y: Int32,
    _ value: Int32,
    _ modifiers: UInt32
) -> Int32

extension Notification.Name {
    static let protonDisplayEditorRequested = Notification.Name("proton.display.editor.requested")
}

private func protonNumber(_ value: Any?) -> Int64 {
    if let value = value as? NSNumber {
        return value.int64Value
    }
    if let value = value as? Int {
        return Int64(value)
    }
    if let value = value as? Double {
        return Int64(value.rounded())
    }
    if let value = value as? String, let parsed = Int64(value) {
        return parsed
    }
    return 0
}

private func protonUInt32(_ value: Any?) -> UInt32 {
    let number = protonNumber(value)
    guard number > 0 else { return 0 }
    return UInt32(min(number, Int64(UInt32.max)))
}

private func protonInt32(_ value: Any?) -> Int32 {
    let number = protonNumber(value)
    return Int32(max(Int64(Int32.min), min(number, Int64(Int32.max))))
}

private let protonDisplayFrameCallback: WasmerDisplayFrameCallback = { framePointer, userData in
    guard let framePointer, let userData else { return }
    let frame = framePointer.bindMemory(to: WasmerDisplayFrame.self, capacity: 1).pointee
    guard frame.format == 1, let data = frame.data, frame.dataLen > 0 else { return }

    let copiedFrame = ProtonDisplayFrame(
        width: Int(frame.width),
        height: Int(frame.height),
        stride: Int(frame.stride),
        frameID: frame.frameID,
        data: Data(bytes: data, count: Int(frame.dataLen)))

    let bridge = Unmanaged<ProtonDisplayBridge>.fromOpaque(userData).takeUnretainedValue()
    bridge.present(copiedFrame)
}

final class ProtonDisplayBridge {
    static let shared = ProtonDisplayBridge()

    private weak var surface: ProtonDisplaySurface?
    private var lastFrame: ProtonDisplayFrame?
    private var isInstalled = false
    private var isEditorRequestPending = false

    private init() {}

    func install() {
        guard !isInstalled else { return }
        let userData = Unmanaged.passUnretained(self).toOpaque()
        wasmer_set_display_frame_callback(protonDisplayFrameCallback, userData)
        isInstalled = true
    }

    func attach(surface: ProtonDisplaySurface) {
        install()
        self.surface = surface
        isEditorRequestPending = false
        if let lastFrame {
            surface.present(lastFrame)
        }
    }

    func detach(surface: ProtonDisplaySurface) {
        if self.surface === surface {
            self.surface = nil
        }
    }

    func requestEditor() {
        DispatchQueue.main.async {
            self.requestEditorOnMain()
        }
    }

    func enqueueInput(from message: [String: Any]) {
        let eventType = protonUInt32(message["Type"])
        let code = protonUInt32(message["Code"])
        let x = protonInt32(message["X"])
        let y = protonInt32(message["Y"])
        let value = protonInt32(message["Value"])
        let modifiers = protonUInt32(message["Modifiers"])
        _ = wasmer_display_enqueue_input_event(eventType, code, x, y, value, modifiers)
    }

    fileprivate func present(_ frame: ProtonDisplayFrame) {
        DispatchQueue.main.async {
            self.lastFrame = frame
            if let surface = self.surface {
                surface.present(frame)
            } else {
                self.requestEditorOnMain()
            }
        }
    }

    private func requestEditorOnMain() {
        guard surface == nil, !isEditorRequestPending else { return }
        isEditorRequestPending = true
        NotificationCenter.default.post(name: .protonDisplayEditorRequested, object: nil)
    }
}

final class ProtonDisplaySurface: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView = WebViewBase()

    private var isLoaded = false
    private var pendingFrame: ProtonDisplayFrame?

    override init() {
        super.init()
        webView.isOpaque = false
        webView.backgroundColor = UIColor(id: "editor.background")
        webView.scrollView.backgroundColor = UIColor(id: "editor.background")
        webView.scrollView.bounces = false
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "protonDisplayInput")
        webView.loadHTMLString(Self.html, baseURL: nil)
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: "protonDisplayInput")
    }

    func present(_ frame: ProtonDisplayFrame) {
        DispatchQueue.main.async {
            guard self.isLoaded else {
                self.pendingFrame = frame
                return
            }
            self.presentLoadedFrame(frame)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        if let pendingFrame {
            self.pendingFrame = nil
            presentLoadedFrame(pendingFrame)
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        ProtonDisplayBridge.shared.enqueueInput(from: body)
    }

    private func presentLoadedFrame(_ frame: ProtonDisplayFrame) {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4 else { return }
        let payload: [String: Any] = [
            "width": frame.width,
            "height": frame.height,
            "stride": frame.stride,
            "frameID": String(frame.frameID),
            "data": frame.data.base64EncodedString(),
        ]
        guard
            let jsonData = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: jsonData, encoding: .utf8)
        else {
            return
        }
        webView.evaluateJavaScript(
            "window.protonPresentFrame && window.protonPresentFrame(\(json));")
    }

    private static let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
          <style>
            html, body {
              width: 100%;
              height: 100%;
              margin: 0;
              overflow: hidden;
              background: #0b0f14;
            }
            #viewport {
              width: 100vw;
              height: 100vh;
              display: block;
              image-rendering: pixelated;
              background: #05070a;
              outline: none;
            }
            #empty {
              position: fixed;
              inset: 0;
              display: grid;
              place-items: center;
              color: rgba(235, 240, 247, 0.55);
              font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              pointer-events: none;
            }
            body.has-frame #empty {
              display: none;
            }
          </style>
        </head>
        <body>
          <canvas id="viewport" tabindex="0"></canvas>
          <div id="empty">Waiting for Proton frames</div>
          <script>
            const canvas = document.getElementById("viewport");
            const context = canvas.getContext("2d", { alpha: false });
            let imageData = null;
            let imageBuffer = null;

            function decodeBase64Bytes(value) {
              const binary = atob(value);
              const bytes = new Uint8Array(binary.length);
              for (let i = 0; i < binary.length; i++) {
                bytes[i] = binary.charCodeAt(i);
              }
              return bytes;
            }

            function modifierMask(event) {
              return (
                (event.shiftKey ? 1 : 0) |
                (event.ctrlKey ? 2 : 0) |
                (event.altKey ? 4 : 0) |
                (event.metaKey ? 8 : 0)
              );
            }

            function canvasPoint(event) {
              const rect = canvas.getBoundingClientRect();
              const scaleX = canvas.width / Math.max(rect.width, 1);
              const scaleY = canvas.height / Math.max(rect.height, 1);
              return {
                x: Math.round((event.clientX - rect.left) * scaleX),
                y: Math.round((event.clientY - rect.top) * scaleY),
              };
            }

            function postInput(type, event, value) {
              const handlers = window.webkit && window.webkit.messageHandlers;
              if (!handlers || !handlers.protonDisplayInput) {
                return;
              }
              const point = canvasPoint(event);
              const key = event.key && event.key.length === 1 ? event.key.charCodeAt(0) : 0;
              const button = typeof event.button === "number" && event.button >= 0 ? event.button : 0;
              handlers.protonDisplayInput.postMessage({
                Type: type,
                Code: type === 5 || type === 6 ? key : button,
                X: point.x,
                Y: point.y,
                Value: value || 0,
                Modifiers: modifierMask(event),
              });
            }

            window.protonPresentFrame = function(frame) {
              if (!frame || !frame.width || !frame.height || !frame.data) {
                return;
              }
              document.body.classList.add("has-frame");
              const width = frame.width | 0;
              const height = frame.height | 0;
              const stride = Math.max(frame.stride | 0, width * 4);
              const bytes = decodeBase64Bytes(frame.data);
              if (canvas.width !== width || canvas.height !== height || !imageData) {
                canvas.width = width;
                canvas.height = height;
                imageData = context.createImageData(width, height);
                imageBuffer = imageData.data;
              }
              for (let y = 0; y < height; y++) {
                const sourceOffset = y * stride;
                const targetOffset = y * width * 4;
                imageBuffer.set(bytes.subarray(sourceOffset, sourceOffset + width * 4), targetOffset);
              }
              context.putImageData(imageData, 0, 0);
            };

            canvas.addEventListener("pointerdown", (event) => {
              canvas.focus();
              canvas.setPointerCapture(event.pointerId);
              postInput(1, event, 1);
              event.preventDefault();
            });
            canvas.addEventListener("pointerup", (event) => {
              postInput(2, event, 0);
              event.preventDefault();
            });
            canvas.addEventListener("pointermove", (event) => {
              postInput(3, event, 0);
            });
            canvas.addEventListener("wheel", (event) => {
              postInput(4, event, Math.round(event.deltaY));
              event.preventDefault();
            }, { passive: false });
            canvas.addEventListener("keydown", (event) => {
              postInput(5, event, 1);
              event.preventDefault();
            });
            canvas.addEventListener("keyup", (event) => {
              postInput(6, event, 0);
              event.preventDefault();
            });
          </script>
        </body>
        </html>
        """
}

private struct ProtonDisplayEditorView: UIViewRepresentable {
    let surface: ProtonDisplaySurface

    func makeUIView(context: Context) -> UIView {
        surface.webView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

final class ProtonDisplayEditorInstance: EditorInstance {
    let surface: ProtonDisplaySurface

    init() {
        let surface = ProtonDisplaySurface()
        self.surface = surface
        super.init(
            view: AnyView(ProtonDisplayEditorView(surface: surface)), title: "Proton Display")
        ProtonDisplayBridge.shared.attach(surface: surface)
    }

    deinit {
        ProtonDisplayBridge.shared.detach(surface: surface)
    }
}

final class ProtonDisplayEditorExtension: CodeAppExtension {
    private var requestObserver: NSObjectProtocol?

    override func onInitialize(app: MainApp, contribution: CodeAppExtension.Contribution) {
        ProtonDisplayBridge.shared.install()
        requestObserver = NotificationCenter.default.addObserver(
            forName: .protonDisplayEditorRequested,
            object: nil,
            queue: .main
        ) { [weak app] _ in
            guard let app else { return }
            Task { @MainActor in
                Self.openEditor(in: app)
            }
        }
    }

    deinit {
        if let requestObserver {
            NotificationCenter.default.removeObserver(requestObserver)
        }
    }

    @MainActor
    private static func openEditor(in app: MainApp) {
        if let existingEditor = app.editors.first(where: { $0 is ProtonDisplayEditorInstance }) {
            app.setActiveEditor(editor: existingEditor)
            return
        }
        let editor = ProtonDisplayEditorInstance()
        app.appendAndFocusNewEditor(editor: editor, alwaysInNewTab: true)
    }
}
