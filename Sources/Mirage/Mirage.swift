//
//  Mirage.swift
//  Swift facade over the C ABI exposed by `CMirage`.
//
//  Trimmed to the surface that the shipped sdcpp.xcframework actually
//  exports (10 symbols: ctx_create/free, generate, generate_video,
//  supports_video, free_image, free_video, last_error, version,
//  set_progress_callback). Upstream `main` also wraps upscaling / TTS /
//  tokenizer, but those symbols are absent from every published
//  xcframework release, so referencing them would fail to link.
//

import Foundation
import CoreGraphics
import ImageIO
import CMirage

// MARK: - Top-level namespace

public enum Mirage {

    /// The engine version reported by the embedded native library.
    public static var nativeVersion: String {
        String(cString: mirage_version())
    }

    /// Install a global progress callback fired once per denoising step.
    /// `step` is 1-indexed, `total` is the configured `steps`, `elapsed` is
    /// seconds since the previous step. Invoked on the engine's worker
    /// thread — hop to the main actor before touching view state.
    public static func setProgressCallback(
        _ cb: (@Sendable (_ step: Int, _ total: Int, _ elapsed: TimeInterval) -> Void)?
    ) {
        progressLock.lock()
        progressClosure = cb
        progressLock.unlock()

        if cb != nil {
            mirage_set_progress_callback({ step, total, time, _ in
                progressLock.lock()
                let c = progressClosure
                progressLock.unlock()
                c?(Int(step), Int(total), TimeInterval(time))
            }, nil)
        } else {
            mirage_set_progress_callback(nil, nil)
        }
    }
}

nonisolated(unsafe) private var progressClosure: (@Sendable (Int, Int, TimeInterval) -> Void)?
private let progressLock = NSLock()

// MARK: - Model

public struct ModelFiles: Sendable {
    public var diffusionModel: URL
    public var vae: URL?
    public var textEncoder: URL?
    public var t5Encoder: URL?
    public var taeDecoder: URL?

    public init(diffusionModel: URL, vae: URL? = nil, textEncoder: URL? = nil,
                t5Encoder: URL? = nil, taeDecoder: URL? = nil) {
        self.diffusionModel = diffusionModel
        self.vae = vae
        self.textEncoder = textEncoder
        self.t5Encoder = t5Encoder
        self.taeDecoder = taeDecoder
    }
}

// MARK: - Generation request

public struct GenerationRequest: Sendable {
    public var prompt: String
    public var negativePrompt: String?
    public var width: Int = 1024
    public var height: Int = 1024
    public var steps: Int = 9
    public var cfgScale: Float = 1.0
    public var seed: Int64? = nil

    public init(
        prompt: String,
        negativePrompt: String? = nil,
        width: Int = 1024,
        height: Int = 1024,
        steps: Int = 9,
        cfgScale: Float = 1.0,
        seed: Int64? = nil
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.cfgScale = cfgScale
        self.seed = seed
    }
}

// MARK: - Video generation request

public struct VideoGenerationRequest: Sendable {
    public var prompt: String
    public var negativePrompt: String?
    public var width: Int = 480
    public var height: Int = 320
    public var frames: Int = 13
    public var steps: Int = 20
    public var cfgScale: Float = 6.0
    public var flowShift: Float = 3.0
    public var seed: Int64? = nil
    public var initImage: CGImage? = nil
    public var vaeTiling: Bool = true
    public var vaeTileSize: Int = 0

    public init(
        prompt: String,
        negativePrompt: String? = nil,
        width: Int = 480,
        height: Int = 320,
        frames: Int = 13,
        steps: Int = 20,
        cfgScale: Float = 6.0,
        flowShift: Float = 3.0,
        seed: Int64? = nil,
        initImage: CGImage? = nil,
        vaeTiling: Bool = true,
        vaeTileSize: Int = 0
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.frames = frames
        self.steps = steps
        self.cfgScale = cfgScale
        self.flowShift = flowShift
        self.seed = seed
        self.initImage = initImage
        self.vaeTiling = vaeTiling
        self.vaeTileSize = vaeTileSize
    }
}

