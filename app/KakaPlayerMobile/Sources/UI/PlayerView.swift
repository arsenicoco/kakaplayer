import SwiftUI
import UIKit
import VLCKit

/// What the player reports back to the model.
enum PlayerEvent {
    case opening
    case playing
    case buffering
    case ended
    case error
    /// The player has actually released the media and the audio hardware. Distinct from
    /// `.ended`: `.ended` is the stream finishing on its own, this is the teardown the
    /// model asked for completing, which is the point at which the audio session can go.
    case stopped
}

/// Thin SwiftUI wrapper around VLCKit's VLCMediaPlayer drawing into a plain UIView.
/// VLCKit 4 exposes the same `VLCMediaPlayer` on iOS as on macOS; only the drawable
/// differs (there is no VLCVideoView on iOS).
struct PlayerView: UIViewRepresentable {
    let url: URL?
    let attempt: Int
    let volume: Int32
    let paused: Bool
    /// `false` letterboxes the video inside the view, `true` crops it to fill — the
    /// difference between black bars and a 16:9 stream filling a 19.5:9 phone in landscape.
    var aspectFill: Bool = false
    let onEvent: (PlayerEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        container.clipsToBounds = true
        context.coordinator.attach(view: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.update(url: url, attempt: attempt, volume: volume, paused: paused, aspectFill: aspectFill)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private var player: VLCMediaPlayer?
        private var currentURL: URL?
        private var currentAttempt = -1
        private var currentPaused = false
        private var currentAspectFill: Bool?
        private let onEvent: (PlayerEvent) -> Void

        init(onEvent: @escaping (PlayerEvent) -> Void) { self.onEvent = onEvent }

        func attach(view: UIView) {
            VLCLogBridge.install()
            let p = VLCMediaPlayer()
            p.drawable = view
            p.delegate = self
            player = p
        }

        func update(url: URL?, attempt: Int, volume: Int32, paused: Bool, aspectFill: Bool) {
            guard let player else { return }
            player.audio?.volume = volume
            applyFit(aspectFill, to: player)
            if url != currentURL || attempt != currentAttempt {
                let previousURL = currentURL
                currentURL = url
                currentAttempt = attempt
                currentPaused = false
                if let url, let media = VLCMedia(url: url) {
                    media.addOptions([
                        "network-caching": 3000,
                        "live-caching": 3000,
                        "http-reconnect": true,
                    ])
                    player.media = media
                    player.play()
                    // A fresh vout starts from the player's own fit mode; re-assert ours so
                    // a reopened stream does not snap back to letterbox.
                    currentAspectFill = nil
                    applyFit(aspectFill, to: player)
                } else {
                    player.stop()
                    // `stop()` is synchronous but the delegate callback below is filtered
                    // out once `currentURL` is nil, so tell the model here: it is waiting
                    // for this before it gives the audio route back. Only when something
                    // was actually open — the first `update` of a fresh player also lands
                    // here (no url yet, attempt 0 vs -1) and that is not a teardown.
                    if previousURL != nil { onEvent(.stopped) }
                }
            } else if paused != currentPaused, currentURL != nil {
                currentPaused = paused
                if paused { player.pause() } else { player.play() }
            }
        }

        /// VLCKit 4's `videoFitMode` does the cropping for us: `.smaller` fits the whole
        /// frame inside the view (letterbox), `.larger` fills it and lets the overflow be
        /// clipped by the container. Nothing here touches `videoAspectRatio` — that
        /// *stretches* the picture rather than cropping it, which is not what fill means.
        private func applyFit(_ aspectFill: Bool, to player: VLCMediaPlayer) {
            guard currentAspectFill != aspectFill else { return }
            currentAspectFill = aspectFill
            player.videoFitMode = aspectFill ? .larger : .smaller
        }

        func stop() {
            player?.stop()
            player?.delegate = nil
            player = nil
        }

        func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
            guard currentURL != nil else {
                // Torn down already: the only state still worth forwarding is the player
                // confirming it has let go, which may land after `update` asked it to stop.
                if newState == .stopped { onEvent(.stopped) }
                return
            }
            switch newState {
            case .opening: onEvent(.opening)
            case .playing: onEvent(.playing)
            case .error: onEvent(.error)
            case .stopped: onEvent(.ended)
            default: break
            }
        }
    }
}

/// Forwards libvlc warnings/errors into the app log.
final class VLCLogBridge: NSObject, VLCLogging {
    static var sink: ((String) -> Void)?
    private static var installed = false
    var level: VLCLogLevel = .warning

    static func install() {
        guard !installed else { return }
        installed = true
        VLCLibrary.shared().loggers = [VLCLogBridge()]
    }

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        let tag = level == .error ? "error" : "warn"
        let module = context?.module ?? "vlc"
        VLCLogBridge.sink?("[vlc/\(tag)] \(module): \(message)")
    }
}
