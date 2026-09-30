import SwiftUI

struct PerfView: View {
    @EnvironmentObject private var device: DeviceProfile

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: columns, spacing: 12) {
                    metricCard("生成速度", value: "18.4", unit: "tok/s")
                    metricCard("内存利用率",
                               value: String(format: "%.0f", device.memoryUsageRatio * 100),
                               unit: "%")
                    metricCard("Metal 加速", value: "已启用", unit: "")
                    metricCard("上下文占用", value: "39", unit: "%")
                }

                budgetCard

                tierCard
            }
            .padding(14)
        }
        .background(RMTheme.bg)
    }

    private func metricCard(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(RMTheme.textSub)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(RMTheme.text)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundStyle(RMTheme.textSub)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("分配内存空间")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RMTheme.text)
                Spacer()
                Text(String(format: "%.1f GB", device.budgetGB))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RMTheme.accent)
            }

            Slider(value: $device.budgetGB, in: 0.5...max(device.totalGB, 0.6), step: 0.1)
                .tint(RMTheme.accent)

            HStack {
                Text("下限 0.5 GB")
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
                Spacer()
                Text(String(format: "推荐 %.1f GB · 默认 %.1f GB",
                            device.recommendedGB, device.recommendedGB))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
                Spacer()
                Text(String(format: "上限 %.1f GB（设备总内存）", device.totalGB))
                    .font(.system(size: 11))
                    .foregroundStyle(RMTheme.textSub)
            }

            Button {
                device.budgetGB = device.recommendedGB
            } label: {
                Text("恢复推荐值")
                    .font(.system(size: 12))
                    .foregroundStyle(RMTheme.accent)
            }
        }
        .padding(14)
        .background(RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var tierCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前推理档位")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RMTheme.text)
            infoRow("量化", device.tier.quant)
            infoRow("实际上下文", "\(device.tier.ctxTokens / 1024)k")
            infoRow("KV 量化", device.tier.kvQuant ? "开（省内存）" : "关")
            infoRow("Metal 层数", "\(device.tier.gpuLayers)")
            infoRow("关键词筛推理", device.tier.requiresKeywordFilter ? "强制开启" : "按需")
        }
        .padding(14)
        .background(RMTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundStyle(RMTheme.textSub)
            Spacer()
            Text(v).font(.system(size: 12)).foregroundStyle(RMTheme.text)
        }
    }
}
