import SwiftUI

struct DiagBenchView: View {
    @ObservedObject var eventHandler = EventHandler.shared
    @State private var port = "9944"
    @State private var tcp = false
    @State private var running = false
    @State private var runID: UUID?
    @State private var status = "Clips: Documents/diag-clips. Logs: Documents/diag."
    @State private var sink = DiagNetSink()
    var body: some View {
        VStack(alignment: .leading) {
            Text("Decode / network measurements").font(.headline)
            Text("Stop streaming before testing. Starting a stream stops diagnostics. Net sink accepts one sender per run, for up to 60 seconds.").font(.caption)
            HStack {
                Button("Decode bench") {
                    let cancel = Progress(totalUnitCount: 1), id = UUID()
                    runID = id
                    running = DiagWorkGate.start(id: id) {
                        Task {
                            let result = await Task.detached { await DiagDecodeBench.run(cancel: cancel) }.value
                            DiagWorkGate.finish(id)
                            if runID == id { status = result; running = false }
                        }
                        return { cancel.cancel() }
                    }
                    status = running ? "Decoding all clips: 1/2 sessions × max/paced…" : "Stop streaming before testing."
                }
                TextField("Port", text: $port).frame(width: 80)
                Toggle("TCP bulk", isOn: $tcp)
                Button("Net sink") {
                    guard let number = UInt16(port), number > 0 else { status = "Port must be 1–65535"; return }
                    let id = UUID(); runID = id
                    var error: String?
                    running = DiagWorkGate.start {
                        error = sink.start(port: number, tcp: tcp) { if runID == id { running = false; status = "Net sink stopped; summary logged." } }
                        return error == nil ? { sink.stop() } : nil
                    }
                    status = error ?? (running ? "Listening on \(number) (\(tcp ? "TCP" : "UDP"))…" : "Stop streaming before testing.")
                }
            }.disabled(running || eventHandler.streamingActive)
            Button("Stop") { DiagWorkGate.stop() }.disabled(!running)
            Text(status).font(.caption)
        }.onDisappear { DiagWorkGate.stop() }
    }
}
