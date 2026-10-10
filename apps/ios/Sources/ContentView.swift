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
    @State private var output: String = "Starting VM…"
    @State private var connected: Bool = false
    @State private var busy: Bool = false
    @State private var connectFailed: Bool = false
    @State private var text: String = "ぼくスタックチャン、かわいいよ"
    @State private var speaking: Bool = false
    @State private var actions: [AppAction] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("Text") {
                        VStack(spacing: 8) {
                            TextField("Subtitle / Speak", text: $text)
                                .textFieldStyle(.roundedBorder)
                            Button("Speak") { speak() }
                                .buttonStyle(.glass)
                                .disabled(speaking || text.isEmpty)
                        }
                    }

                    group("Actions") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], alignment: .leading, spacing: 8) {
                            ForEach(actions) { action in
                                Button(action.label) { send(action.name, text) }
                                    .buttonStyle(.glass)
                            }
                        }
                    }

                    group("Output") {
                        Text(output.isEmpty ? "—" : output)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                    }
                }
                .padding()
            }
            .navigationTitle("Stack-chan")
            .navigationSubtitle(statusText)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button(connected ? "Connected" : "Connect") {
                        connect()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(statusColor)
                    .disabled(busy)
                }
            }
        }
        .onAppear { boot() }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold()
            content()
        }
    }

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            output = "(could not read bundled app.rb)"
            return
        }
        VMExecutor.shared.start(bootSource: src) { result in
            DispatchQueue.main.async {
                self.output = result
                VMExecutor.shared.call("actions", "list") { listing in
                    self.actions = AppAction.parse(listing)
                }
                if let batch = UserDefaults.standard.string(forKey: "StackchanBatch") {
                    VMExecutor.shared.runBatch(batch)
                }
            }
        }
    }

    private var statusText: String {
        if busy { return "scanning…" }
        if connected { return "connected" }
        if connectFailed { return "connect failed — see Output" }
        return "not connected"
    }

    private var statusColor: Color {
        if connected { return .green }
        if connectFailed && !busy { return .red }
        return .accentColor
    }

    private func connect() {
        busy = true
        connectFailed = false
        output = "Scanning for Stack-chan…"
        VMExecutor.shared.call("connect", "") { result in
            self.output = result.isEmpty ? "(no output)" : result
            self.connected = result.contains("Connected; dRuby pair bound")
            self.connectFailed = !self.connected
            self.busy = false
        }
    }

    private func send(_ method: String, _ arg: String) {
        VMExecutor.shared.call(method, arg) { result in
            self.output = result.isEmpty ? "(no output)" : result
        }
    }

    private func speak() {
        speaking = true
        output = "Synthesizing…"
        let text = self.text
        send("subtitle", text)
        SpeechSynth.shared.synthesize(text: text) { hex in
            guard let hex else {
                self.output = "speech synthesis failed"
                self.speaking = false
                return
            }
            VMExecutor.shared.call("speak_audio", hex) { result in
                self.output = result.isEmpty ? "(no output)" : result
                self.speaking = false
            }
        }
    }
}
