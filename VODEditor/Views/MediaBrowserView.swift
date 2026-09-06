import AppKit
import SwiftUI
import WebKit

/// A mini browser pointed at YouTube: search like normal, open a video, and
/// the Download menu pulls it into the shared Downloads folder as MP4, MP3 or
/// WAV — where every project's library lists it.
struct MediaBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloader = MediaDownloader.shared
    @StateObject private var web = WebController()
    @State private var addressText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { web.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.bordered)
                    .disabled(!web.canGoBack)
                TextField("Search YouTube, or paste any link", text: $addressText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { web.open(addressText) }
                Button { web.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)

                if let watch = web.watchURL {
                    Menu {
                        ForEach(MediaDownloader.Format.allCases) { format in
                            Button("\(format.rawValue) — \(format.explainer)") {
                                downloader.download(url: watch, format: format)
                            }
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle.fill")
                    }
                    .menuStyle(.borderedButton)
                    .fixedSize()
                    .disabled(downloader.isDownloading)
                } else {
                    Text("Open a video to download it")
                        .font(.caption2)
                        .foregroundStyle(Theme.textFaint)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(downloader.files.isEmpty
                                                                   ? [Paths.downloadsRoot]
                                                                   : [downloader.files[0]])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .help("Show the Clips folder in Finder (Desktop → VOD_Editor → Clips)")
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(10)

            if let label = downloader.activeLabel {
                HStack(spacing: 8) {
                    ProgressView(value: downloader.progress).tint(Theme.accent)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 120, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
            if let error = downloader.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            } else if let finished = downloader.lastFinished {
                Text(finished)
                    .font(.caption2)
                    .foregroundStyle(Theme.positive)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            Divider().overlay(Theme.border)

            WebViewRepresentable(controller: web)
        }
        .background(Theme.background)
        .onAppear {
            if web.webView.url == nil { web.open("https://www.youtube.com") }
        }
        .onChange(of: web.currentURLString) { _, value in
            addressText = value
        }
    }
}

/// Owns the WKWebView so SwiftUI updates never recreate it mid-navigation.
@MainActor
final class WebController: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    @Published private(set) var canGoBack = false
    @Published private(set) var currentURLString = ""
    @Published private(set) var watchURL: String?

    override init() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // YouTube's SPA rewrites the URL without a navigation, so poll cheaply.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
    }

    func open(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url: URL?
        if trimmed.contains("://") {
            url = URL(string: trimmed)
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            url = URL(string: "https://\(trimmed)")
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            url = URL(string: "https://www.youtube.com/results?search_query=\(query)")
        }
        if let url { webView.load(URLRequest(url: url)) }
    }

    func goBack() { webView.goBack() }
    func reload() { webView.reload() }

    private func sync() {
        canGoBack = webView.canGoBack
        let urlString = webView.url?.absoluteString ?? ""
        if urlString != currentURLString { currentURLString = urlString }
        let watch = webView.url.flatMap { MediaDownloader.watchURL(from: $0) }
        if watch != watchURL { watchURL = watch }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.sync() }
    }
}

private struct WebViewRepresentable: NSViewRepresentable {
    let controller: WebController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
