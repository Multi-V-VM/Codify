//
//  Resources.swift
//  Code
//
//  Created by Ken Chung on 7/11/2022.
//

import Foundation

class Resources {
    static let appGroupSharedLibrary = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.thebaselab.code")

    static let clangLib = URL(fileURLWithPath: Bundle.main.resourcePath!).appendingPathComponent(
        "ClangLib")

    static let wasmHTML = Bundle.main.url(
        forResource: "wasm-worker", withExtension: "html", subdirectory: "ClangLib")

    static let themes = URL(fileURLWithPath: Bundle.main.resourcePath!).appendingPathComponent(
        "Themes")

    static let pythonLibrary = URL(fileURLWithPath: Bundle.main.resourcePath!)
        .appendingPathComponent(
            "Library")

    static let carcert = Bundle.main.url(forResource: "cacert", withExtension: "pem")!

    static let npm = Bundle.main.url(forResource: "npm", withExtension: "bundle")!

    static let nodeWasm = Bundle.main.url(forResource: "node", withExtension: "wasm")

    static let ggufModel = Bundle.main.url(forResource: "Qwen3.5-0.8B-Q8_0", withExtension: "gguf")
}
