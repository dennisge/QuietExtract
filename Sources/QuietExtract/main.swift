import AppKit
import Darwin
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let jobs = Jobs()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dropState = DropState()
        let content = WindowContent(jobs: jobs, dropState: dropState) { [weak self] kind in self?.chooseFiles(kind) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 548, height: 445),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "QuietExtract"
        window.contentMinSize = NSSize(width: 440, height: 370)
        window.isReleasedWhenClosed = false
        window.contentView = ArchiveDropView(rootView: content, dropState: dropState) { [weak self] urls in
            guard let self else { return }
            jobs.enqueue(urls, kind: jobs.mode)
        }
        window.center()
        self.window = window
        installMenu()
        showWindow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        jobs.mode = .extract
        jobs.enqueue(urls, kind: .extract)
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        jobs.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) } ? .terminateNow : .terminateLater
    }

    @objc private func openArchives() { chooseFiles(.extract) }
    @objc private func compressItems() { chooseFiles(.compress) }
    @objc private func verifyArchives() { chooseFiles(.verify) }

    private func chooseFiles(_ kind: Job.Kind) {
        guard let window else { return }
        showWindow()
        let panel = NSOpenPanel()
        jobs.mode = kind
        panel.title = kind == .compress ? "Choose Files or Folders" : "Choose Archives"
        panel.canChooseDirectories = kind == .compress
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.jobs.enqueue(panel.urls, kind: kind) }
        }
    }

    private func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func installMenu() {
        let bar = NSMenu()
        let application = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "About QuietExtract", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit QuietExtract", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        application.submenu = applicationMenu
        bar.addItem(application)

        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let open = fileMenu.addItem(withTitle: "Open Archives…", action: #selector(openArchives), keyEquivalent: "o")
        open.target = self
        let compress = fileMenu.addItem(withTitle: "Compress Items…", action: #selector(compressItems), keyEquivalent: "n")
        compress.target = self
        let verify = fileMenu.addItem(withTitle: "Verify Archives…", action: #selector(verifyArchives), keyEquivalent: "")
        verify.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu
        bar.addItem(file)
        NSApp.mainMenu = bar
    }
}

setlocale(LC_CTYPE, "en_US.UTF-8")
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
