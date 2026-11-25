import AppKit
import SwiftUI

/// Renders identity metadata produced by MimacIdentity. App bundle icons remain
/// the first choice; this view handles CLI brands and semantic system symbols.
struct ToolIdentityIcon: View {
    let name: String

    private static let cache = NSCache<NSString, NSImage>()
    private static let templateAssets: Set<String> = ["nextdotjs"]

    @ViewBuilder
    var body: some View {
        if name.hasPrefix("sf:") {
            Image(systemName: String(name.dropFirst(3)))
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkDim)
        } else if let image = image {
            if Self.templateAssets.contains(name) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Theme.ink)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            }
        } else {
            Image(systemName: "command")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkDim)
        }
    }

    private var image: NSImage? {
        if let cached = Self.cache.object(forKey: name as NSString) { return cached }
        let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "ToolIcons")
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        Self.cache.setObject(image, forKey: name as NSString)
        return image
    }
}
