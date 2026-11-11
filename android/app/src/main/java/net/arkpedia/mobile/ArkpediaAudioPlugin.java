package net.arkpedia.mobile;

import android.content.*;
import android.net.Uri;
import android.os.IBinder;
import com.getcapacitor.*;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Consumer;

/** Only the configured production page can control the app's audio service. */
@CapacitorPlugin(name = "ArkpediaAudio")
public class ArkpediaAudioPlugin extends Plugin {
    private AudioService service;
    private final List<Runnable> waiting = new ArrayList<>();
    private boolean bound;
    private final Consumer<JSObject> listener = state -> notifyListeners("state", state);
    private final ServiceConnection connection = new ServiceConnection() {
        public void onServiceConnected(ComponentName name, IBinder binder) {
            service = ((AudioService.LocalBinder) binder).service();
            service.listeners.add(listener);
            for (Runnable task : new ArrayList<>(waiting)) task.run();
            waiting.clear();
        }
        public void onServiceDisconnected(ComponentName name) { service = null; }
    };
    private void run(PluginCall call, Consumer<AudioService> action) {
        getActivity().runOnUiThread(() -> {
            Uri page = Uri.parse(bridge.getWebView().getUrl() == null ? "" : bridge.getWebView().getUrl());
            if (!"https".equals(page.getScheme()) || !"www.arkpedia.net".equals(page.getHost()) || (page.getPort() != -1 && page.getPort() != 443)) {
                call.reject("Audio is available only to Arkpedia production"); return;
            }
            Runnable task = () -> {
                try { action.accept(service); call.resolve(service.state()); }
                catch (Exception error) { call.reject("Audio command failed", error); }
            };
            if (service != null) { task.run(); return; }
            waiting.add(task);
            if (!bound) {
                Intent intent = new Intent(getContext(), AudioService.class).setAction(AudioService.BIND_APP);
                bound = getContext().bindService(intent, connection, Context.BIND_AUTO_CREATE);
                if (!bound) { waiting.clear(); call.reject("Could not connect to audio service"); }
            }
        });
    }
    @PluginMethod public void getState(PluginCall call) { run(call, service -> {}); }
    @PluginMethod public void configure(PluginCall call) { run(call, service -> service.configure(call.getData())); }
    @PluginMethod public void loadTrack(PluginCall call) { run(call, service -> service.loadTrack(call.getData())); }
    @PluginMethod public void command(PluginCall call) { run(call, service -> service.command(call.getData())); }
    @Override protected void handleOnDestroy() {
        if (service != null) service.listeners.remove(listener);
        if (bound) getContext().unbindService(connection);
        waiting.clear(); service = null; bound = false;
    }
}
