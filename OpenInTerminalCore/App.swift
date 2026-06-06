//
//  App.swift
//  OpenInTerminalCore
//
//  Created by Jianing Wang on 2020/12/5.
//  Copyright © 2020 Jianing Wang. All rights reserved.
//

import Foundation
import AppKit
import ScriptingBridge

public enum AppType: String, Codable {
    case terminal
    case editor
}

public struct App: Codable {
    public var name: String
    public var path: String?
    public var bundleId: String?
    public var type: AppType
    
    public init(name: String, type: AppType) {
        self.name = name
        self.type = type
    }
}

extension App: Equatable {
    public static func == (lhs: App, rhs: App) -> Bool {
        return lhs.name == rhs.name && lhs.bundleId == rhs.bundleId
    }
}

// MARK: - Openable

public protocol Openable {
    func openOutsideSandbox() throws
    func openInSandbox(_ urls: [URL]) throws
}

extension App: Openable {
    
    static let codexEmptyPromptSentinel = "\u{200B}"
    
    struct CodexOpenRequest {
        let workspaceURL: URL
        let promptText: String
    }
    
    func executeGeneralScript(_ openCommand: String) {
        logw(openCommand)
        guard let scriptURL = ScriptManager.shared.getScriptURL(with: Constants.generalScript) else { return }
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return }
        guard let script = try? NSUserAppleScriptTask(url: scriptURL) else { return }
        let event = ScriptManager.shared.getScriptEvent(functionName: "openApp", openCommand)
        script.execute(withAppleEvent: event) { (appleEvent, error) in
            if let error = error {
                logw("cannot execute applescript: \(error)")
            }
        }
    }
    
    func executeCodexOpenRequest(_ request: CodexOpenRequest) {
        logw("codex workspace: \(request.workspaceURL.path); prompt: \(request.promptText)")
        guard let url = codexDeepLinkURL(for: request) else {
            executeGeneralScript(codexOpenCommand([request.workspaceURL]))
            return
        }
        
        if !NSWorkspace.shared.open(url) {
            executeGeneralScript(codexOpenCommand([request.workspaceURL]))
        }
    }
    
    func codexDeepLinkURL(for request: CodexOpenRequest) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        
        var queryItems = [
            URLQueryItem(name: "path", value: request.workspaceURL.path)
        ]
        let promptText = request.promptText.isEmpty ? App.codexEmptyPromptSentinel : request.promptText
        queryItems.append(URLQueryItem(name: "prompt", value: promptText))
        components.queryItems = queryItems
        
        return components.url
    }
    
    func codexOpenRequest(_ urls: [URL]) -> CodexOpenRequest? {
        guard let url = urls.first?.standardizedFileURL else { return nil }
        if isDirectory(url) {
            return CodexOpenRequest(workspaceURL: url, promptText: "")
        }
        
        return CodexOpenRequest(workspaceURL: url.deletingLastPathComponent(),
                                promptText: url.path)
    }
    
    func isDirectory(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
           let isDirectory = values.isDirectory {
            return isDirectory
        }
        
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    
    func codexWorkspaceURLs(_ urls: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        return urls.compactMap { url in
            var isDirectory: ObjCBool = false
            let workspaceURL: URL
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                workspaceURL = url
            } else {
                workspaceURL = url.deletingLastPathComponent()
            }
            
            let standardizedURL = workspaceURL.standardizedFileURL
            guard !seenPaths.contains(standardizedURL.path) else { return nil }
            seenPaths.insert(standardizedURL.path)
            return standardizedURL
        }
    }
    
    func codexOpenCommand(_ urls: [URL]) -> String {
        let codexCLI = "/Applications/Codex.app/Contents/Resources/codex"
        return codexWorkspaceURLs(urls).map { url in
            let path = url.path.specialCharEscaped()
            return "if [ -x \(codexCLI) ]; then \(codexCLI) app \(path) >/dev/null 2>&1 & else open -b \(SupportedApps.codex.bundleId) \(path); fi"
        }.joined(separator: "; ")
    }
    
    public func openOutsideSandbox() throws {
        
        func excute(_ source: String) throws {
            guard let script = NSAppleScript(source: source) else {
                throw OITError.cannotCreateAppleScript(source)
            }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error != nil {
                throw OITError.cannotAccessApp(self.name)
            }
        }
        
        switch self.type {
        case .terminal:
            // get path
            var path = try FinderManager.shared.getPathToFrontFinderWindowOrSelectedFile()
            if path == "" {
                // No Finder window and no file selected.
                guard let desktopPath = FinderManager.shared.getDesktopPath() else { return }
                path = desktopPath
            }
            
            if SupportedApps.is(self, is: .terminal) {
                // this app is supported: Terminal
                let url = URL(fileURLWithPath: path)
                guard let terminal = SBApplication(bundleIdentifier: SupportedApps.terminal.bundleId) as TerminalApplication?,
                      let open = terminal.open else {
                    throw OITError.cannotAccessApp(self.name)
                }
                open([url])
                terminal.activate()
//                let newOption = DefaultsManager.shared.getNewOption(.terminal) ?? .window
//                switch newOption {
//                case .window:
//                    // open in a new window
//                    guard let terminal = SBApplication(bundleIdentifier: SupportedApps.terminal.bundleId) as TerminalApplication?,
//                          let open = terminal.open else {
//                        throw OITError.cannotAccessApp(self.name)
//                    }
//                    open([url])
//                    terminal.activate()
//                case .tab:
//                    // open in a new tab
//                    let source = ScriptManager.shared.getTerminalNewTabAppleScript(url: url)
//                    try excute(source)
//                }
            } else {
                // this app is general
                var openCommand = DefaultsManager.shared.getOpenCommand(self, escapeCount: 2)
                openCommand += " " + path.specialCharEscaped(2)
                let source = """
                do shell script "\(openCommand)"
                """
                try excute(source)
            }
            
        case .editor:
            // get paths
            var paths = try FinderManager.shared.getFullPathsToFrontFinderWindowOrSelectedFile()
            if paths.count == 0 {
                // No Finder window and no file selected.
                guard let desktopPath = FinderManager.shared.getDesktopPath() else { return }
                paths.append(desktopPath)
            }
            
            var openCommand = DefaultsManager.shared.getOpenCommand(self, escapeCount: 2)
            var path = ""
            paths.forEach {
                path += " \($0.specialCharEscaped(2))"
            }
            // fix for neovim
            if SupportedApps.is(self, is: .neovim) {
                openCommand = openCommand.replacingOccurrences(of: "PATH", with: path)
            } else {
                openCommand += path
            }
            logw(openCommand)
            
            let source = """
            do shell script "\(openCommand)"
            """
            try excute(source)
        }
    }
    
    public func openInSandbox(_ urls: [URL]) throws {
        switch self.type {
        case .terminal:
            guard var url = urls.first else { return }
            url.getDirectory()
            // get open command, e.g. "open -a Terminal /Users/user/Desktop/test\ folder"
            var openCommand = DefaultsManager.shared.getOpenCommand(self)
            openCommand += " " + url.path.specialCharEscaped()
//            // handle exceptional case
//            if SupportedApps.is(self, is: .terminal) {
//                if let newOption = DefaultsManager.shared.getNewOption(.terminal),
//                   newOption == .tab {
//                    openCommand = ScriptManager.shared.getTerminalNewTabCommand(path: path)
//                    guard let tabScriptURL = ScriptManager.shared.getScriptURL(with: Constants.terminalNewTabScript) else { return }
//                    scriptURL = tabScriptURL
//                }
//            }
            executeGeneralScript(openCommand)
        case .editor:
            if SupportedApps.is(self, is: .codex) {
                guard let request = codexOpenRequest(urls) else { return }
                executeCodexOpenRequest(request)
                return
            }
            
            // get open command, e.g. "open -a TextEdit /Users/user/Desktop/test\ folder /Users/user/Documents"
            var openCommand = DefaultsManager.shared.getOpenCommand(self)
            var path = ""
            urls.map {
                $0.path
            }.forEach {
                path += " " + $0.specialCharEscaped()
            }
            if SupportedApps.is(self, is: .neovim) {
                openCommand = openCommand.replacingOccurrences(of: "PATH", with: path)
            } else {
                openCommand += path
            }
            executeGeneralScript(openCommand)
        }
    }
    
}
