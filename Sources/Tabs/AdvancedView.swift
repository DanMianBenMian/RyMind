import SwiftUI

/// 「高级」页：温度 / 重复惩罚 / 随机性(top-p) / 输出长度
struct AdvancedView: View {
    @EnvironmentObject private var device: DeviceProfile

    @State private var temp: Double
    @State private var pen: Double
    @State private var topP: Double
    @State private var maxTok: Double

    init() {
        let s = RMSampleStore.load()
        _temp = State(initialValue: Double(s.temperature))
        _pen  = State(initialValue: Double(s.repeatPenalty))
        _topP = State(initialValue: Double(s.topP))
        _maxTok = State(initialValue: Double(s.maxTokens))
    }

    var body: some View {
        Form {
            // 「高级」页头图标（侧栏 / 底栏用的 symbol 是 sliders.horizontal）
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(RMTheme.accent)
                            .frame(width: 42, height: 42)
                        Image(systemName: "sliders.horizontal")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Color(hex: 0x0B1F1B))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("高级 · 采样参数").font(.system(size: 14, weight: .medium)).foregroundStyle(RMTheme.text)
                        Text("温度 / 重复惩罚 / 随机性 / 输出长度").font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            Section("生成方式") {
                Text("改完下次发消息立刻生效，不用重启 App。出厂默认就是「发挥」预设（温度 1.0 / 惩罚 0.20 / top-p 0.95 / 768 token）；想要最稳就切到「稳」（温度 0 贪心解码，小模型最不容易跑偏）。")
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section {
                Label("温度（越小越稳，越大越爱瞎编）", systemImage: "thermometer")
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.accent)
                Slider(value: $temp, in: 0...1, step: 0.05)
                    .tint(RMTheme.accent)
                    .onChange(of: temp) { _ in persist() }
                Text(temp == 0
                     ? "0.00 · 贪心解码：永远选最可能的词，最稳、最不跑题"
                     : String(format: "%.2f · 有随机性，%.2f 以上小模型开始容易胡说", temp, temp))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section {
                Label("重复惩罚（越高越不复读）", systemImage: "repeat")
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.accent)
                Slider(value: $pen, in: 0...0.5, step: 0.01)
                    .tint(RMTheme.accent)
                    .onChange(of: pen) { _ in persist() }
                Text(String(format: "%.2f", pen))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section {
                Label("随机性 top-p（0.9 够用，1 = 不筛）", systemImage: "dice")
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.accent)
                Slider(value: $topP, in: 0.1...1, step: 0.05)
                    .tint(RMTheme.accent)
                    .onChange(of: topP) { _ in persist() }
                Text(String(format: "%.2f", topP))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section {
                Label("输出长度（最多吐多少 token）", systemImage: "arrow.right")
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.accent)
                Slider(value: $maxTok, in: 64...1024, step: 32)
                    .tint(RMTheme.accent)
                    .onChange(of: maxTok) { _ in persist() }
                Text("\(Int(maxTok)) token（约 \(Int(maxTok) * 2) 个汉字）")
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section("Metal / GPU 加速（关掉就走纯 CPU，省电省内存但会慢）") {
                Toggle("Metal 加速", isOn: $device.metalEnabled)
                    .tint(RMTheme.accent)
                Text("关掉之后 llama 的 GPU 层数变 0，权重全跑 CPU。下次发消息立刻生效，不用重启。当前档位最多可上 \(device.tier.gpuLayers) 层。")
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section("预设（点了会同时把下面的滑条改掉）") {
                ForEach(RMPreset.all) { p in
                    Button { applyPreset(p) } label: { presetRow(p.name, p.desc, current: isPreset(p)) }
                }
            }

            Section("当前生效") {
                let s = RMSampleStore.load()
                LabeledContent("温度") { Text(String(format: "%.2f", s.temperature)).foregroundStyle(RMTheme.text) }
                LabeledContent("重复惩罚") { Text(String(format: "%.2f", s.repeatPenalty)).foregroundStyle(RMTheme.text) }
                LabeledContent("随机性 top-p") { Text(String(format: "%.2f", s.topP)).foregroundStyle(RMTheme.text) }
                LabeledContent("输出长度") { Text("\(s.maxTokens) token").foregroundStyle(RMTheme.text) }
            }
        }
        .background(RMTheme.bg)
        .navigationTitle("高级")
    }

    private func isPreset(_ p: RMPreset) -> Bool {
        let s = RMSampleStore.load()
        let t = p.sample
        return abs(Double(s.temperature) - Double(t.temperature)) < 0.001
            && abs(Double(s.repeatPenalty) - Double(t.repeatPenalty)) < 0.001
            && abs(Double(s.topP) - Double(t.topP)) < 0.001
            && Double(s.maxTokens) == Double(t.maxTokens)
    }

    private func presetRow(_ name: String, _ desc: String, current: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13)).foregroundStyle(RMTheme.text)
                Text(desc).font(.system(size: 11)).foregroundStyle(RMTheme.textSub)
            }
            Spacer()
            if current { Image(systemName: "checkmark").foregroundStyle(RMTheme.accent) }
        }
    }

    private func applyPreset(_ p: RMPreset) {
        let t = p.sample
        RMSampleStore.save(RMSample(temperature: t.temperature,
                                    repeatPenalty: t.repeatPenalty,
                                    topP: t.topP,
                                    maxTokens: t.maxTokens))
        temp = Double(t.temperature); pen = Double(t.repeatPenalty)
        topP = Double(t.topP); maxTok = Double(t.maxTokens)
    }

    // ⚠️ 之前四个滑条只改了 @State，**从来没写回 RMSampleStore**，
    // 所以每次进页面都是上次的预设值 —— 这就是"调了参数还是用预设"的 bug。现在一改就存。
    private func persist() {
        RMSampleStore.save(RMSample(temperature: Float(temp),
                                    repeatPenalty: Float(pen),
                                    topP: Float(topP),
                                    maxTokens: Int(maxTok)))
    }
}
