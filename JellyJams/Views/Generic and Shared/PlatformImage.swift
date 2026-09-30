import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: PlatformImage) { self.init(nsImage: platformImage) }
}
#else
import UIKit
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: PlatformImage) { self.init(uiImage: platformImage) }
}
#endif

extension PlatformImage {
    /// Wraps an already-decoded bitmap without copying pixel data. The point
    /// size matches the pixel size: artwork is displayed with `.resizable()`,
    /// which takes its size from the frame rather than the image.
    ///
    /// Distinctly named so it cannot collide with `UIImage`'s own
    /// `init(cgImage:)`: an extension initializer with that exact signature
    /// resolves its own `self.init(cgImage:)` delegation to itself and
    /// recurses forever.
    convenience init(decodedCGImage: CGImage) {
        #if os(macOS)
        self.init(cgImage: decodedCGImage, size: CGSize(width: decodedCGImage.width, height: decodedCGImage.height))
        #else
        self.init(cgImage: decodedCGImage)
        #endif
    }
}
