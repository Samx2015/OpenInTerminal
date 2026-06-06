//
//  AppDelegate.swift
//  OpenInTerminal
//
//  Created by Cameron Ingham on 4/17/19.
//  Copyright © 2019 Jianing Wang. All rights reserved.
//

import Cocoa
import OpenInTerminalCore
import ShortcutRecorder

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
    
    // MARK: - Properties
    
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    
    @IBOutlet weak var statusBarMenu: NSMenu!
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        DefaultsManager.shared.firstSetup()
        addObserver()
        terminateOpenInTerminalHelper()
        setStatusItemIcon()
        setStatusItemVisible()
        setStatusToggle()
        
        logw("")
        logw("App launched")
        logw("macOS \(ProcessInfo().operatingSystemVersionString)")
        logw("OpenInTerminal Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        
        // bind global shortcuts
        bindShortcuts()
        
        do {
            // check scripts and install them if needed
            try checkScripts()
        } catch {
            logw(error.localizedDescription)
        }
        
        showFinderExtensionSetupIfNeeded()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        NSStatusBar.system.removeStatusItem(statusItem)
        
        removeObserver()
        logw("App terminated")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showPreferencesWindow()
        }
        return true
    }
    
}

extension AppDelegate {
    
    // MARK: - Status Bar Item
    
    func setStatusItemIcon() {
        let icon = NSImage(assetIdentifier: .StatusBarIcon)
        icon.isTemplate = true // Support Dark Mode
        DispatchQueue.main.async {
            self.statusItem.button?.image = icon
        }
    }
    
    func setStatusItemVisible() {
        let isHideStatusItem = DefaultsManager.shared.isHideStatusItem
        statusItem.isVisible = !isHideStatusItem
    }
    
    func setStatusToggle() {
        let isQuickToogle = DefaultsManager.shared.isQuickToggle
        if isQuickToogle {
            statusItem.menu = nil
            if let button = statusItem.button {
                button.action = #selector(statusBarButtonClicked)
                button.sendAction(on: [.leftMouseUp, .leftMouseDown,
                                       .rightMouseUp, .rightMouseDown])
            }
        } else {
            statusItem.menu = statusBarMenu
        }
    }
    
