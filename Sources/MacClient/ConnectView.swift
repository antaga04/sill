import SwiftUI
import StreamProtocol

/// The window before a session: the Macs the network lists and the saved ones away from home, each
/// ending in how it is reached (Wired, Wi-Fi, Direct, Remote, Not paired, Update Sill), as on the
/// iPhone and iPad; the status line; pairing (a Mac's code at home, or Add a Mac with an address and
/// a code, or a pasted sill://pair link). All of it is the shared StreamClient's; this is its look.
struct ConnectView: View {
    @ObservedObject var client: StreamClient
    /// The fields' state. An ObservableObject rather than `@State`: `@State` is a macro in the
    /// macOS 27 SDK, whose plugin only Xcode carries, so this target builds with the Command Line
    /// Tools alone.
    @StateObject private var draft = ConnectDraft()

    private var homeShown: HomeAsk? { client.homeAsk.flatMap { $0.phase == .shown ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.weight(.semibold))
            Text(client.status).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = client.notice, notice.storeLink, notice.text == client.status {
                Text("Update Sill on this Mac to keep using that Mac.").font(.callout)
            }
            pairingLine

            if let pending = client.pendingLink {
                linkConfirmation(pending)
            } else if let ask = homeShown {
                homeCard(ask)
            } else if draft.adding {
                addCard
            } else {
                rows
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 560, alignment: .topLeading)
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }

    private var title: String {
        if client.pendingLink != nil || draft.adding { return "Add a Mac" }
        if let ask = homeShown { return DiscoveryPolicy.HomeCopy.cardTitle(mac: ask.name) }
        return "Connect to a Mac"
    }

    @ViewBuilder private var pairingLine: some View {
        switch client.pairing {
        case .idle: EmptyView()
        case .working(let text): Label(text, systemImage: "hourglass").foregroundStyle(.secondary)
        case .paired(let name): Label("Paired with \(name).", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let problem): Label(problem.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var rows: some View {
        List {
            ForEach(client.macs) { mac in
                Button { client.connect(to: mac) } label: {
                    HStack {
                        Image(systemName: "desktopcomputer").frame(width: 24)
                        Text(mac.name)
                        Spacer()
                        if let word = mac.word { Text(word).foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .accessibilityLabel(mac.route == .remote ? "\(mac.name), Remote" : mac.homeWord.label(name: mac.name))
                .contextMenu { menu(for: mac) }
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 120, maxHeight: 360)
        HStack {
            Button("Add a Mac…") {
                client.cancelHomeAsk()
                client.pairing = .idle
                draft.adding = true
            }
            if client.showsNearbyHint {
                if client.searchingNearby {
                    Text("Also looking nearby").foregroundStyle(.secondary)
                } else {
                    Button("Search Nearby") { client.searchNearby() }
                        .help("Also looks for a Mac with Direct Wireless Connection turned on, without a Wi-Fi network.")
                }
            }
        }
        if client.showsNearbyHint {
            Text("The other Mac has to be on the same network as this one, or have Direct Wireless Connection turned on in Sill. Away from home, add it once with a code from that Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func menu(for mac: FoundMac) -> some View {
        if let id = mac.macID {
            if mac.route == .network {
                Button("Connect Remotely") { client.connectRemotely(id) }
            }
            let name = client.savedMac(id) != nil ? client.displayName(id) : mac.name
            Button("Forget \(name)", role: .destructive) { client.forget(id) }
        }
    }

    /// The Mac shows its code: type it here (the iPhone's camera has no Mac counterpart).
    private func homeCard(_ ask: HomeAsk) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the 12-digit code \(ask.name) shows.").fixedSize(horizontal: false, vertical: true)
            TextField("Code", text: $draft.homeCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
                .onSubmit { client.pairHome(code: draft.homeCode) }
            HStack {
                Button("Cancel") { client.cancelHomeAsk(); draft.homeCode = "" }
                Spacer()
                Button("Pair") { client.pairHome(code: draft.homeCode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.homeCode.filter(\.isNumber).count < 12)
            }
        }
        .onDisappear { draft.homeCode = "" }
    }

    /// Add a Mac: the address the other Mac's pairing window gives and its code, or the whole link
    /// (copied from that window, or opened from Messages).
    private var addCard: some View {
        Form {
            Section("With the address and code") {
                TextField("Address", text: $draft.address, prompt: Text("name.tailnet.ts.net or 100.101.102.103"))
                TextField("Code", text: $draft.code, prompt: Text("12 digits"))
                    .font(.system(.body, design: .monospaced))
                Button("Pair") { client.pairTyped(code: draft.code, address: draft.address, overlay: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.address.isEmpty || draft.code.filter(\.isNumber).count < 12)
            }
            Section("Or with a pairing link") {
                TextField("Link", text: $draft.link, prompt: Text("sill://pair?…"))
                HStack {
                    Button("Paste") { draft.link = NSPasteboard.general.string(forType: .string) ?? draft.link }
                    Button("Pair with Link") { pairLink() }.disabled(draft.link.isEmpty)
                }
            }
            HStack {
                Spacer()
                Button("Done") {
                    if case .working = client.pairing { client.cancelPairing() }
                    client.pairing = .idle
                    draft.adding = false
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: client.connected) { _, connected in if connected { draft.adding = false } }
    }

    private func pairLink() {
        switch PairLink.parse(draft.link.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .success(let parsed): client.scanned(parsed, tapped: true, overlay: false)
        case .failure: client.pairing = .failed(.notALink)
        }
    }

    private func linkConfirmation(_ pending: PairLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pair this Mac with \(pending.name)?")
            HStack {
                Button("Cancel") { client.cancelPendingLink() }
                Spacer()
                Button("Pair") { draft.adding = true; client.confirmPendingLink() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

final class ConnectDraft: ObservableObject {
    @Published var adding = false
    @Published var address = ""
    @Published var code = ""
    @Published var homeCode = ""
    @Published var link = ""
}
