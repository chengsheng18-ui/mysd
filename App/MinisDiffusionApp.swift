//
//  MinisDiffusionApp.swift
//  On-device image generation on top of stable-diffusion.cpp (via Mirage).
//

import SwiftUI

@main
struct MinisDiffusionApp: App {

    init() {
        // Must land before any ggml-metal device probe fires. The experimental
        // tensor API is unstable on A19-class iPhones (see Mirage 0.2.0 notes).
        setenv("GGML_METAL_TENSOR_DISABLE", "1", 1)
        setenv("GGML_METAL_FUSION_DISABLE", "1", 1)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
