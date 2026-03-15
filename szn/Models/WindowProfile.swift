import Foundation
import CoreGraphics

struct WindowProfile: Codable, Identifiable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    let appName: String
    var size: CGSize
    var position: CGPoint?
    var isEnabled: Bool
    var savePosition: Bool

    var displayName: String {
        appName.isEmpty ? bundleIdentifier : appName
    }
}
