import Foundation

/// 推理崩溃兜底：把 SIGSEGV / SIGBUS / SIGABRT 这类"直接带走进程"的信号用 sigsetjmp 接住，
/// 让上层走错误分支（提示内存不够、自动降档），而不是闪退。
///
/// ⚠️ 只包住**一段**推理代码，包的时候别碰 @State / 别依赖事后继续用那些对象：
/// longjmp 回来之后原栈帧里的临时对象全部被跳过释放，只能立刻走 error 路径。
enum RMGuard {

    private static var installed = false

    static func install() {
        guard !installed else { return }
        rm_guard_install()
        installed = true
    }

    /// true = 正常跑完；false = 中途崩了（被接住，调用方立刻走错误分支）
    static func run(_ body: @escaping () -> Void) -> Bool {
        install()
        let box = UnsafeMutablePointer<(() -> Void)>.allocate(capacity: 1)
        box.initialize(to: body)
        let fn: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ptr in
            guard let ptr = ptr else { return }
            ptr.bindMemory(to: (() -> Void).self, capacity: 1).pointee()
        }
        let tripped = rm_guard_call(fn, box)
        box.deinitialize()
        box.deallocate()
        return tripped == 0
    }
}
