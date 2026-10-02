import SwiftUI
import PhotosUI

struct ImageGenView: View {
    @EnvironmentObject private var lock: TaskLock
    @EnvironmentObject private var store: ModelStore

    @State private var prompt = ""
    @State private var running = false
    @State private var stage = ""
    @State private var progress: Double = 0
    @State private var seed: UInt64 = UInt64(Date().timeIntervalSince1970)
    @State private var styleIdx = 0
    @State private var paletteIdx = 0
    @State private var sizeIdx = 1
    @State private var photoItem: PhotosPickerItem?
    @State private var reference: UIImage?
    /// ⚠️ 结果存成带稳定 id 的元组：老写法用 Array offset 当 id，
    /// 插入/淘汰后所有 id 平移，SwiftUI 的 diff 会失控（这是弹层和列表一起崩的帮凶）。
    @State private var results: [RMPic] = []
    @State private var previewItem: LoadedImage?
    @State private var note = ""
    /// 当前这张的取消开关（点「生成中…点停止」就掐掉）
    @State private var cancelJob: RMCancelToken? = nil

    private let sizes = [384, 512, 768]

    private var styleName: String { RMBitmap.Style.allCases[styleIdx].name }
    private var paletteName: String { RMBitmap.palettes.keys.sorted()[paletteIdx] }

