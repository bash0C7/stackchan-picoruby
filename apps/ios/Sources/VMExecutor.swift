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

    func call(_ method: String, _ arg: String, onResult: @escaping (String) -> Void) {
        queue.async {
            guard let vm = self.vm else {
                DispatchQueue.main.async { onResult("(VM not ready)") }
                return
            }
            let out = method.withCString { m in
                arg.withCString { a in
                    vm_call(vm, m, a)
                }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            NSLog("[Stackchan] %@(%@) ->\n%@", method, arg, result)
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

    private func startTick() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self = self, let vm = self.vm else { return }
            let out = "tick".withCString { m in
                "".withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            if !result.isEmpty { NSLog("[Stackchan] tick ->\n%@", result) }
        }
        t.resume()
        self.timer = t
    }
}
