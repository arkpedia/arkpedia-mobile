import AVFoundation
import MediaPlayer
import Capacitor
import ActivityKit

@objc(ArkpediaAudioPlugin)
public class ArkpediaAudioPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ArkpediaAudioPlugin"
    public let jsName = "ArkpediaAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getSpectrum", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "configure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "loadTrack", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "command", returnType: CAPPluginReturnPromise)
    ]
    public override func load() {
        // Dismiss a companion card left by 0.2.0. New versions use only Apple's player.
        if #available(iOS 17.0, *) {
            Task { for activity in Activity<PlayerActivity>.activities { await activity.end(nil, dismissalPolicy: .immediate) } }
        }
        NativeAudio.shared.changed = { [weak self] state in self?.notifyListeners("state", data: state) }
    }
    private func run(_ call: CAPPluginCall, _ action: @escaping (NativeAudio, [String: Any]) throws -> Void) {
        DispatchQueue.main.async {
            guard let url = self.bridge?.webView?.url, url.scheme == "https", url.host == "www.arkpedia.net", url.port == nil || url.port == 443 else {
                call.reject("Audio is available only to Arkpedia production"); return
            }
            do {
                try action(NativeAudio.shared, call.options as? [String: Any] ?? [:])
                call.resolve(NativeAudio.shared.state())
            } catch { call.reject(error.localizedDescription) }
        }
    }
    @objc func getState(_ call: CAPPluginCall) { run(call) { _, _ in } }
    @objc func getSpectrum(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let url = self.bridge?.webView?.url, url.scheme == "https", url.host == "www.arkpedia.net", url.port == nil || url.port == 443 else {
                call.reject("Audio is available only to Arkpedia production"); return
            }
            call.resolve(NativeAudio.shared.spectrum())
        }
    }
    @objc func configure(_ call: CAPPluginCall) { run(call) { audio, data in audio.configure(data) } }
    @objc func loadTrack(_ call: CAPPluginCall) { run(call) { audio, data in try audio.load(data) } }
    @objc func command(_ call: CAPPluginCall) { run(call) { audio, data in try audio.command(data) } }
}

