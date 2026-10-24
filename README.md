# 本机出图 — iPhone 本地跑 sd.cpp 出图

一个不依赖任何现成出图 App 的 iOS 工程：把 [`stable-diffusion.cpp`](https://github.com/leejet/stable-diffusion.cpp)
+ ggml-Metal 通过 [Mirage](https://github.com/haplollc/Mirage) 的预编译 xcframework 嵌进来，
用 SwiftUI 做前端，GitHub Actions 云编译出 `.ipa`。

```
提示词 → Qwen3-4B 文本编码 → Z-Image-Turbo DiT (Metal) → AE 解码 → PNG
```

## 先说清楚三件事（别踩坑）

1. **机型决定了你能跑什么。**
   - **6 GB 机型（iPhone 14/15 及更早）**：默认预设是 **SD 1.5 Q4_0，1.5 GB**，单文件、
     CLIP/VAE 全内置，512² 20 步。这是这一档唯一现实的选择。
   - **8 GB 机型**：可以试 Z-Image-Turbo Q2_K（4.8 GB），画质明显下降。
   - **12 GB 机型 + 付费账号**：Z-Image-Turbo Q3_K_M（6.9 GB）才谈得上「现代模型」的质量。

   普通 App 的 jetsam 上限只有 2–3 GB；`com.apple.developer.kernel.increased-memory-limit`
   能放开到 ~10 GB，但它**只对付费账号（$99/年）签发的 profile 生效**。
2. **不要在 iSH 里编译。** iSH 是 x86 用户态模拟，跑 Metal 驱动不了 GPU，内存也顶不住。
   这个工程的所有构建都在 GitHub 的 macOS runner 上完成，手机只负责点按钮。
3. **出图很慢。** 512² / 8 步在 A19 上约 30–60 秒；1024² / 8 步约 3–5 分钟。
   这不是 bug，是 6B 模型在手机上的真实速度。

## 目录

| 路径 | 说明 |
|---|---|
| `App/` | SwiftUI 前端：下载、加载、出图、进度、保存 |
| `App/ModelManifest.swift` | 两套模型预设的下载清单与体积 |
| `App/Downloader.swift` | 断点续传下载器（写 Application Support/Models） |
| `Sources/Mirage/` | Swift 门面层，只包已发布的 10 个 C 符号 |
| `Sources/CMirage/` | C modulemap + 头文件（与 xcframework 内的字节一致） |
| `Frameworks/` | 预编译 `sdcpp.xcframework`（26 MB，CI 自动下载，不入库） |
| `project.yml` | XcodeGen 描述，生成 `MinisDiffusion.xcodeproj` |
| `scripts/selfcheck.py` | 离线自检：头文件/符号/entitlement/YAML |
| `.github/workflows/build-ipa.yml` | 云编译 + 出包 + artifact |

## 模型

| 预设 | 组成 | 合计 | 适用机型 |
|---|---|---|---|
| `SD 1.5 Q4_0`（默认） | 单文件 GGUF（UNet+CLIP+VAE 内置） | **1.5 GB** | 6 GB 机型，512² / 20 步 / CFG 7.5 |
| `Z-Image-Turbo Q2_K` | DiT 3.47 GB + Qwen3-4B UD-IQ1_S 1.03 GB + AE 0.24 GB | **4.8 GB** | 8 GB 机型可试，画质下降 |
| `Z-Image-Turbo Q3_K_M` | DiT 3.99 GB + Qwen3-4B Q4_K_M 2.38 GB + AE 0.24 GB | **6.9 GB** | 12 GB 机型 + entitlement |

VAE 用 FLUX.2 的 `full_encoder_small_decoder.safetensors`（238 MB），比原版 `ae.safetensors`
（336 MB）省内存，Mirage 的 iPhone 目标就是用的小解码器。

下载源默认走 `hf-mirror.com`（与 huggingface.co 字节一致）。在国内网络下 huggingface.co 直连基本不通，
要换回官方源改 `ModelManifest.host` 即可。

## 构建

### 1. 上传仓库

```sh
git init && git add . && git commit -m "init"
git remote add origin git@github.com:<你>/<仓库>.git
git push -u origin main
```

`Frameworks/sdcpp.xcframework` 在 `.gitignore` 里 —— CI 会自己下载固定版本
`sdcpp-2026-08-27`（**不要**换成 `0.2.0`：那个 tag 的二进制缺少 `supports_video` /
`generate_video` 符号，虽然 App 只出图也用得上其中的稳定修复）。

### 2. 让它编译

push 之后 Actions 里的 `build-ipa` 会自动跑，产物在 **Artifacts → MinisDiffusion-ipa**：

- `MinisDiffusion-unsigned.ipa`：交给 AltStore / SideStore / Sideloadly 自签
- `MinisDiffusion-unsigned.app.zip`：直接拖进 Xcode 也行

只编译不签名不需要任何 Apple 账号，所以这一步一定跑得通 —— 先确认能编过，再折腾签名。

### 3. 签名（关键一步）

在仓库 Settings → Secrets 里加：

| Secret | 内容 |
|---|---|
| `APPLE_TEAM_ID` | 10 位 Team ID |
| `BUILD_CERTIFICATE_BASE64` | `.p12` 的 base64 |
| `P12_PASSWORD` | 导出 p12 时设的密码 |
| `PROVISIONING_PROFILE_BASE64` | 给 `dev.minis.diffusion` 手动创建的 Ad Hoc profile |

**在 developer.apple.com 里必须做的一件事**：App ID `dev.minis.diffusion` →
Capabilities → 勾上 **Increased Memory Limit**（以及 Extended Virtual Addressing），
然后重新生成 profile。忘了这步，build 能成功、App 能装，但加载权重时必被杀。

### 4. 装到手机

- **AltStore / SideStore**：ipa 丢进去，用它自己的证书重签。注意 AltStore 免费账号签出来的
  App **没有**内存 entitlement —— 只能用 Q2_K 预设，且 8 GB 以上机型。
- **付费账号 + Ad Hoc**：用第 3 步签好的 ipa，Apple Configurator / Xcode Devices 拖进去。
- **TrollStore**（系统版本合适时）：永久签名，最省事。

## 本地验证（不需要 Mac）

```sh
python3 scripts/selfcheck.py
python3 scripts/check_models.py   # 需要联网，核对 7 个模型文件的真实体积
```

`selfcheck.py` 检查四项：头文件与二进制一致、Swift 调的 C 函数都存在、二进制里真有这些符号、entitlement 齐全。

## 已知限制

- 只做文生图。二进制虽然带 `mirage_generate_video`，但没验证过任何视频模型。
- 上游 `main` 分支的 Swift 层还包了放大（ESRGAN）、TTS、外挂 tokenizer，这些符号
  **在所有已发布的 xcframework 里都不存在**，所以这里把门面层裁到只有这 10 个符号。
- 加载 6.9 GB 权重会吃满磁盘页缓存，第一次生成要额外等 10–40 秒。
- 切换预设会先卸载旧引擎再加载新的（否则两个引擎并存直接 OOM）。

## 许可

本工程代码 MIT。Mirage 为 MIT，stable-diffusion.cpp 为 MIT。
Z-Image-Turbo 权重按其自身许可使用；FLUX.2 组件（AE 解码器）来自 BFL，使用时注意署名要求。
