import Foundation
import SwiftUI

/// Chat 推理与生图互斥锁：同一时刻只允许一个重任务运行，第二个触发时弹窗提示。
final class TaskLock: ObservableObject {
    enum Holder: String {
        case chat
        case image

        var label: String {
            switch self {
            case .chat:  return "对话"
            case .image: return "生图"
            }
        }
    }

    @Published private(set) var holder: Holder? = nil
    @Published var alertMessage: String? = nil

    var isBusy: Bool { holder != nil }

    /// 尝试取得锁。已被其它任务占用时返回 false 并弹提示。
    @discardableResult
    func acquire(_ who: Holder) -> Bool {
        if let current = holder, current != who {
            alertMessage = "\(current.label)正在进行中，无法同时启动\(who.label)。请先停止或等待完成。"
            return false
        }
        holder = who
        return true
    }

    func release(_ who: Holder) {
        if holder == who { holder = nil }
    }
}
