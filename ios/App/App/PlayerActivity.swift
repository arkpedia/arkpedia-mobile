import ActivityKit

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
