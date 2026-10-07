import MetalKit
import UIKit

/// Shows the frames the game draws. Metal is used where available; devices
/// without it (32-bit ones such as the iPad 4) fall back to Core Graphics.
protocol FrameDisplay: UIView {
    /// Stops drawing, e.g. in the background where GPU work isn't allowed.
    var isPaused: Bool { get set }
}

/// Makes the best display this device supports.
func makeFrameDisplay() -> FrameDisplay {
    (MetalFrameView.make() as FrameDisplay?) ?? LayerFrameView()
}

/// Uploads frames to a Metal texture and scales them with nearest filtering.
final class MetalFrameView: MTKView, FrameDisplay {
    private var renderer: FrameRenderer?

    /// nil when the device has no Metal, or the build has no shaders.
    static func make() -> MetalFrameView? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }

        let view = MetalFrameView(frame: .zero, device: device)

        guard let renderer = FrameRenderer(view: view) else { return nil }

        view.renderer = renderer
        view.delegate = renderer
        return view
    }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        preferredFramesPerSecond = 60
        isUserInteractionEnabled = false
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Turns each new frame into a CGImage on a layer. Plenty fast for the
/// client's small software-rendered frames, and works on any iOS device.
final class LayerFrameView: UIView, FrameDisplay {
    private var displayLink: CADisplayLink?
    private var lastSerial: UInt64 = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    var isPaused: Bool {
        get { displayLink?.isPaused ?? true }
        set { displayLink?.isPaused = newValue }
    }

    init() {
        super.init(frame: .zero)

        backgroundColor = .black
        isUserInteractionEnabled = false

        // keep the chunky pixels crisp, and letterbox like the Metal view
        layer.magnificationFilter = .nearest
        layer.contentsGravity = .resizeAspect

        // lives as long as the app, so the link retaining us is fine
        let link = CADisplayLink(target: self, selector: #selector(update))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func update() {
        var pixels: UnsafePointer<UInt32>?
        var width: Int32 = 0
        var height: Int32 = 0

        let serial = rsc_frame_lock(&pixels, &width, &height)

        guard serial != lastSerial, let pixels = pixels, width > 0, height > 0 else {
            rsc_frame_unlock()
            return
        }

        // copy out so the game can keep drawing into its buffer
        let data = Data(bytes: pixels, count: Int(width) * Int(height) * 4)
        rsc_frame_unlock()

        lastSerial = serial

        // 0x00RRGGBB little endian: blue, green, red, then an unused byte
        let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.noneSkipFirst.rawValue)

        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: Int(width), height: Int(height),
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * 4,
                space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }

        layer.contents = image
    }
}
