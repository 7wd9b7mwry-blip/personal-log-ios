import CryptoKit
import SwiftUI
import WebKit

/// The lost-item finder (tools/finder on the PC): retrace your steps and a live camera search. It is expensive (the
/// PC's GPU and 2.5 GB of RAM), so nothing runs until Start; the PC loads the models (about a minute), then its page
/// opens here. It stops itself after 10 idle minutes, or with Stop. Home Wi-Fi only (it is served from the PC).
struct FindView: View {
    @EnvironmentObject var store: Store
    @State private var state = FinderState()
    @State private var busy = false
    @State private var polling = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.page.ignoresSafeArea()
                if state.state == "ready", let url = state.url.flatMap(URL.init(string:)) {
                    FinderWebView(url: url, fingerprint: state.fingerprint ?? "")
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            Card(title: "Find something", intro: "Retrace where you've been since you last had it, then search with the camera: the PC spots what you describe (and, if you add one, matches a photo) and buzzes when it sees it.") {
                                VStack(alignment: .leading, spacing: 10) {
                                    statusLine
                                    if state.active {
                                        Button(role: .destructive) { Task { await act("stop") } } label: {
                                            Label("Stop", systemImage: "stop.circle").frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered).disabled(busy)
                                    } else {
                                        Button { Task { await act("start") } } label: {
                                            Label("Start the finder", systemImage: "magnifyingglass.circle.fill").frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(busy)
                                    }
                                    Muted(text: "Runs on the PC's graphics card, so it only starts when you tap Start and stops itself after 10 minutes without use. Works on the home Wi-Fi.")
                                }
                            }
                        }
                        .reportPage()
                    }
                }
            }
            .navigationTitle("Find")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if state.state == "ready" {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Stop", role: .destructive) { Task { await act("stop") } }
                    }
                }
            }
            .task { await refresh(); if state.active { await poll() } }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.state {
        case "requested": HStack { ProgressView(); Muted(text: "Asking the PC to start it…") }
        case "starting": HStack { ProgressView(); Muted(text: (state.message ?? "Starting") + " (about a minute)…") }
        case "error": Muted(text: "It didn't start: \(state.message ?? "unknown error")")
        default: Muted(text: state.message.map { "Off (\($0))." } ?? "Off.")
        }
    }

    private func act(_ action: String) async {
        busy = true
        defer { busy = false }
        if let s = try? await store.finder(action) { state = s }
        if action == "start" { await poll() }
    }

    private func refresh() async {
        if let s = try? await store.finder(nil) { state = s }
    }

    /// Every 2 s while it is on its way up (or running, to notice it stopping), up to 4 minutes for the start.
    private func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        var waited = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refresh()
            if !state.active { return }
            if state.state != "ready" {
                waited += 2
                if waited > 240 { state.message = "The PC didn't answer: is it on, with the HA logger running?"; return }
            }
        }
    }
}

struct FinderState: Decodable, Equatable {
    var state = "stopped"     // stopped | requested | starting | ready | error
    var url: String?
    var fingerprint: String?
    var message: String?
    var wanted: String?

    var active: Bool { ["requested", "starting", "ready"].contains(state) }
}

/// The finder's page, with the camera allowed and the PC's self-signed certificate trusted only when it is the one
/// the finder reported (its SHA-256 fingerprint).
struct FinderWebView: UIViewRepresentable {
    let url: URL
    let fingerprint: String

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator
        v.uiDelegate = context.coordinator
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(fingerprint: fingerprint.lowercased()) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let fingerprint: String
        init(fingerprint: String) { self.fingerprint = fingerprint }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let der = SecCertificateCopyData(leaf) as Data
            let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            if !fingerprint.isEmpty && hex == fingerprint {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        /// The page's camera (getUserMedia): allowed (iOS also asks once for the app's camera permission).
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }
}
