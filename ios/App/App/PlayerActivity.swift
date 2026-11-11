import ActivityKit
import AppIntents

@available(iOS 17.0, *)
struct PlayerActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var trackId: String
        var title: String
        var favourite: Bool
        var blocked: Bool
    }
    var name: String = "Arkpedia"
}

@available(iOS 17.0, *)
struct FavouriteTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Favourite song"
    @Parameter(title: "Track") var trackId: String
    init() {}
    init(trackId: String) { self.trackId = trackId }
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { NativeAudio.shared.preference("favourites", expectedId: trackId) }
        #endif
        return .result()
    }
}

@available(iOS 17.0, *)
struct BlockTrackIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Block song from autoplay"
    @Parameter(title: "Track") var trackId: String
    init() {}
    init(trackId: String) { self.trackId = trackId }
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run { NativeAudio.shared.preference("blocked", expectedId: trackId) }
        #endif
        return .result()
    }
}