public struct GeneratedVideo: Sendable {
    public let width: Int
    public let height: Int
    public let frames: [CGImage]

    public init(width: Int, height: Int, frames: [CGImage]) {
        self.width = width
        self.height = height
        self.frames = frames
    }
}

// MARK: - Errors

public enum MirageError: Error, CustomStringConvertible, Sendable {
    case modelLoadFailed(String)
    case generationFailed(String)
    case invalidNativeImage(String)
    case cgImageCreationFailed
    case videoUnsupported

    public var description: String {
        switch self {
        case .modelLoadFailed(let s):    return "model load failed — \(s)"
        case .generationFailed(let s):   return "generation failed — \(s)"
        case .invalidNativeImage(let s): return "native image invalid — \(s)"
        case .cgImageCreationFailed:     return "failed to build CGImage from pixel buffer"
        case .videoUnsupported:          return "loaded model does not support video generation"
        }
    }
}

// MARK: - Engine

public actor Engine {

    private let ctx: OpaquePointer

    public init(models: ModelFiles) throws {
        let diffusion = models.diffusionModel.path
        let vae = models.vae?.path
        let llm = models.textEncoder?.path
        let t5 = models.t5Encoder?.path
        let tae = models.taeDecoder?.path

        func withOptionalCString<T>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            if let s = s { return s.withCString { body($0) } }
            return body(nil)
        }

        let result: OpaquePointer? = diffusion.withCString { dPtr in
            withOptionalCString(vae) { vPtr in
                withOptionalCString(llm) { lPtr in
                    withOptionalCString(t5) { tPtr in
                        withOptionalCString(tae) { taePtr in
                            var paths = mirage_model_paths(
                                diffusion_model_path: dPtr,
                                vae_path: vPtr,
                                llm_path: lPtr,
                                t5xxl_path: tPtr,
                                taesd_path: taePtr
                            )
                            return withUnsafePointer(to: &paths) { pp -> OpaquePointer? in
                                mirage_ctx_create(pp)
                            }
                        }
                    }
                }
            }
        }

        guard let ctx = result else {
            throw MirageError.modelLoadFailed(Self.lastNativeError())
        }
        self.ctx = ctx
    }

    deinit {
        mirage_ctx_free(ctx)
    }

    public func generate(_ request: GenerationRequest) async throws -> CGImage {
        let promptHolder = request.prompt
        let negHolder = request.negativePrompt ?? ""
        let ctx = self.ctx

        let imgPtr: UnsafeMutablePointer<mirage_image>? = promptHolder.withCString { pPtr in
            negHolder.withCString { nPtr in
                var params = mirage_gen_params(
                    prompt: pPtr,
                    negative_prompt: request.negativePrompt == nil ? nil : nPtr,
                    width: Int32(request.width),
                    height: Int32(request.height),
                    steps: Int32(request.steps),
                    cfg_scale: request.cfgScale,
                    seed: request.seed ?? -1,
                    batch_size: 1
                )
                return withUnsafePointer(to: &params) { pp in
                    mirage_generate(ctx, pp)
                }
            }
        }

        guard let imgPtr = imgPtr else {
            throw MirageError.generationFailed(Self.lastNativeError())
        }
        defer { mirage_free_image(imgPtr) }

        let img = imgPtr.pointee
        guard img.width > 0, img.height > 0, img.channels == 4 || img.channels == 3 else {
            throw MirageError.invalidNativeImage(
                "got width=\(img.width) height=\(img.height) channels=\(img.channels)"
            )
        }
        guard let cg = Self.makeCGImage(from: img) else {
            throw MirageError.cgImageCreationFailed
        }
        return cg
    }

    public var supportsVideo: Bool {
        mirage_supports_video(ctx)
    }

    public func generateVideo(_ request: VideoGenerationRequest) async throws -> GeneratedVideo {
        guard mirage_supports_video(ctx) else { throw MirageError.videoUnsupported }

        let promptHolder = request.prompt
        let negHolder = request.negativePrompt ?? ""
        let ctx = self.ctx

        var initPixels: [UInt8]? = nil
        var initW: Int32 = 0
        var initH: Int32 = 0
        if let cg = request.initImage, let rgb = Self.makeRGB8(from: cg) {
            initPixels = rgb
            initW = Int32(cg.width)
            initH = Int32(cg.height)
        }

        let videoPtr: UnsafeMutablePointer<mirage_video>? = promptHolder.withCString { pPtr in
            negHolder.withCString { nPtr -> UnsafeMutablePointer<mirage_video>? in
                func run(_ ip: UnsafePointer<UInt8>?) -> UnsafeMutablePointer<mirage_video>? {
                    var params = mirage_video_params(
                        prompt: pPtr,
                        negative_prompt: request.negativePrompt == nil ? nil : nPtr,
                        width: Int32(request.width),
                        height: Int32(request.height),
                        frames: Int32(request.frames),
                        steps: Int32(request.steps),
                        cfg_scale: request.cfgScale,
                        flow_shift: request.flowShift,
                        seed: request.seed ?? -1,
                        init_image_pixels: ip,
                        init_image_width: initW,
                        init_image_height: initH,
                        vae_tiling: request.vaeTiling,
                        vae_tile_size: Int32(request.vaeTileSize)
                    )
                    return withUnsafePointer(to: &params) { pp in
                        mirage_generate_video(ctx, pp)
                    }
                }
                if let pixels = initPixels {
                    return pixels.withUnsafeBufferPointer { buf in run(buf.baseAddress) }
                }
                return run(nil)
            }
        }

        guard let videoPtr = videoPtr else {
            throw MirageError.generationFailed(Self.lastNativeError())
        }
        defer { mirage_free_video(videoPtr) }

        let v = videoPtr.pointee
        guard v.width > 0, v.height > 0, v.frame_count > 0, v.channels == 3 || v.channels == 4 else {
            throw MirageError.invalidNativeImage(
                "video w=\(v.width) h=\(v.height) ch=\(v.channels) frames=\(v.frame_count)"
            )
        }

        let w = Int(v.width), h = Int(v.height), c = Int(v.channels)
        let frameStr = w * h * c
        var frames: [CGImage] = []
        frames.reserveCapacity(Int(v.frame_count))
        for i in 0..<Int(v.frame_count) {
            guard let base = v.pixels?.advanced(by: i * frameStr) else { break }
            var img = mirage_image(width: v.width, height: v.height, channels: v.channels, pixels: base)
            if let cg = withUnsafePointer(to: &img, { Self.makeCGImage(from: $0.pointee) }) {
                frames.append(cg)
            }
        }
        return GeneratedVideo(width: w, height: h, frames: frames)
    }

    // MARK: - Diagnostics

    /// Last error string from the native side.
    public static func lastNativeError() -> String {
        guard let cstr = mirage_last_error() else { return "(no error message)" }
        let s = String(cString: cstr)
        return s.isEmpty ? "(no error message)" : s
    }

    // MARK: - Pixel conversion

    private static func makeRGB8(from cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 3)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.none.rawValue
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 3,
                                      space: cs, bitmapInfo: info) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }

    private static func makeCGImage(from img: mirage_image) -> CGImage? {
        let w = Int(img.width)
        let h = Int(img.height)
        let c = Int(img.channels)
        guard w > 0, h > 0, c == 3 || c == 4, let pixels = img.pixels else { return nil }
        let bytesPerRow = w * c
        guard let data = CFDataCreate(nil, pixels, bytesPerRow * h) else { return nil }
        guard let provider = CGDataProvider(data: data) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = c == 4
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: c * 8,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

// MARK: - CGImage helpers

public extension CGImage {
    func pngData() -> Data? {
        guard let cf = CFDataCreateMutable(nil, 0) else { return nil }
        guard let dest = CGImageDestinationCreateWithData(cf, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, self, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return cf as Data
    }
}
