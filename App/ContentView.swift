//
//  ContentView.swift
//  Prompt → image, with model download, memory gating and progress.
//

import SwiftUI
import Mirage

@MainActor
final class GeneratorModel: ObservableObject {
    @Published var engineReady = false
    @Published var busy = false
    @Published var status = ""
    @Published var step = 0
    @Published var totalSteps = 0
    @Published var elapsed: Double = 0
    @Published var image: CGImage?
    @Published var savedURL: URL?

    private var engine: Engine?

    /// Drop the loaded weights so a different preset can be loaded.
    func unload() {
        engine = nil
        engineReady = false
        image = nil
        status = ""
    }

    var availableGB: Double { Double(ModelManifest.availableMemory()) / 1_073_741_824 }

    func load(preset: ModelManifest.Preset) {
        guard !busy else { return }
        busy = true
        status = "正在加载模型（首次需要 10–40 秒）…"
        engineReady = false

        Task.detached(priority: .userInitiated) { [preset, weak self] in
            do {
                var paths: [ModelFile.Role: URL] = [:]
                for f in preset.files {
                    paths[f.role] = Downloader.localURL(for: f)
                }
                let models = ModelFiles(
                    diffusionModel: paths[.diffusion]!,
                    vae: paths[.vae],
                    textEncoder: paths[.textEncoder],
                    taeDecoder: paths[.tae]
                )
                let e = try Engine(models: models)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.engine = e
                    self.engineReady = true
                    self.busy = false
                    self.status = "就绪（引擎 \(Mirage.nativeVersion)）"
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.busy = false
                    self?.status = "加载失败：\(error)"
                }
            }
        }
    }

    func generate(prompt: String, negative: String, width: Int, height: Int,
                  steps: Int, cfg: Float, seed: Int64?) {
        guard let engine, !busy else { return }
        busy = true
        status = "生成中…"
        step = 0
        totalSteps = steps
        savedURL = nil

        Mirage.setProgressCallback { s, t, e in
            Task { @MainActor in
                self.step = s
                self.totalSteps = t
                self.elapsed = e
            }
        }

        Task {
            defer {
                busy = false
                Mirage.setProgressCallback(nil)
            }
            do {
                let req = GenerationRequest(
                    prompt: prompt,
                    negativePrompt: negative.isEmpty ? nil : negative,
                    width: width,
                    height: height,
                    steps: steps,
                    cfgScale: cfg,
                    seed: seed
                )
                let cg = try await engine.generate(req)
                image = cg
                status = "完成"
                if let data = cg.pngData() {
                    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    let url = dir.appendingPathComponent("image-\(Int(Date().timeIntervalSince1970)).png")
                    try? data.write(to: url)
                    savedURL = url
                }
            } catch {
                status = "失败：\(error)"
            }
        }
    }
}

struct ContentView: View {

    private struct TaskKey: Hashable {
        let preset: ModelManifest.Preset
        let token: Int
    }

    @StateObject private var dl = Downloader()
    @StateObject private var gen = GeneratorModel()

    @State private var preset: ModelManifest.Preset = .sd15
    @State private var prompt = "a corgi in a spacesuit on the surface of Mars, photorealistic"
    @State private var negative = ""
    @State private var size = 512
    @State private var steps = 20
    @State private var cfg: Double = 7.5
    @State private var showSettings = false
    /// Bumped after a download finishes so `.task(id:)` re-fires and the
    /// engine loads without the user having to force-quit the app.
    @State private var reloadToken = 0

