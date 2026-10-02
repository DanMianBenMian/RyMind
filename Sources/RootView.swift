import SwiftUI

enum RMTab: String, CaseIterable, Identifiable {
    case chat      = "对话"
    case image     = "生图"
    case perf      = "性能"
    case library   = "库"
    case advanced  = "高级"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .chat:     return "bubble.left.and.bubble.right"
        case .image:    return "photo"
        case .perf:     return "gauge"
        case .library:  return "folder"
        // 别用 slider.horizontal.adjustable（iOS 17+ 才在），滑条缺图标在老系统上是空白
        case .advanced: return "sliders.horizontal"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var lock: TaskLock
    @EnvironmentObject private var shortcuts: RMShortcuts
    @State private var tab: RMTab = .chat

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                RMTheme.bg.ignoresSafeArea()
                if landscape {
                    HStack(spacing: 0) {
                        SideRail(tab: $tab).frame(width: 88)
                        content(landscape: landscape)
                    }
                } else {
                    VStack(spacing: 0) {
                        content(landscape: landscape)
                        BottomBar(tab: $tab)
                    }
                }
                // 快捷指令浮层（rymind:// 打开时显示结果 / 生成中）
                if !shortcuts.banner.isEmpty || shortcuts.isBusy {
                    shortcutBanner
                        .allowsHitTesting(false)
                }
            }
        }
        .alert("无法同时进行", isPresented: Binding(
            get: { lock.alertMessage != nil },
            set: { if !$0 { lock.alertMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { lock.alertMessage = nil }
        } message: {
            Text(lock.alertMessage ?? "")
        }
    }

    private var shortcutBanner: some View {
        VStack(spacing: 6) {
            if shortcuts.isBusy {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: RMTheme.accent))
            }
            Text(shortcuts.banner.isEmpty ? "正在生成…（别切走 App）" : shortcuts.banner)
                .font(.system(size: 12))
                .foregroundStyle(RMTheme.text)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(RMTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(RMTheme.accent.opacity(0.55), lineWidth: 1))
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func content(landscape: Bool) -> some View {
        switch tab {
        case .chat:    ChatView(landscape: landscape)
        case .image:   ImageGenView()
        case .perf:     PerfView()
        case .library:  LibraryView()
        case .advanced: AdvancedView()
        }
    }
}

private struct SideRail: View {
    @Binding var tab: RMTab

    var body: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 16)
            ForEach(RMTab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 17))
                        Text(t.rawValue).font(.system(size: 11))
                    }
                    .foregroundStyle(tab == t ? RMTheme.accent : RMTheme.textSub)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(tab == t ? RMTheme.surface : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .background(RMTheme.rail)
    }
}

private struct BottomBar: View {
    @Binding var tab: RMTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RMTab.allCases) { t in
                Button { tab = t } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 16))
                        Text(t.rawValue).font(.system(size: 11))
                    }
                    .foregroundStyle(tab == t ? RMTheme.accent : RMTheme.textSub)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                }
            }
        }
        .background(RMTheme.rail)
    }
}
