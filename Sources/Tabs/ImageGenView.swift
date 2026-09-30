import SwiftUI
import PhotosUI

struct ImageGenView: View {
    @EnvironmentObject private var lock: TaskLock

    @State private var prompt = ""
    @State private var pickedItem: PhotosPickerItem? = nil
    @State private var reference: UIImage? = nil
    @State private var running = false
    @State private var progress: Double = 0

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("生图 · 本地离线")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RMTheme.text)
                Spacer()
                if lock.holder == .image {
                    Text("生成中")
                        .font(.system(size: 11))
                        .foregroundStyle(RMTheme.warn)
                }
            }

            PhotosPicker(selection: $pickedItem, matching: .images) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(RMTheme.surface, lineWidth: 1)
                        .frame(height: 150)
                    if let img = reference {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 22))
                            Text("上传参考图（可选）").font(.system(size: 12))
                        }
                        .foregroundStyle(RMTheme.textSub)
                    }
                }
            }
            .onChange(of: pickedItem) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { return }
                    reference = img
                }
            }

            TextField("描述想生成的画面…", text: $prompt, axis: .vertical)
                .font(.system(size: 13))
                .foregroundStyle(RMTheme.text)
                .lineLimit(3...6)
                .padding(11)
                .background(RMTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if running {
                ProgressView(value: progress)
                    .tint(RMTheme.accent)
            }

            Button { start() } label: {
                Text(running ? "生成中…" : "开始生成")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: 0x0B1F1B))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(running ? RMTheme.textSub : RMTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(running)

            Spacer()
        }
        .padding(14)
        .background(RMTheme.bg)
    }

    private func start() {
        // 与对话互斥
        guard lock.acquire(.image) else { return }
        running = true
        progress = 0
        // TODO: 接 ml-stable-diffusion（Core ML / Neural Engine，本地离线，允许慢）
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
            progress += 0.05
            if progress >= 1 {
                t.invalidate()
                running = false
                lock.release(.image)
            }
        }
    }
}
