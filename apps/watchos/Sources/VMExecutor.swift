import Foundation

final class VMExecutor {
    static let shared = VMExecutor()

    private var vmThread: VMThread?
    private var timer: DispatchSourceTimer?

    private init() {}

    func start(bootSource: String, onResult: @escaping (String) -> Void) {
        guard vmThread == nil else { return }
        let t = VMThread(bootSource: bootSource, executor: self, onReady: onResult)
        t.stackSize = 4 * 1024 * 1024
        vmThread = t
        t.start()
    }

    func call(_ method: String, _ arg: String, onResult: @escaping (String) -> Void) {
        guard let thread = vmThread else {
            DispatchQueue.main.async { onResult("(VM not ready)") }
            return
        }
        thread.enqueue {
            guard let vm = thread.vm else {
                DispatchQueue.main.async { onResult("(VM not ready)") }
                return
            }
            let out = method.withCString { m in
                arg.withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            NSLog("[WatchStackchan] %@(%@) ->\n%@", method, arg, result)
            DispatchQueue.main.async { onResult(result) }
        }
    }

    func runTrial(_ spec: String) {
        let lines = spec.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.isEmpty { finishTrial() }
        for (i, line) in lines.enumerated() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            call(parts[0], parts.count > 1 ? parts[1] : "") { result in
                for out in result.split(separator: "\n", omittingEmptySubsequences: true) {
                    print("[trial] \(out)")
                }
                fflush(stdout)
                if i == lines.count - 1 { self.finishTrial() }
            }
        }
    }

    private func finishTrial() {
        print("[trial] end")
        fflush(stdout)
        exit(0)
    }

    fileprivate func startTick() {
        guard let thread = vmThread else { return }
        let t = DispatchSource.makeTimerSource(queue: thread.workQueue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler {
            guard let vm = thread.vm else { return }
            let out = "tick".withCString { m in
                "".withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            if !result.isEmpty { NSLog("[WatchStackchan] tick ->\n%@", result) }
        }
        t.resume()
        self.timer = t
    }
}

final class VMThread: Thread {
    var vm: UnsafeMutableRawPointer?
    let workQueue: DispatchQueue

    private let bootSource: String
    private weak var executor: VMExecutor?
    private let onReady: (String) -> Void

    init(bootSource: String, executor: VMExecutor, onReady: @escaping (String) -> Void) {
        self.bootSource = bootSource
        self.executor = executor
        self.onReady = onReady
        self.workQueue = DispatchQueue(label: "com.bash0c7.watchstackchan.vm")
        super.init()
    }

    func enqueue(_ work: @escaping () -> Void) {
        workQueue.async(execute: work)
    }

    override func main() {
        NSLog("[WatchStackchan] VMThread starting (stack: 4MB)")
        guard let handle = bootSource.withCString({ vm_open($0) }) else {
            NSLog("[WatchStackchan] vm_open returned NULL (app.rb failed to load)")
            DispatchQueue.main.async { self.onReady("(VM failed to start)") }
            return
        }
        workQueue.sync { self.vm = handle }
        NSLog("[WatchStackchan] VM opened")
        DispatchQueue.main.async { self.onReady("VM ready") }
        executor?.startTick()
        RunLoop.current.run()
    }
}
