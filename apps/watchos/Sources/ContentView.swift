import SwiftUI

struct AppAction: Identifiable {
    let name: String
    let label: String
    var id: String { name }

    static func parse(_ listing: String) -> [AppAction] {
        listing.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] != "connect", parts[0] != "stop" else { return nil }
            return AppAction(name: parts[0], label: parts[1])
        }
    }
}

struct ContentView: View {
    @State private var status: String = "Starting VM…"
    @State private var connected: Bool = false
    @State private var busy: Bool = false
    @State private var actions: [AppAction] = []

    var body: some View {
        List {
            Button(action: connect) {
                HStack {
                    Text("🔗").font(.title2)
                    Text("つなぐ")
                }
            }
            .disabled(busy)

            ForEach(actions) { action in
                Button(action.label) { send(action.name) }
                    .disabled(busy)
            }

            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear { boot() }
    }

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            status = "could not read app.rb"
            return
        }
        VMExecutor.shared.start(bootSource: src) { result in
            self.status = result
            VMExecutor.shared.call("actions", "list") { listing in
                self.actions = AppAction.parse(listing)
            }
            if let trial = UserDefaults.standard.string(forKey: "StackchanTrial") {
                VMExecutor.shared.runTrial(trial)
            }
        }
    }

    private func lastLine(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: true).last.map(String.init) ?? "no reply"
    }

    private func connect() {
        busy = true
        status = "Scanning…"
        VMExecutor.shared.call("connect", "") { result in
            self.connected = result.contains("Connected; RX value_handle bound")
            self.status = self.connected ? "connected" : self.lastLine(result)
            self.busy = false
        }
    }

    private func send(_ name: String) {
        busy = true
        status = "\(name)…"
        VMExecutor.shared.call(name, "") { result in
            self.status = self.lastLine(result)
            self.busy = false
        }
    }
}
