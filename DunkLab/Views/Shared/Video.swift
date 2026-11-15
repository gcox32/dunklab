import SafariServices
import SwiftUI
import WebKit

/// A play button for an exercise's how-to video. YouTube links play in a
/// lightbox showing just the player; other links open in an in-app browser.
/// Renders nothing when there is no usable link.
struct VideoButton: View {
    let link: String?

    @State private var showing = false

    private var url: URL? {
        guard let link, let url = URL(string: link.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    var body: some View {
        if let url {
            let video = YouTubeVideo(url)
            Button {
                showing = true
            } label: {
                Image(systemName: "play.rectangle.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.rim)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Watch video")
            .fullScreenCover(isPresented: Binding(get: { showing && video != nil }, set: { showing = $0 })) {
                if let video { VideoLightbox(video: video) }
            }
            .sheet(isPresented: Binding(get: { showing && video == nil }, set: { showing = $0 })) {
                SafariView(url: url).ignoresSafeArea()
            }
        }
    }
}

/// A YouTube video id pulled from the usual link shapes.
struct YouTubeVideo {
    let id: String
    let isShort: Bool

    init?(_ url: URL) {
        let host = url.host()?.replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "m.", with: "") ?? ""
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "youtu.be":
            guard let first = parts.first else { return nil }
            id = first
            isShort = false
        case "youtube.com", "youtube-nocookie.com":
            if parts.first == "watch",
               let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
                id = v
                isShort = false
            } else if parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]) {
                id = parts[1]
                isShort = parts[0] == "shorts"
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}

/// The player alone, centered on a dimmed backdrop. Tap outside to close.
private struct VideoLightbox: View {
    let video: YouTubeVideo

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            YouTubePlayer(video: video)
                .aspectRatio(video.isShort ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                .frame(maxHeight: video.isShort ? 560 : nil)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
            }
            .accessibilityLabel("Close video")
            .padding(16)
        }
        .presentationBackground(.clear)
    }
}

private struct YouTubePlayer: UIViewRepresentable {
    let video: YouTubeVideo

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style>
        </head><body>
        <iframe src="https://www.youtube.com/embed/\(video.id)?playsinline=1&autoplay=1&rel=0"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
          referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
        </body></html>
        """
        // YouTube refuses embeds with no referrer, so give the page an origin
        // named after the app, as YouTube asks of embedding apps.
        let origin = URL(string: "https://\(Bundle.main.bundleIdentifier ?? "dunklab.app")")
        view.loadHTMLString(html, baseURL: origin)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