    @objc func statusBarButtonClicked(sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseDown || event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)
        {
            statusItem.menu = statusBarMenu
            statusItem.button?.performClick(self)
            statusItem.menu = nil
        } else if event.type == .leftMouseUp {
            if let quickToggleType = DefaultsManager.shared.quickToggleType {
                switch quickToggleType {
                case .openWithDefaultTerminal:
                    openDefaultTerminal()
                case .openWithDefaultEditor:
                    openDefaultEditor()
                case .copyPathToClipboard:
                    copyPathToClipboard()
                }
            }
        }
    }
    
    func terminateOpenInTerminalHelper() {
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Constants.Id.LauncherApp
        }
        
        if isRunning {
            LaunchNotifier.postNotification(.terminateApp, object: Bundle.main.bundleIdentifier!)
        }
    }
    
    func showPreferencesWindow() {
        NSApp.setActivationPolicy(.regular) // show icon in Dock
        let preferencesWindowController: PreferencesWindowController = {
            let storyboard = NSStoryboard(storyboardIdentifier: .Preferences)
            let windowController = storyboard.instantiateInitialController() as? PreferencesWindowController ?? PreferencesWindowController()
            return windowController
        }()
        preferencesWindowController.window?.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindowController.showWindow(self)
        preferencesWindowController.window?.makeKeyAndOrderFront(self)
    }
    
    func showFinderExtensionSetupIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !self.isFinderExtensionEnabled() {
                self.activateForUserInteraction()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.askHowToOpenFinderExtensionSettings()
                }
            }
        }
    }
    
    func askHowToOpenFinderExtensionSettings() {
        activateForUserInteraction()
        
        let alert = NSAlert()
        alert.messageText = "Enable the Finder extension?"
        alert.informativeText = """
        OpenInTerminal adds Finder context menu items through a bundled Finder extension.
        
        You can enable it automatically, or open macOS Extensions settings and find OpenInTerminal by app name.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable Automatically")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        alert.window.level = .modalPanel
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.window.center()
        alert.window.orderFrontRegardless()
        activateForUserInteraction()
        
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if !enableFinderExtensionAutomatically() {
                openFinderExtensionSettings(shouldRegisterFinderExtension: true)
            }
        case .alertSecondButtonReturn:
            openFinderExtensionSettings(shouldRegisterFinderExtension: true)
        default:
            logw("Skipped Finder extension settings")
        }
    }
    
    func openFinderExtensionSettings(shouldRegisterFinderExtension: Bool) {
        logw("Opening Finder extension settings; register extension: \(shouldRegisterFinderExtension)")
        if shouldRegisterFinderExtension {
            registerFinderExtensionForSettings()
        }
        
        openSystemSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension?ExtensionItems")
    }
    
    @discardableResult
    func openSystemSettings(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }
    
    func activateForUserInteraction() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @discardableResult
    func registerFinderExtensionForSettings() -> Bool {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else { return false }
        let extensionURL = pluginsURL.appendingPathComponent("OpenInTerminalFinderExtension.appex")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { return false }
        
        guard let result = runPlugInKit(arguments: ["-a", extensionURL.path]) else { return false }
        if result.status != 0 {
            logw("pluginkit registration failed: \(result.status); \(result.output)")
            return false
        }
        return true
    }
    
    func enableFinderExtensionAutomatically() -> Bool {
        guard registerFinderExtensionForSettings() else { return false }
        guard let result = runPlugInKit(arguments: ["-e", "use", "-i", Constants.Id.FinderExtension]) else {
            return false
        }
        
        if result.status != 0 {
            logw("pluginkit enable failed: \(result.status); \(result.output)")
            return false
        }
        
        let isEnabled = isFinderExtensionEnabled()
        logw("Finder extension automatically enabled: \(isEnabled)")
        return isEnabled
    }
    
    func isFinderExtensionEnabled() -> Bool {
        guard let result = runPlugInKit(arguments: ["-m", "-A", "-D", "-i", Constants.Id.FinderExtension]) else {
            return false
        }
        
        let isEnabled = result.output.components(separatedBy: .newlines).contains { line in
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedLine.contains(Constants.Id.FinderExtension)
                && (trimmedLine.hasPrefix("+") || trimmedLine.hasPrefix("!"))
        }
        
        logw("Finder extension enabled: \(isEnabled)")
        return isEnabled
    }
    
    func runPlugInKit(arguments: [String]) -> (output: String, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (output: output, status: process.terminationStatus)
        } catch {
            logw("cannot run pluginkit \(arguments): \(error)")
            return nil
        }
    }
    
    // MARK: - Notification
    
    func addObserver() {
        OpenNotifier.addObserver(observer: self,
                                 selector: #selector(openDefaultTerminal),
                                 notification: .openDefaultTerminal)
        OpenNotifier.addObserver(observer: self,
                                 selector: #selector(openDefaultEditor),
                                 notification: .openDefaultEditor)
        OpenNotifier.addObserver(observer: self,
                                 selector: #selector(copyPathToClipboard),
                                 notification: .copyPathToClipboard)
    }
    
    func removeObserver() {
        OpenNotifier.removeObserver(observer: self, notification: .openDefaultTerminal)
        OpenNotifier.removeObserver(observer: self, notification: .openDefaultEditor)
        OpenNotifier.removeObserver(observer: self, notification: .copyPathToClipboard)
    }
    
    // MARK: Notification Actions
    
    @objc func openDefaultTerminal() {
        var defaultTerminal: App
        if let terminal = DefaultsManager.shared.defaultTerminal {
            defaultTerminal = terminal
        } else {
            // if there is no defualt terminal, then pick one
            guard let selectedTerminal = AppManager.shared.pickTerminalAlert() else {
                return
            }
            DefaultsManager.shared.defaultTerminal = selectedTerminal
            defaultTerminal = selectedTerminal
        }
        do {
            try defaultTerminal.openOutsideSandbox()
        } catch {
            logw("\(error)")
        }
    }
    
    @objc func openDefaultEditor() {
        var defaultEditor: App
        if let editor = DefaultsManager.shared.defaultEditor {
            defaultEditor = editor
        } else {
            // if there is no defualt editor, then pick one
            guard let selectedEditor = AppManager.shared.pickEditorAlert() else {
                return
            }
            DefaultsManager.shared.defaultEditor = selectedEditor
            defaultEditor = selectedEditor
        }
        do {
            try defaultEditor.openOutsideSandbox()
        } catch {
            logw("\(error)")
        }
    }
    
    @objc func copyPathToClipboard() {
        do {
            var urls = try FinderManager.shared.getFullUrlsToFrontFinderWindowOrSelectedFile()
            if urls.count == 0 {
                // No Finder window and no file selected.
                let homePath = NSHomeDirectory()
                guard let homeUrl = URL(string: homePath) else { return }
                urls.append(homeUrl.appendingPathComponent("Desktop"))
            }
            let paths = urls.map { $0.path }
            let pathString = paths.joined(separator: "\n")
            // Set string
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pathString, forType: .string)
        } catch {
            logw(error.localizedDescription)
        }
    }
    
//    func writeimage() {
//        SupportedApps.allCases.forEach {
//            let path = "/Applications/\($0.name).app"
//            guard FileManager.default.fileExists(atPath: path) else { return }
//
//            let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
//            let destinationURL = desktopURL.appendingPathComponent("\($0.name).png")
//            let icon = AppManager.getApplicationIcon(from: path)
//
//            guard let tiffRepresentation = icon.tiffRepresentation,
//                  let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else { return }
//            let pngData = bitmapImage.representation(using: .png, properties: [:])
//            do {
//                try pngData?.write(to: destinationURL, options: .atomic)
//            } catch {
//                print("\($0.name)")
//                print(error)
//            }
//        }
//    }
}

extension AppDelegate {
    
    // MARK: - Global Shortcuts
    
    func bindShortcuts() {
        let oitAction = ShortcutAction(keyPath: Constants.Key.defaultTerminalShortcut, of: Defaults) { _ in
            let appDelegate = NSApplication.shared.delegate as! AppDelegate
            appDelegate.openDefaultTerminal()
            return true
        }
        GlobalShortcutMonitor.shared.addAction(oitAction, forKeyEvent: .down)
        
        let oieAction = ShortcutAction(keyPath: Constants.Key.defaultEditorShortcut, of: Defaults) { _ in
            let appDelegate = NSApplication.shared.delegate as! AppDelegate
            appDelegate.openDefaultEditor()
            return true
        }
        GlobalShortcutMonitor.shared.addAction(oieAction, forKeyEvent: .down)
        
        let copyPathAction = ShortcutAction(keyPath: Constants.Key.copyPathShortcut, of: Defaults) { _ in
            let appDelegate = NSApplication.shared.delegate as! AppDelegate
            appDelegate.copyPathToClipboard()
            return true
        }
        GlobalShortcutMonitor.shared.addAction(copyPathAction, forKeyEvent: .down)
    }
}

extension AppDelegate: NSWindowDelegate {
    
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // hide icon in Dock
    }
}
