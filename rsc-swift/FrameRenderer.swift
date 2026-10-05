import MetalKit

/// Uploads the software-rendered frames from the game thread into a texture
/// and scales them to fill the view.
final class FrameRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    // rotate textures so we never overwrite one the GPU is still reading
    private var textures: [MTLTexture] = []
    private var textureIndex = 0
    private var lastSerial: UInt64 = 0
    private var frameSize = CGSize.zero
    private let inFlight = DispatchSemaphore(value: 3)

    init?(view: MTKView) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "frame_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "frame_fragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

        let samplerDescriptor = MTLSamplerDescriptor()
        // keep the chunky pixels crisp
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else { return nil }

        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.sampler = sampler
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        inFlight.wait()

        guard uploadLatestFrame(device: view.device!) else {
            inFlight.signal()
            return
        }

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else {
            inFlight.signal()
            return
        }

        encoder.setViewport(viewport(for: view.drawableSize))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(textures[textureIndex], index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commands.present(drawable)
        commands.commit()
    }

    /// Returns false when there is no new frame, so the view keeps showing
    /// the last one without spending GPU time.
    private func uploadLatestFrame(device: MTLDevice) -> Bool {
        var pixels: UnsafePointer<UInt32>?
        var width: Int32 = 0
        var height: Int32 = 0

        let serial = rsc_frame_lock(&pixels, &width, &height)
        defer { rsc_frame_unlock() }

        guard serial != lastSerial, let pixels, width > 0, height > 0 else {
            return false
        }

        lastSerial = serial
        frameSize = CGSize(width: Int(width), height: Int(height))
        textureIndex = (textureIndex + 1) % 3

        if textures.count < 3 || textures[0].width != Int(width)
            || textures[0].height != Int(height)
        {
            textures = (0..<3).compactMap { _ in
                makeTexture(device: device, width: Int(width), height: Int(height))
            }
        }

        textures[textureIndex].replace(
            region: MTLRegionMake2D(0, 0, Int(width), Int(height)),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: Int(width) * 4)

        return true
    }

    /// Aspect-fit the frame, e.g. while loading at a fixed size or when the
    /// game hasn't caught up with a rotation yet.
    private func viewport(for drawableSize: CGSize) -> MTLViewport {
        let scale = min(drawableSize.width / frameSize.width,
                        drawableSize.height / frameSize.height)
        let width = frameSize.width * scale
        let height = frameSize.height * scale

        return MTLViewport(
            originX: Double((drawableSize.width - width) / 2),
            originY: Double((drawableSize.height - height) / 2),
            width: Double(width), height: Double(height),
            znear: 0, zfar: 1)
    }

    private func makeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        // 0x00RRGGBB little endian is BGRA in memory
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}
