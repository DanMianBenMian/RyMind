import SwiftUI

/// 模型切换器：Chat（LLM）与生图各挂一个，两边都能切自己的模型。
struct ModelPicker: View {
    @EnvironmentObject private var store: ModelStore
    let kind: RMModelKind

    private var current: RMModel? {
        kind == .llm ? store.currentLLM : store.currentImage
    }

    private var list: [RMModel] {
        kind == .llm ? store.llmModels : store.imageModels
    }

    var body: some View {
        Menu {
            ForEach(list) { m in
                Button {
                    _ = store.select(m)
                } label: {
                    if m.state == .ready {
                        Label("\(m.label) · \(m.sizeLabel)",
                              systemImage: current?.id == m.id ? "checkmark" : "circle")
                    } else {
                        Label("\(m.label) · \(m.state.rawValue)", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(m.state != .ready)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kind == .llm ? "cpu" : "photo")
                    .font(.system(size: 10))
                Text(current?.label ?? "未选择模型")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(RMTheme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RMTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