    private var ready: Bool { Downloader.presetReady(preset) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    preview
                    controls
                }
                .padding()
            }
            .navigationTitle("本机出图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("设置") { showSettings = true }
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .task(id: TaskKey(preset: preset, token: reloadToken)) {
                if ready && !gen.engineReady { gen.load(preset: preset) }
            }
            .onChange(of: dl.progress.finished) { _, done in
                if done && Downloader.presetReady(preset) {
                    gen.engineReady = false
                    reloadToken += 1
                }
            }
        }
    }

    // MARK: Preview

    @ViewBuilder
    private var preview: some View {
        Group {
            if let cg = gen.image {
                Image(decorative: cg, scale: 1)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 8) {
                            Text(ready ? gen.status : "模型未下载")
                                .font(.callout)
                            if !ready {
                                Button("下载模型（\(byteString(preset.files.reduce(0) { $0 + $1.bytes }))）") {
                                    dl.download(preset)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding()
                        .multilineTextAlignment(.center)
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if gen.busy && gen.totalSteps > 0 {
                VStack(spacing: 4) {
                    ProgressView(value: Double(gen.step), total: Double(max(1, gen.totalSteps)))
                    Text("第 \(gen.step)/\(gen.totalSteps) 步 · 上一步 \(String(format: "%.1f", gen.elapsed))s")
                        .font(.caption2).monospacedDigit()
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
            }
        }
        .overlay(alignment: .topLeading) {
            if dl.progress.overall > 0 && dl.progress.overall < 1 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dl.progress.filename).font(.caption2).lineLimit(1)
                    ProgressView(value: dl.progress.overall)
                    Text("\(byteString(dl.progress.received)) / \(byteString(dl.progress.total))")
                        .font(.caption2).monospacedDigit()
                }
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding()
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            TextField("提示词", text: $prompt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            Picker("尺寸", selection: $size) {
                Text("512").tag(512)
                Text("768").tag(768)
                Text("1024").tag(1024)
            }
            .pickerStyle(.segmented)

            HStack {
                Stepper("步数：\(steps)", value: $steps, in: 1...30)
                Spacer()
                Text("CFG \(String(format: "%.1f", cfg))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button {
                gen.generate(prompt: prompt, negative: negative,
                             width: size, height: size, steps: steps,
                             cfg: Float(cfg), seed: nil)
            } label: {
                HStack {
                    if gen.busy { ProgressView().tint(.white) }
                    Text(gen.engineReady ? "生成" : "引擎未就绪").bold()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!gen.engineReady || gen.busy || prompt.isEmpty)

            if let s = gen.savedURL {
                ShareLink(item: s) { Label("保存 / 分享 PNG", systemImage: "square.and.arrow.up") }
                    .font(.callout)
            }

            Text(gen.status.isEmpty ? "可用内存 \(String(format: "%.1f", gen.availableGB)) GB" : gen.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Actions

    /// Switching presets must drop the loaded engine first: keeping a 7 GB
    /// (Z-Image Q3) engine resident while loading the lean one would OOM.
    private func applyPreset(_ p: ModelManifest.Preset) {
        guard p != preset else { showSettings = false; return }
        gen.unload()
        preset = p
        size = p.defaults.size
        steps = p.defaults.steps
        cfg = p.defaults.cfg
        showSettings = false
        // Give ARC a moment to release the old weights before the new load.
        reloadToken += 1
    }

    // MARK: Settings

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("模型") {
                    ForEach(ModelManifest.Preset.allCases) { p in
                        Button {
                            applyPreset(p)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.title)
                                    Text(p.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if p == preset { Image(systemName: "checkmark") }
                                if Downloader.presetReady(p) {
                                    Image(systemName: "internaldrive.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                Section("生成参数") {
                    Stepper("CFG \(String(format: "%.1f", cfg))", value: $cfg, in: 1...9, step: 0.5)
                    TextField("反向提示词", text: $negative, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section("诊断") {
                    LabeledContent("引擎版本", value: Mirage.nativeVersion)
                    LabeledContent("可用内存", value: "\(String(format: "%.1f", gen.availableGB)) GB")
                    LabeledContent("模型占用", value: byteString(Downloader.bytesOnDisk(preset)))
                    Button("清除已下载模型", role: .destructive) {
                        for f in ModelManifest.Preset.allCases.flatMap({ $0.files }) {
                            try? FileManager.default.removeItem(at: Downloader.localURL(for: f))
                        }
                        gen.engineReady = false
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showSettings = false }
                }
            }
        }
    }
}

func byteString(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
