import Foundation

final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.stackchan.vm")
    private var vm: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?

    private init() {}

    func start(bootSource: String, onResult: @escaping (String) -> Void) {
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[Stackchan] vm_open returned NULL (app.rb failed to load)")
                onResult("(VM failed to start — app.rb did not load)")
                return
            }
            self.vm = handle
            NSLog("[Stackchan] VM opened")
            onResult("VM ready. Tap Connect to scan for Stack-chan.")
            self.startTick()
        }
    }

    private func invoke(_ vm: UnsafeMutableRawPointer, _ method: String, _ arg: String) -> String {
        let out = method.withCString { m in
            arg.withCString { a in vm_call(vm, m, a) }
        }
        let result = out.map { String(cString: $0) } ?? ""
        if let out = out { free(out) }
        return result
    }

    func call(_ method: String, _ arg: String, onResult: @escaping (String) -> Void) {
        queue.async {
            guard let vm = self.vm else {
                DispatchQueue.main.async { onResult("(VM not ready)") }
                return
            }
            let result = self.invoke(vm, method, arg)
            NSLog("[Stackchan] %@(%@) ->\n%@", method, arg, result)
            DispatchQueue.main.async { onResult(result) }
        }
    }

    func runBatch(_ spec: String) {
        let lines = spec.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.isEmpty { queue.async { self.finishBatch() } }
        for (i, line) in lines.enumerated() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let method = parts[0]
            let arg = parts.count > 1 ? parts[1] : ""
            let last = i == lines.count - 1
            queue.async {
                let result = self.vm.map { self.invoke($0, method, arg) } ?? "(VM not ready)"
                NSLog("[Stackchan] %@(%@) ->\n%@", method, arg, result)
                for out in result.split(separator: "\n", omittingEmptySubsequences: true) {
                    print("[batch] \(out)")
                }
                fflush(stdout)
                if last { self.finishBatch() }
            }
        }
    }

    private func finishBatch() {
        print("[batch] end")
        fflush(stdout)
        exit(0)
    }

    private func startTick() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self = self, let vm = self.vm else { return }
            let result = self.invoke(vm, "tick", "")
            if !result.isEmpty { NSLog("[Stackchan] tick ->\n%@", result) }
        }
        t.resume()
        self.timer = t
    }
}