    /// 生图模型就绪 → 真·模型生图（stable-diffusion.cpp）；没下载 → 程序化涂鸦兜底
    private var useModel: Bool { store.currentImage?.state == .ready }
    private var modelName: String { store.currentImage?.label ?? "SD 1.5" }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 参考图（img2img）：选了就是"在它基础上改"
                    SectionCard(title: "参考图（选了就是在它基础上改进，不选就凭种子生成）") {
                        HStack(spacing: 10) {
                            if let ref = reference {
                                Image(uiImage: ref)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 76, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("已选参考图")
                                        .font(.system(size: 12))
                                        .foregroundStyle(RMTheme.text)
                                    Button("换一张") { photoItem = nil; reference = nil }
                                        .font(.system(size: 11))
                                        .foregroundStyle(RMTheme.warn)
                                }
                                Spacer()
                            } else {
                                PhotosPicker(selection: $photoItem, matching: .images) {
                                    VStack(spacing: 6) {
                                        Image(systemName: "photo.badge.plus")
                                            .font(.system(size: 20))
                                            .foregroundStyle(RMTheme.accent)
                                        Text("从相册选参考图")
                                            .font(.system(size: 11))
                                            .foregroundStyle(RMTheme.textSub)
                                    }
                                    .frame(width: 76, height: 76)
                                    .background(RMTheme.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                Spacer()
                            }
                        }
                    }

                    SectionCard(title: "提示词（决定构图和配色方向）") {
                        TextField("例如：赛博风格的雨夜城市天际线", text: $prompt, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.system(size: 13))
                            .foregroundStyle(RMTheme.text)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(RMTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    SectionCard(title: "参数") {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("风格").font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                                Menu(styleName) {
                                    ForEach(0..<RMBitmap.Style.allCases.count, id: \.self) { i in
                                        Button(RMBitmap.Style.allCases[i].name) { styleIdx = i }
                                    }
                                }
                                .font(.system(size: 12)).foregroundStyle(RMTheme.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("配色").font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                                Menu(paletteName) {
                                    ForEach(Array(RMBitmap.palettes.keys.sorted().enumerated()), id: \.offset) { i, k in
                                        Button(k) { paletteIdx = i }
                                    }
                                }
                                .font(.system(size: 12)).foregroundStyle(RMTheme.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("尺寸").font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                                Menu("\(sizes[sizeIdx])") {
                                    ForEach(Array(sizes.enumerated()), id: \.offset) { i, s in
                                        Button("\(s) px") { sizeIdx = i }
                                    }
                                }
                                .font(.system(size: 12)).foregroundStyle(RMTheme.accent)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("种子").font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                                HStack(spacing: 6) {
                                    Text(String(seed % 100000))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(RMTheme.text)
                                    Button("随机") { seed = UInt64(Date().timeIntervalSince1970) }
                                        .font(.system(size: 11))
                                        .foregroundStyle(RMTheme.accent)
                                }
                            }
                        }
                    }

                    if running {
                        VStack(spacing: 6) {
                            ProgressView(value: progress)
                                .tint(RMTheme.accent)
                            Text(stage.isEmpty ? "正在本地生成…" : stage)
                                .font(.system(size: 11))
                                .foregroundStyle(RMTheme.textSub)
                        }
                        .padding(12)
                        .background(RMTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(RMTheme.warn)
                    }

                    // 模式状态：让用户知道这次跑的是真模型还是兜底涂鸦
                    Text(useModel
                         ? "模式：模型生图 · \(modelName) · \(RMSDEngine.sdPlan(budgetGB: DeviceProfile.shared.budgetGB).maxSteps) 步 · 真扩散模型，\(sizes[sizeIdx] > RMSDEngine.sdPlan(budgetGB: DeviceProfile.shared.budgetGB).maxSize ? "尺寸已按内存预算自动降" : "稍慢请耐心")"
                         : "模式：程序化涂鸦（兜底）· 生图模型未下载，去「库 → 生图模型」下载 SD 1.5（1.6GB）")
                        .font(.system(size: 10))
                        .foregroundStyle(RMTheme.textSub)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // 生成按钮
                    Button {
                        generate()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: running ? "stop.fill" : "wand.and.stars")
                            Text(running ? "生成中…点停止" : (useModel ? "模型生成" : "本地生成"))
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(running ? RMTheme.danger : Color(hex: 0x0B1F1B))
                        .background(running ? RMTheme.surface : RMTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    // ⚠️ 老版这里 .disabled(running)，生成中按钮点不动 → 「点停止」永远是死按钮。
                    // 现在生成中点击 = 停止（generate() 里有 running 分支）。

                    // 出图结果
                    if !results.isEmpty {
                        SectionCard(title: "出图结果（\(results.count) 张，点开看大图）") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(results) { pic in
                                        Button { previewItem = LoadedImage(img: pic.img) } label: {
                                            Image(uiImage: pic.img)
                                                .resizable()
                                                .scaledToFill()
                                                .frame(width: 96, height: 96)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .stroke(RMTheme.accent, lineWidth: 1))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text("全程离线：不联网、不下载模型权重，图在本地算出来。真 Stable Diffusion 的 Core ML 权重要另外 1.5 GB，目前这版是「参考图改进 + 程序化生成」。")
                        .font(.system(size: 10))
                        .foregroundStyle(RMTheme.textSub)
                }
                .padding(12)
            }
        }
        .background(RMTheme.bg)
        .sheet(item: $previewItem) { item in ImagePreviewSheet(img: item.img) }
        .onChange(of: photoItem) { item in
            guard let item = item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                guard let data = data, let img = UIImage(data: data) else { return }
                DispatchQueue.main.async { self.reference = img; self.photoItem = nil }
            }
        }
    }


    // MARK: - 生成

    private func generate() {
        if running {
            if useModel {
                // 模型模式：让 sd 库内部安全取消，running 保持 true 等 onDone 收尾，
                // 防止取消还没生效就又点「生成」开第二张（同一个 ctx 会乱）
                RMSDEngine.shared.cancel()
                note = "停止中…"
                return
            }
            // 涂鸦模式：掐掉当前这张，界面立刻恢复
            cancelJob?.cancel()
            cancelJob = nil
            running = false
            progress = 0
            stage = ""
            note = "已停止"
            return
        }
        guard lock.acquire(.image) else { return }

        let ref = reference
        let st = RMBitmap.Style.allCases[styleIdx]
        let pal = RMBitmap.palettes.keys.sorted()[paletteIdx]
        let seq = results.count + 1

        let token = RMCancelToken()
        cancelJob = token
        // ⚠️ 只有主线程能读写这几个 @State；后台线程一律只干活、不碰界面
        running = true
        note = ""
        progress = 0.02
        stage = (reference != nil ? "读取参考图…" : "准备本地管线…")

        if useModel {
            generateWithModel(seq: seq, ref: ref)
        } else {
            generateProcedural(st: st, pal: pal, seq: seq, ref: ref, token: token)
        }
    }

    // MARK: - 真·模型生图（stable-diffusion.cpp）

    private func generateWithModel(seq: Int, ref: UIImage?) {
        guard let m = store.currentImage, m.state == .ready else {
            running = false; progress = 0; stage = ""
            note = "生图模型未就绪"; lock.release(.image)
            return
        }
        let raw = sizes[sizeIdx] > 512 ? 512 : sizes[sizeIdx]   // 768 在 4GB 设备太重，钉死 ≤512
        // ⚠️ 内存预算真正生效：按「性能」页的预算推导安全尺寸/步数，夹到上限以内
        let plan = RMSDEngine.sdPlan(budgetGB: DeviceProfile.shared.budgetGB)
        let sd = min(raw, plan.maxSize)
        if !plan.note.isEmpty {
            note = "内存预算紧，已自动调整：\(plan.note)"
        }
        // ⚠️ 内存纪律：聊天模型必须先卸载（两者不能同时进内存）；聊天页发消息会自动重新加载
        LlamaEngine.shared.unload()
        RMTrace.shared.log("生图(模型)开始 model=\(m.id) size=\(sd) steps=\(plan.maxSteps) ref=\(ref != nil) seed=\(seed) 预算=\(String(format: "%.1f", DeviceProfile.shared.budgetGB))GB", tag: "image")

        RMSDEngine.shared.generate(
            modelPath: store.localPath(for: m),
            prompt: prompt,
            negative: "blurry, low quality, watermark, text, deformed",
            reference: ref,
            size: sd, steps: plan.maxSteps, cfg: 7.0, seed: seed,
            onProgress: { p, s in
                self.progress = p
                self.stage = s
            },
            onDone: { img, err in
                self.running = false
                self.progress = 0
                self.stage = ""
                if let img {
                    self.results.insert(RMPic(img: img), at: 0)
                    if self.results.count > 6 { self.results.removeLast() }
                    if let d = img.pngData() {
                        FileStore.shared.writeData(name: "studio/rmind-\(self.seed % 100000)-v\(seq).png", data: d)
                    }
                    self.seed = UInt64(Date().timeIntervalSince1970)   // 下张换种子，别连出一样的
                } else {
                    self.note = err
                }
                self.lock.release(.image)
            })
    }

    // MARK: - 程序化涂鸦（兜底，模型没下载时）

    private func generateProcedural(st: RMBitmap.Style, pal: String, seq: Int, ref: UIImage?, token: RMCancelToken) {
        let sz = sizes[sizeIdx]
        let sd = seed

        let job = RMPixelJob(opt: RMPixelJob.Opt(size: sz, seed: sd, style: st,
                                                 paletteName: pal, reference: ref))
        RMTrace.shared.log("生图开始 size=\(sz) style=\(st) pal=\(pal) ref=\(ref != nil) seed=\(sd)", tag: "image")
        DispatchQueue.global(qos: .userInitiated).async {
            var finished: UIImage? = nil
            var ticks = 0
            // 分片出图：算一小片 → 回报一次进度 → 让出一次线程（界面不会像卡死，也随时能停）
            while job.step(rows: 8) {
                if token.isCancelled { break }
                ticks += 1
                if ticks % 2 == 0 {
                    let pct = job.progress
                    DispatchQueue.main.async {
                        self.progress = 0.02 + 0.75 * pct
                        self.stage = "生成像素…\(Int(pct * 100))%"
                    }
                }
                Thread.sleep(forTimeInterval: 0.012)
            }
            // 崩过 3 次的活儿：每一步都留痕，真崩了至少知道死在 step 还是 makeImage
            RMTrace.shared.log("像素循环结束 ticks=\(ticks) cancelled=\(token.isCancelled)", tag: "image")
            if !token.isCancelled {
                finished = job.makeImage()
                RMTrace.shared.log("makeImage 完成 img=\(finished != nil)", tag: "image")
            }
            let out = finished
            let cancelled = token.isCancelled
            // ⚠️ pngData() 很贵，放到后台编；主线程只负责把图塞进列表，别再拖时间
            let png = out?.pngData()
            DispatchQueue.main.async {
                self.running = false
                self.progress = 0
                self.stage = ""
                if let out, !cancelled {
                    self.results.insert(RMPic(img: out), at: 0)
                    // 结果别无限堆（内存大头），留最近 6 张
                    if self.results.count > 6 { self.results.removeLast() }
                    if let d = png {
                        FileStore.shared.writeData(name: "studio/rmind-\(sd % 100000)-v\(seq).png", data: d)
                    }
                } else if cancelled {
                    self.note = "已停止（没保存这张）"
                } else {
                    self.note = "这次没生成出来：换个种子或换小尺寸（384）再试"
                }
                self.lock.release(.image)
            }
        }
    }
}

// MARK: - 预览弹层

/// 一张出图结果（带自己的 id，别用数组下标）
struct RMPic: Identifiable {
    let img: UIImage
    let id = UUID()
}

struct LoadedImage: Identifiable {
    let img: UIImage
    /// ⚠️ 必须存一份 id：老写法 `var id: UUID { UUID() }` 每次取值都是新 UUID，
    /// SwiftUI 的 .sheet(item:) 认不出同一个 item，会一直重建弹层 → 崩。
    let id = UUID()
}

struct ImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let img: UIImage
    @State private var shareItems: [Any] = []
    /// ⚠️ pngData() 很贵（512×512 编码一次几十毫秒），老版调了三遍，又卡又吃内存。只编一次。
    @State private var png: Data?

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Group {
                    if let png, let ui = UIImage(data: png) {
                        Image(uiImage: ui).resizable().scaledToFit().padding(12)
                    } else {
                        Image(uiImage: img).resizable().scaledToFit().padding(12)
                            .onAppear { png = img.pngData() }
                    }
                }
                HStack(spacing: 14) {
                    Button {
                        if let png { shareItems = [png] }
                    } label: { Label("分享", systemImage: "square.and.arrow.up") }
                    Button {
                        if let d = img.pngData() {
                            FileStore.shared.writeData(name: "studio/save-\(Date().timeIntervalSince1970).png", data: d)
                        }
                    } label: { Label("存入工作空间", systemImage: "folder") }
                    Button("关闭") { dismiss() }
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 16)
            }
            .background(RMTheme.bg)
            .navigationTitle("出图预览")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: Binding(get: { !shareItems.isEmpty }, set: { v in if !v { shareItems = [] } })) {
                ShareSheet(items: shareItems)
            }
        }
    }
}

// MARK: - 分享（iOS 16 的 ShareLink 对 Data 不好使，直接用系统分享面板）

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - 小卡片

private struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(RMTheme.textSub)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
