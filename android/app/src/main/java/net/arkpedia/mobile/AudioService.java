package net.arkpedia.mobile;

import android.app.PendingIntent;
import android.content.Intent;
import android.net.Uri;
import android.os.*;
import androidx.annotation.Nullable;
import androidx.media3.common.*;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.session.*;
import com.getcapacitor.JSObject;
import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.*;
import java.util.*;
import java.util.function.Consumer;
import org.json.*;

/** Owns playback and queue progression independently of the WebView lifecycle. */
@androidx.annotation.OptIn(markerClass = androidx.media3.common.util.UnstableApi.class)
public class AudioService extends MediaSessionService {
    public static final String BIND_APP = "net.arkpedia.mobile.BIND_AUDIO";
    private static final SessionCommand HEART = new SessionCommand("arkpedia.favourite", Bundle.EMPTY);
    private static final SessionCommand BLOCK = new SessionCommand("arkpedia.block", Bundle.EMPTY);
    final Set<Consumer<JSObject>> listeners = new HashSet<>();
    private ExoPlayer player;
    private MediaSession session;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private List<JSONObject> tracks = new ArrayList<>();
    private JSONObject current;
    private String repeat = "off";
    private JSONObject favourites = new JSONObject(), blocked = new JSONObject(), changes = new JSONObject();
    private long revision;
    private long sequence;
    private final String sessionId = UUID.randomUUID().toString();
    private String error = "";
    private final Runnable tick = new Runnable() {
        public void run() { emit(); handler.postDelayed(this, 1000); }
    };
    public class LocalBinder extends Binder { AudioService service() { return AudioService.this; } }
    @Nullable @Override public IBinder onBind(Intent intent) {
        return BIND_APP.equals(intent.getAction()) ? new LocalBinder() : super.onBind(intent);
    }
    @Override public void onCreate() {
        super.onCreate();
        try {
            JSONObject saved = new JSONObject(getSharedPreferences("audio", MODE_PRIVATE).getString("preferences", "{}"));
            favourites = saved.optJSONObject("favourites") == null ? favourites : saved.optJSONObject("favourites");
            blocked = saved.optJSONObject("blocked") == null ? blocked : saved.optJSONObject("blocked");
            changes = saved.optJSONObject("changes") == null ? changes : saved.optJSONObject("changes");
            revision = saved.optLong("revision");
        } catch (JSONException ignored) {}
        player = new ExoPlayer.Builder(this).build();
        player.setAudioAttributes(new AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(), true);
        player.setHandleAudioBecomingNoisy(true);
        player.setWakeMode(C.WAKE_MODE_LOCAL);
        player.addListener(new Player.Listener() {
            @Override public void onEvents(Player source, Player.Events events) { emit(); }
            @Override public void onPlaybackStateChanged(int state) {
                if (state == Player.STATE_ENDED) {
                    if ("one".equals(repeat)) play(current, 0, true);
                    else advance(1);
                }
            }
            @Override public void onPlayerError(PlaybackException failure) { error = "Unable to play this song. Tap Play to retry."; emit(); }
        });
        // A forwarding player routes system Next/Previous through our native queue, including
        // the autoplay exclusions, rather than through ExoPlayer's single loaded item.
        ForwardingPlayer controls = new ForwardingPlayer(player) {
            @Override public Player.Commands getAvailableCommands() {
                return super.getAvailableCommands().buildUpon().add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM).add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM).add(Player.COMMAND_SEEK_TO_NEXT).add(Player.COMMAND_SEEK_TO_PREVIOUS).build();
            }
            @Override public boolean isCommandAvailable(int command) { return getAvailableCommands().contains(command); }
            @Override public void seekToNextMediaItem() { advance(1); }
            @Override public void seekToNext() { advance(1); }
            @Override public void seekToPreviousMediaItem() { advance(-1); }
            @Override public void seekToPrevious() { advance(-1); }
        };
        session = new MediaSession.Builder(this, controls)
            .setSessionActivity(PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT))
            .setCallback(new MediaSession.Callback() {
                @Override public MediaSession.ConnectionResult onConnect(MediaSession s, MediaSession.ControllerInfo controller) {
                    return new MediaSession.ConnectionResult.AcceptedResultBuilder(s)
                        .setAvailableSessionCommands(MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon().add(HEART).add(BLOCK).build()).build();
                }
                @Override public ListenableFuture<SessionResult> onCustomCommand(MediaSession s, MediaSession.ControllerInfo controller, SessionCommand command, Bundle args) {
                    if (current == null) return Futures.immediateFuture(new SessionResult(SessionError.ERROR_INVALID_STATE));
                    if (command.equals(HEART)) preference("favourites");
                    else if (command.equals(BLOCK)) preference("blocked");
                    else return Futures.immediateFuture(new SessionResult(SessionError.ERROR_NOT_SUPPORTED));
                    return Futures.immediateFuture(new SessionResult(SessionResult.RESULT_SUCCESS));
                }
            }).build();
        buttons(); handler.post(tick);
    }
    @Override public MediaSession onGetSession(MediaSession.ControllerInfo controller) { return session; }
    private String id() { return current == null ? "" : current.optString("id"); }
    private void buttons() {
        if (session == null) return;
        session.setMediaButtonPreferences(ImmutableList.of(
            new CommandButton.Builder(favourites.optBoolean(id()) ? CommandButton.ICON_HEART_FILLED : CommandButton.ICON_HEART_UNFILLED)
                .setDisplayName(favourites.optBoolean(id()) ? "Unfavourite" : "Favourite").setSessionCommand(HEART).build(),
            new CommandButton.Builder(CommandButton.ICON_THUMB_DOWN_UNFILLED)
                .setDisplayName(blocked.optBoolean(id()) ? "Allow autoplay" : "Block from autoplay").setSessionCommand(BLOCK).build()));
    }
    void configure(JSONObject data) {
        JSONArray list = data.optJSONArray("tracks");
        if (list != null) {
            List<JSONObject> next = new ArrayList<>();
            for (int i = 0; i < Math.min(list.length(), 3000); i++) {
                JSONObject track = list.optJSONObject(i);
                if (track != null && valid(track)) next.add(track);
            }
            tracks = next;
            for (JSONObject track : tracks) if (track.optString("id").equals(id())) { current = track; break; }
        }
        repeat = data.optString("repeat", "off");
        // Stale page state cannot overwrite taps received while JavaScript was suspended.
        if (data.optLong("revision", -1) >= revision) {
            favourites = flags(data.optJSONArray("favourites"));
            blocked = flags(data.optJSONArray("blocked"));
            changes = new JSONObject(); save();
        }
        buttons(); emit();
    }
    private JSONObject flags(JSONArray values) {
        JSONObject result = new JSONObject();
        if (values != null) for (int i = 0; i < values.length(); i++) put(result, values.optString(i), true);
        return result;
    }
    private boolean valid(JSONObject track) {
        return !track.optString("id").isEmpty() && track.optString("id").length() < 150 && track.optString("cid").matches("[0-9]{1,20}");
    }
    void loadTrack(JSONObject data) {
        JSONObject track = data.optJSONObject("track");
        if (track == null || !valid(track)) throw new IllegalArgumentException("Invalid Monster Siren track");
        play(track, Math.max(0, data.optDouble("seconds", 0)), data.optBoolean("play", true));
    }
    private void play(JSONObject track, double seconds, boolean start) {
        if (track == null) return;
        current = track; error = "";
        String cid = track.optString("cid");
        MediaMetadata metadata = new MediaMetadata.Builder().setTitle(track.optString("title", "Arkpedia"))
            .setArtist(track.optString("artist", "Monster Siren Records")).setAlbumTitle(track.optString("album"))
            .setArtworkUri(Uri.parse("https://www.arkpedia.net/api/music-cover/" + cid)).build();
        player.setMediaItem(new MediaItem.Builder().setMediaId(id()).setUri("https://www.arkpedia.net/api/music-audio/" + cid).setMediaMetadata(metadata).build(), (long)(seconds * 1000));
        player.prepare(); player.setPlayWhenReady(start); buttons(); emit();
    }
    private void advance(int direction) {
        if (direction < 0 && player.getCurrentPosition() > 3000) { player.seekTo(0); return; }
        int index = -1;
        for (int i = 0; i < tracks.size(); i++) if (tracks.get(i).optString("id").equals(id())) { index = i; break; }
        for (int step = 1; step <= tracks.size(); step++) {
            int next = index + direction * step;
            if (next < 0 || next >= tracks.size()) {
                if (!"all".equals(repeat)) break;
                next = Math.floorMod(next, tracks.size());
            }
            JSONObject track = tracks.get(next);
            if (track.optBoolean("autoplay") && blocked.optBoolean(track.optString("id"))) continue;
            play(track, 0, true); return;
        }
        player.pause(); if (direction < 0) player.seekTo(0); emit();
    }
    void command(JSONObject data) {
        switch (data.optString("action")) {
            case "play": if (player.getPlayerError() != null) play(current, player.getCurrentPosition()/1000.0, true); else player.play(); break;
            case "pause": player.pause(); break;
            case "stop": player.stop(); player.clearMediaItems(); current = null; tracks.clear(); break;
            case "seek": player.seekTo((long)(Math.max(0, data.optDouble("seconds")) * 1000)); break;
            case "volume": player.setVolume((float)Math.min(1, Math.max(0, data.optDouble("volume", 1)))); break;
            case "next": advance(1); break;
            case "previous": advance(-1); break;
            case "favourite": preference("favourites"); break;
            case "block": preference("blocked"); break;
            default: throw new IllegalArgumentException("Unknown command");
        }
        emit();
    }
    private void preference(String kind) {
        if (id().isEmpty()) return;
        JSONObject values = kind.equals("favourites") ? favourites : blocked;
        boolean value = !values.optBoolean(id()); put(values, id(), value);
        JSONObject edit = new JSONObject(); put(edit, "id", id()); put(edit, "kind", kind); put(edit, "value", value);
        put(changes, kind + ":" + id(), edit); revision++; save(); buttons(); emit();
        if (kind.equals("blocked") && value && current.optBoolean("autoplay")) advance(1);
    }
    private void save() {
        JSONObject saved = new JSONObject(); put(saved, "favourites", favourites); put(saved, "blocked", blocked); put(saved, "changes", changes); put(saved, "revision", revision);
        getSharedPreferences("audio", MODE_PRIVATE).edit().putString("preferences", saved.toString()).apply();
    }
    JSObject state() {
        JSObject result = new JSObject();
        result.put("version", 1); result.put("track", current == null ? JSONObject.NULL : current);
        result.put("sequence", ++sequence); result.put("sessionId", sessionId);
        result.put("seconds", player == null ? 0 : player.getCurrentPosition()/1000.0);
        result.put("duration", player == null || player.getDuration() == C.TIME_UNSET ? 0 : player.getDuration()/1000.0);
        result.put("playing", player != null && player.isPlaying());
        result.put("buffering", player != null && player.getPlayWhenReady() && player.getPlaybackState() == Player.STATE_BUFFERING);
        result.put("revision", revision); result.put("changes", changes); result.put("error", error);
        return result;
    }
    private void emit() { for (Consumer<JSObject> listener : new ArrayList<>(listeners)) listener.accept(state()); }
    private static void put(JSONObject target, String key, Object value) { try { target.put(key, value); } catch (JSONException ignored) {} }
    @Override public void onTaskRemoved(Intent rootIntent) { if (!player.getPlayWhenReady()) stopSelf(); }
    @Override public void onDestroy() { handler.removeCallbacks(tick); session.release(); player.release(); super.onDestroy(); }
}