/// Audio, queue progression and preference edits remain native while WKWebView is suspended.
final class NativeAudio {
    static let shared = NativeAudio()
    var changed: (([String: Any]) -> Void)?
    private let player = AVPlayer()
    private var tracks: [[String: Any]] = []
    private var current: [String: Any]?
    private var repeatMode = "off"
    private var favourites: [String: Bool] = [:], blocked: [String: Bool] = [:]
    private var changes: [String: [String: Any]] = [:]
    private var revision = 0
    private var sequence = 0
    private let sessionId = UUID().uuidString
    private var error = ""
    private var artwork: MPMediaItemArtwork?
    private var clock: Any?
    private var status: NSKeyValueObservation?
    private var itemStatus: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var wasPlaying = false
    private var generation = 0
    private var capture: NativeSpectrumCapture?
    private let analyzer = SpectrumAnalyzer()
    private var id: String { current?["id"] as? String ?? "" }

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: "nativeAudioPreferences") ?? [:]
        favourites = saved["favourites"] as? [String: Bool] ?? [:]
        blocked = saved["blocked"] as? [String: Bool] ?? [:]
        changes = saved["changes"] as? [String: [String: Any]] ?? [:]
        revision = saved["revision"] as? Int ?? 0
        clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in self?.emit() }
        status = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.emit() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] event in
            guard let self, event.object as? AVPlayerItem === self.player.currentItem else { return }
            if self.repeatMode == "one", let current = self.current { try? self.play(current, seconds: 0, start: true) }
            else { self.advance(1) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] event in
            guard let self, let kind = event.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            if kind == AVAudioSession.InterruptionType.began.rawValue {
                self.wasPlaying = self.player.rate > 0; self.player.pause(); self.capture?.reset()
            } else if self.wasPlaying,
                      let raw = event.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true); self.player.play()
            }
            self.emit()
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] event in
            if event.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.player.pause(); self?.emit() }
        })
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in self?.remote("play") ?? .commandFailed }
        remote.pauseCommand.addTarget { [weak self] _ in self?.remote("pause") ?? .commandFailed }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.remote("toggle") ?? .commandFailed
        }
        remote.nextTrackCommand.addTarget { [weak self] _ in self?.remote("next") ?? .commandFailed }
        remote.previousTrackCommand.addTarget { [weak self] _ in self?.remote("previous") ?? .commandFailed }
        remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self.remote("seek", seconds: event.positionTime)
        }
        remote.likeCommand.addTarget { [weak self] _ in self?.remote("favourite") ?? .commandFailed }
        remote.dislikeCommand.addTarget { [weak self] _ in self?.remote("block") ?? .commandFailed }
    }
    private func remote(_ action: String, seconds: Double = 0) -> MPRemoteCommandHandlerStatus {
        if !Thread.isMainThread { return DispatchQueue.main.sync { self.remote(action, seconds: seconds) } }
        guard current != nil else { return .noSuchContent }
        let resolved = action == "toggle" ? (player.rate > 0 ? "pause" : "play") : action
        do { try command(["action": resolved, "seconds": seconds]); return .success } catch { return .commandFailed }
    }
    private func valid(_ track: [String: Any]) -> Bool {
        guard let id = track["id"] as? String, !id.isEmpty, id.count < 150,
              let cid = track["cid"] as? String else { return false }
        return cid.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil
    }
    func configure(_ data: [String: Any]) {
        if let values = data["tracks"] as? [[String: Any]] {
            tracks = Array(values.prefix(3000)).filter(valid)
            if let match = tracks.first(where: { $0["id"] as? String == id }) { current = match }
        }
        repeatMode = data["repeat"] as? String ?? "off"
        if (data["revision"] as? Int ?? -1) >= revision {
            favourites = Dictionary((data["favourites"] as? [String] ?? []).map { ($0, true) }, uniquingKeysWith: { _, value in value })
            blocked = Dictionary((data["blocked"] as? [String] ?? []).map { ($0, true) }, uniquingKeysWith: { _, value in value })
            changes = [:]; save()
        }
        emit()
    }
    func load(_ data: [String: Any]) throws {
        guard let track = data["track"] as? [String: Any], valid(track) else { throw failure("Invalid Monster Siren track") }
        try play(track, seconds: max(0, data["seconds"] as? Double ?? 0), start: data["play"] as? Bool ?? true)
    }
    private func play(_ track: [String: Any], seconds: Double, start: Bool) throws {
        guard let cid = track["cid"] as? String, valid(track) else { throw failure("Invalid track") }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        if start { try AVAudioSession.sharedInstance().setActive(true) }
        generation += 1; let request = generation
        current = track; error = ""; artwork = nil
        let item = AVPlayerItem(url: URL(string: "https://www.arkpedia.net/api/music-audio/\(cid)")!)
        let capture = NativeSpectrumCapture()
        self.capture = capture
        // A remote MP3 is an AVURLAsset, not an HLS stream. Install its audio tap
        // once the track is known; loading analysis never delays or starts playback.
        Task { [weak self, weak item] in
            guard let item else { return }
            guard let audioTrack = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            await MainActor.run {
                guard let self, self.generation == request, self.player.currentItem === item,
                      let tap = capture.tap() else { return }
                let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
                parameters.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                item.audioMix = mix
            }
        }
        itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                if item.status == .failed { self.error = "Unable to play this song. Tap Play to retry."; self.player.pause() }
                self.emit()
            }
        }
        player.pause()
        player.replaceCurrentItem(with: item)
        if seconds.isFinite && seconds > 0 { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        if start { player.play() }
        URLSession.shared.dataTask(with: URL(string: "https://www.arkpedia.net/api/music-cover/\(cid)")!) { [weak self] data, _, _ in
            guard let data, data.count <= 5_000_000, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }; self.emit()
            }
        }.resume()
        emit()
    }
    private func advance(_ direction: Int) {
        if direction < 0 && player.currentTime().seconds > 3 { player.seek(to: .zero); return }
        let index = tracks.firstIndex(where: { $0["id"] as? String == id }) ?? -1
        if !tracks.isEmpty {
            for step in 1...tracks.count {
                var next = index + direction * step
                if next < 0 || next >= tracks.count {
                    if repeatMode != "all" { break }
                    next = ((next % tracks.count) + tracks.count) % tracks.count
                }
                let track = tracks[next]
                if track["autoplay"] as? Bool == true && blocked[track["id"] as? String ?? ""] == true { continue }
                do { try play(track, seconds: 0, start: true) } catch { self.error = error.localizedDescription; emit() }
                return
            }
        }
        player.pause(); if direction < 0 { player.seek(to: .zero) }; emit()
    }
    func command(_ data: [String: Any]) throws {
        switch data["action"] as? String ?? "" {
        case "play":
            if let current, player.currentItem?.status == .failed { try play(current, seconds: finite(player.currentTime().seconds), start: true) }
            else { try AVAudioSession.sharedInstance().setActive(true); player.play() }
        case "pause": player.pause(); capture?.reset()
        case "stop":
            generation += 1; player.pause(); player.replaceCurrentItem(with: nil); current = nil; tracks = []; capture = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        case "seek":
            capture?.reset()
            player.seek(to: CMTime(seconds: max(0, finite(data["seconds"] as? Double ?? 0)), preferredTimescale: 600))
        case "volume": player.volume = Float(min(1, max(0, data["volume"] as? Double ?? 1)))
        case "next": advance(1)
        case "previous": advance(-1)
        case "favourite": preference("favourites")
        case "block": preference("blocked")
        default: throw failure("Unknown audio command")
        }
        emit()
    }
    func preference(_ kind: String, expectedId: String? = nil) {
        if let expectedId, expectedId != id { return }
        guard !id.isEmpty else { return }
        let value: Bool
        if kind == "favourites" { value = !(favourites[id] ?? false); favourites[id] = value }
        else { value = !(blocked[id] ?? false); blocked[id] = value }
        changes["\(kind):\(id)"] = ["id": id, "kind": kind, "value": value]
        revision += 1; save(); emit()
        if kind == "blocked" && value && current?["autoplay"] as? Bool == true { advance(1) }
    }
    private func save() {
        UserDefaults.standard.set(["favourites": favourites, "blocked": blocked, "changes": changes, "revision": revision], forKey: "nativeAudioPreferences")
    }
    private func finite(_ number: Double) -> Double { number.isFinite ? max(0, number) : 0 }
    func spectrum() -> [String: Any] {
        guard UIApplication.shared.applicationState == .active, player.timeControlStatus == .playing,
              let analyzer, let samples = capture?.snapshot(at: player.currentTime().seconds) else {
            return ["trackId": id, "available": false, "bands": []]
        }
        return ["trackId": id, "available": true,
                "bands": analyzer.levels(channels: samples.channels, sampleRate: samples.sampleRate)]
    }
    func state() -> [String: Any] {
        sequence += 1
        return ["version": 1, "sequence": sequence, "sessionId": sessionId, "track": current as Any? ?? NSNull(), "seconds": finite(player.currentTime().seconds),
         "duration": finite(player.currentItem?.duration.seconds ?? 0), "playing": player.timeControlStatus == .playing,
         "buffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate, "revision": revision, "changes": changes, "error": error]
    }
    private func emit() {
        if let current {
            var info: [String: Any] = [MPMediaItemPropertyTitle: current["title"] as? String ?? "Arkpedia",
                MPMediaItemPropertyArtist: current["artist"] as? String ?? "Monster Siren Records",
                MPMediaItemPropertyAlbumTitle: current["album"] as? String ?? "",
                MPMediaItemPropertyPlaybackDuration: finite(player.currentItem?.duration.seconds ?? 0),
                MPNowPlayingInfoPropertyElapsedPlaybackTime: finite(player.currentTime().seconds),
                MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? 1.0 : 0.0]
            if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        let remote = MPRemoteCommandCenter.shared()
        remote.likeCommand.isEnabled = current != nil; remote.likeCommand.isActive = favourites[id] == true
        remote.likeCommand.localizedTitle = favourites[id] == true ? "Unfavourite" : "Favourite"
        remote.dislikeCommand.isEnabled = current != nil; remote.dislikeCommand.isActive = blocked[id] == true
        remote.dislikeCommand.localizedTitle = blocked[id] == true ? "Allow autoplay" : "Block from autoplay"
        changed?(state())
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "ArkpediaAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
