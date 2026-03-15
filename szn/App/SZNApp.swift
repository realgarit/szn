import Cocoa

// AppDelegate must be stored statically so it isn't deallocated —
// NSApplication.delegate is a weak reference.
private let appDelegate = AppDelegate()

@main
enum SZNApp {
    static func main() {
        let app = NSApplication.shared
        app.delegate = appDelegate
        app.run()
    }
}
