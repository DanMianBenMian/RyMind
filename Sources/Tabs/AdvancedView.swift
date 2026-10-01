import SwiftUI

/// 「高级」页：温度 / 重复惩罚 / 随机性(top-p) / 输出长度
struct AdvancedView: View {
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
            Section("生成方式") {
                Text("这几个值下一次发消息就生效，不用重启 App。默认让你关掉随机（温度 0），小模型最不容易跑偏；想要发挥再往上调。")
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section("温度（越小越稳，越大越爱瞎编）") {
                Slider(value: $temp, in: 0...1, step: 0.05)
                    .tint(RMTheme.accent)
                Text(temp == 0
                     ? "0.00 · 贪心解码：永远选最可能的词，最稳、最不跑题"
                     : String(format: "%.2f · 有随机性，%.2f 以上小模型开始容易胡说", temp, temp))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section("重复惩罚（越高越不复读）") {
                Slider(value: $pen, in: 0...0.5, step: 0.01)
                    .tint(RMTheme.accent)
                Text(String(format: "%.2f", pen))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section("随机性（top-p，0.9 够用，1 = 不筛）") {
                Slider(value: $topP, in: 0.1...1, step: 0.05)
                    .tint(RMTheme.accent)
                Text(String(format: "%.2f", topP))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section("输出长度（最多吐多少 token）") {
                Slider(value: $maxTok, in: 64...1024, step: 32)
                    .tint(RMTheme.accent)
                Text("\(Int(maxTok)) token（约 \(Int(maxTok) * 2) 个汉字）")
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Section("预设") {
                Button {
                    apply(0, 0.0, 0.9, 256)
                } label: { presetRow("稳", "温度 0 · 不惩罚 · 256 token", current: isPreset(0, 0.0, 0.9, 256)) }
                Button {
                    apply(0.6, 0.10, 0.9, 512)
                } label: { presetRow("均衡", "温度 0.6 · 轻度惩罚 · 512 token", current: isPreset(0.6, 0.10, 0.9, 512)) }
                Button {
                    apply(1.0, 0.20, 0.95, 768)
                } label: { presetRow("发挥", "温度 1.0 · 强惩罚 · 768 token", current: isPreset(1.0, 0.20, 0.95, 768)) }
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

    private func isPreset(_ t: Double, _ p: Double, _ tp: Double, _ m: Int) -> Bool {
        let s = RMSampleStore.load()
        return abs(Double(s.temperature) - t) < 0.001
            && abs(Double(s.repeatPenalty) - p) < 0.001
            && abs(Double(s.topP) - tp) < 0.001
            && Double(s.maxTokens) == Double(m)
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

    private func apply(_ t: Double, _ p: Double, _ tp: Double, _ m: Int) {
        RMSampleStore.save(RMSample(temperature: Float(t), repeatPenalty: Float(p), topP: Float(tp), maxTokens: Int(m)))
        temp = t; pen = p; topP = tp; maxTok = Double(m)
    }
}
