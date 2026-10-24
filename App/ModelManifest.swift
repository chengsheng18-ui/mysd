//
//  ModelManifest.swift
//  Which model bundle to download, and how much RAM the device needs.
//

import Foundation

struct ModelFile: Identifiable, Hashable {
    var id: String { filename }
    let filename: String
    let repo: String
    let remotePath: String
    let bytes: Int64
    /// Which Engine slot this file fills.
    let role: Role

    enum Role: String { case diffusion, vae, textEncoder, tae }

    var downloadURL: URL {
        // Byte-identical mirror of huggingface.co. Use the HF host directly if
        // you already have it in your region — same paths, same files.
        URL(string: "\(ModelManifest.host)/\(repo)/resolve/main/\(remotePath)")!
    }
}

enum ModelManifest {

    /// Mirror used for downloads. Swap to "https://huggingface.co" where reachable.
    static let host = "https://hf-mirror.com"

    /// SD 1.5: UNet + CLIP + VAE all inside one GGUF, so a single 1.5 GB
    /// download. The only preset that comfortably fits a 6 GB iPhone with the
    /// stock (non-entitled) ~2-3 GB per-process ceiling.
    static let sd15Files = [
        ModelFile(filename: "sd15-Q4_0.gguf",
                  repo: "second-state/stable-diffusion-v1-5-GGUF",
                  remotePath: "stable-diffusion-v1-5-pruned-emaonly-Q4_0.gguf",
                  bytes: 1_566_700_000,
                  role: .diffusion),
    ]

    // Z-Image-Turbo (S3-DiT, 6B, distilled to ~8 steps).
    // Weights from unsloth's GGUF quant set; VAE is FLUX.2's autoencoder.
    static let zImageTurbo = [
        ModelFile(filename: "z-image-turbo-Q3_K_M.gguf",
                  repo: "unsloth/Z-Image-Turbo-GGUF",
                  remotePath: "z-image-turbo-Q3_K_M.gguf",
                  bytes: 4_186_356_000,
                  role: .diffusion),
        ModelFile(filename: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                  repo: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
                  remotePath: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
                  bytes: 2_497_300_000,
                  role: .textEncoder),
        ModelFile(filename: "ae.safetensors",
                  repo: "black-forest-labs/FLUX.2-small-decoder",
                  remotePath: "full_encoder_small_decoder.safetensors",
                  bytes: 249_600_000,
                  role: .vae),
    ]

    // Leaner preset for 6–8 GB devices: Q2_K transformer + IQ1_S text encoder.
    // Noticeably softer, but it fits inside the ~6 GB ceiling of a stock
    // (non-entitled) 12 GB iPhone.
    static let zImageTurboLean = [
        ModelFile(filename: "z-image-turbo-Q2_K.gguf",
                  repo: "unsloth/Z-Image-Turbo-GGUF",
                  remotePath: "z-image-turbo-Q2_K.gguf",
                  bytes: 3_639_400_000,
                  role: .diffusion),
        ModelFile(filename: "Qwen3-4B-Instruct-2507-UD-IQ1_S.gguf",
                  repo: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
                  remotePath: "Qwen3-4B-Instruct-2507-UD-IQ1_S.gguf",
                  bytes: 1_083_200_000,
                  role: .textEncoder),
        ModelFile(filename: "ae.safetensors",
                  repo: "black-forest-labs/FLUX.2-small-decoder",
                  remotePath: "full_encoder_small_decoder.safetensors",
                  bytes: 249_600_000,
                  role: .vae),
    ]

    enum Preset: String, CaseIterable, Identifiable {
        case sd15, lean, turbo
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sd15:  return "SD 1.5 Q4_0"
            case .lean:  return "Z-Image-Turbo Q2_K"
            case .turbo: return "Z-Image-Turbo Q3_K_M"
            }
        }
        var detail: String {
            switch self {
            case .sd15:  return "1.5 GB · 6 GB 机型唯一可行，512² 20 步"
            case .lean:  return "4.8 GB · 8 GB 机型可试，画质下降"
            case .turbo: return "6.9 GB · 需要 12 GB 机型 + entitlement"
            }
        }
        /// Sampling defaults that match this checkpoint's training.
        var defaults: (size: Int, steps: Int, cfg: Double) {
            switch self {
            case .sd15:  return (512, 20, 7.5)
            case .lean:  return (512, 8, 1.0)
            case .turbo: return (512, 8, 1.0)
            }
        }
        var files: [ModelFile] {
            switch self {
            case .sd15:  return ModelManifest.sd15Files
            case .turbo: return ModelManifest.zImageTurbo
            case .lean:  return ModelManifest.zImageTurboLean
            }
        }
    }

    /// Available bytes before jetsam kills us.
    static func availableMemory() -> Int64 {
        Int64(os_proc_available_memory())
    }
}
