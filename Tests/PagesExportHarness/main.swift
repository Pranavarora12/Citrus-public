import Foundation
import AppKit

func runChecks(in output: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    let samples = [
        "Unicode: café — नमस्ते 🌿\nQuoted: \"hello\" and \\ paths\n",
        "First line\r\nSecond line\rThird line",
        "",
        "No final newline"
    ]
    for (index, text) in samples.enumerated() {
        let destination = output.appendingPathComponent("Roundtrip \(index)-\(UUID().uuidString).pages")
        try PagesIO.write(text: text, to: destination)
        let expected = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard try PagesIO.readText(destination) == expected else { throw PagesIO.Failure("Roundtrip content mismatch") }
        print("PASS Native Pages export roundtrip \(index)")
    }
    print("PAGES EXPORT CHECKS PASSED: \(samples.count)")
}

final class PagesChecksDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "Run the checks to create four temporary Pages documents. A macOS Automation prompt may appear.")
    let button = NSButton(title: "Run Pages export checks", target: nil, action: nil)
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 620, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Citrus Pages Export Checks"
        window.isReleasedWhenClosed = false
        status.frame = NSRect(x: 20, y: 75, width: 580, height: 120)
        button.frame = NSRect(x: 20, y: 20, width: 240, height: 36)
        button.target = self; button.action = #selector(run)
        window.contentView?.addSubview(status); window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func run() {
        button.isEnabled = false; status.stringValue = "Running Pages roundtrip checks…"
        let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("pages-export-live-results")
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            do { try runChecks(in: output); message = "PASS: four native Pages exports preserve all tested text. Outputs: " + output.path }
            catch { message = "FAILED: " + error.localizedDescription }
            DispatchQueue.main.async { self.status.stringValue = message; self.button.isEnabled = true }
        }
    }
}

if Bundle.main.bundleURL.pathExtension == "app" {
    let app = NSApplication.shared
    let delegate = PagesChecksDelegate(); app.delegate = delegate
    app.setActivationPolicy(.regular); app.run()
} else {
    let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/pages-export-results", isDirectory: true)
    do { try runChecks(in: output) }
    catch { fputs("PAGES EXPORT CHECKS FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
}
