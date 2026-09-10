import SwiftUI
import AppKit
import VLCKit

/// What the player reports back to the model.
enum PlayerEvent {
    case opening
    case playing
    case buffering
    case ended
    case error
}

/// Thin SwiftUI wrapper around VLCKit's VLCVideoView + VLCMediaPlayer.
struct PlayerView: NSViewRepresentable {
    let url: URL?
    let attempt: Int
    let volume: Int32
    let paused: Bool
    let onEvent: (PlayerEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeNSView(context: Context) -> NSView {
        // A plain container keeps VLC's video view (and anything libvlc adds) clipped
        // to the player area instead of spilling over the rest of the window.
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.layer?.masksToBounds = true
        let video = VLCVideoView(frame: .zero)
        video.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(video)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            video.topAnchor.constraint(equalTo: container.topAnchor),
            video.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.attach(view: video)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(url: url, attempt: attempt, volume: volume, paused: paused)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private var player: VLCMediaPlayer?
        private var currentURL: URL?
        private var currentAttempt = -1
        private var currentPaused = false
        private let onEvent: (PlayerEvent) -> Void

        init(onEvent: @escaping (PlayerEvent) -> Void) { self.onEvent = onEvent }

        func attach(view: VLCVideoView) {
            VLCLogBridge.install()
            let p = VLCMediaPlayer(videoView: view)
            p.delegate = self
            player = p
        }

        func update(url: URL?, attempt: Int, volume: Int32, paused: Bool) {
            guard let player else { return }
            player.audio?.volume = volume
            if url != currentURL || attempt != currentAttempt {
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
                } else {
                    player.stop()
                }
            } else if paused != currentPaused, currentURL != nil {
                currentPaused = paused
                if paused { player.pause() } else { player.play() }
            }
        }

        func stop() {
            player?.stop()
            player?.delegate = nil
            player = nil
        }

        func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
            guard currentURL != nil else { return }
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
