import ActivityKit
import WidgetKit
import SwiftUI

@main
struct ArkpediaControls: WidgetBundle {
    var body: some Widget { PlayerControls() }
}

struct PlayerControls: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayerActivity.self) { context in
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arkpedia").font(.caption).foregroundStyle(.secondary)
                    Text(context.state.title).font(.headline).lineLimit(2)
                }
                Spacer(minLength: 0)
                Controls(state: context.state)
            }
            .padding()
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .widgetURL(URL(string: "https://www.arkpedia.net/music"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text("Arkpedia").font(.caption) }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.title).lineLimit(1)
                        Spacer()
                        Controls(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Image(systemName: context.state.favourite ? "heart.fill" : "heart")
            } minimal: {
                Image(systemName: "music.note")
            }
        }
    }
}

private struct Controls: View {
    let state: PlayerActivity.ContentState
    var body: some View {
        HStack(spacing: 12) {
            Button(intent: FavouriteTrackIntent(trackId: state.trackId)) {
                Image(systemName: state.favourite ? "heart.fill" : "heart")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .tint(state.favourite ? .pink : .primary)
            .accessibilityLabel(state.favourite ? "Unfavourite song" : "Favourite song")
            Button(intent: BlockTrackIntent(trackId: state.trackId)) {
                Image(systemName: state.blocked ? "nosign" : "hand.thumbsdown")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .tint(state.blocked ? .orange : .primary)
            .accessibilityLabel(state.blocked ? "Allow autoplay for this song" : "Block this song from autoplay")
        }
        .buttonStyle(.borderless)
    }
}
