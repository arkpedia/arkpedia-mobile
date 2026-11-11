package net.arkpedia.mobile;

import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.webkit.CookieManager;
import androidx.browser.customtabs.CustomTabsIntent;
import com.getcapacitor.*;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.net.HttpCookie;
import java.io.ByteArrayOutputStream;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.atomic.AtomicInteger;
import org.json.JSONObject;

/** Proofs and HttpOnly cookies stay native. No browser/provider origin gets bridge access. */
@CapacitorPlugin(name = "ArkpediaAuth")
public class ArkpediaAuthPlugin extends Plugin {
    private static final String ORIGIN = "https://www.arkpedia.net";
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService network = Executors.newSingleThreadExecutor();
    private String verifier, state;
    private PluginCall pending;
    private boolean leftApp, redeeming;
    private final Runnable timeout = () -> fail("Sign-in timed out. Please try again.");
    private boolean allowed() {
        Uri page = Uri.parse(bridge.getWebView().getUrl() == null ? "" : bridge.getWebView().getUrl());
        return "https".equals(page.getScheme()) && "www.arkpedia.net".equals(page.getHost()) && (page.getPort() == -1 || page.getPort() == 443);
    }
    private static boolean valid(String value) { return value != null && value.matches("[A-Za-z0-9_-]{43}"); }
    private static String encoded(byte[] bytes) { return Base64.encodeToString(bytes, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING); }
    private void clear() { main.removeCallbacks(timeout); verifier = null; state = null; pending = null; leftApp = false; redeeming = false; }
    private void fail(String message) { PluginCall call = pending; clear(); if (call != null) call.reject(message); }
    @PluginMethod public void prepare(PluginCall call) {
        main.post(() -> {
            if (!allowed()) { call.reject("Sign-in is available only to Arkpedia production"); return; }
            if (pending != null) { call.reject("Sign-in is already open"); return; }
            clear();
            try {
                byte[] bytes = new byte[32]; new SecureRandom().nextBytes(bytes); verifier = encoded(bytes);
                call.resolve(new JSObject().put("challenge", encoded(MessageDigest.getInstance("SHA-256").digest(verifier.getBytes(StandardCharsets.UTF_8)))));
            } catch (Exception error) { clear(); call.reject("Could not prepare sign-in"); }
        });
    }
    @PluginMethod public void open(PluginCall call) {
        main.post(() -> {
            String next = call.getString("state");
            if (!allowed() || !valid(next) || verifier == null || pending != null) { call.reject("Prepare sign-in first"); return; }
            state = next; pending = call;
            try {
                main.postDelayed(timeout, 600_000);
                new CustomTabsIntent.Builder().build().launchUrl(getActivity(), Uri.parse(ORIGIN + "/api/native-auth/start?state=" + next));
            } catch (Exception error) { fail("Could not open sign-in. Please try again."); }
        });
    }
    @PluginMethod public void cancel(PluginCall call) {
        main.post(() -> {
            if (!allowed()) { call.reject("Unavailable outside Arkpedia"); return; }
            fail("Sign-in cancelled."); call.resolve();
        });
    }
    @Override protected void handleOnPause() { if (pending != null) leftApp = true; }
    @Override protected void handleOnResume() {
        if (leftApp && pending != null && !redeeming) {
            String previous = state;
            main.postDelayed(() -> { if (Objects.equals(state, previous) && !redeeming) fail("Sign-in cancelled."); }, 700);
        }
    }
    @Override protected void handleOnDestroy() { fail("Sign-in cancelled."); network.shutdownNow(); }
    @Override protected void handleOnNewIntent(Intent intent) {
        Uri url = intent.getData();
        if (pending == null || redeeming || url == null || !"net.arkpedia.mobile".equals(url.getScheme()) || !"auth".equals(url.getHost())
            || (url.getPath() != null && !url.getPath().isEmpty()) || url.getQueryParameters("state").size() != 1 || !Objects.equals(state, url.getQueryParameter("state"))) return;
        if (url.getQueryParameter("error") != null) { fail("Sign-in could not finish. Use your existing login and try again."); return; }
        if (!allowed()) { fail("Unavailable outside Arkpedia"); return; }
        redeeming = true;
        String expected = state, proof = verifier;
        network.execute(() -> redeem(expected, proof));
    }
    private void redeem(String expected, String proof) {
        HttpsURLConnection connection = null;
        try {
            connection = (HttpsURLConnection) new URL(ORIGIN + "/api/native-auth/redeem").openConnection();
            connection.setInstanceFollowRedirects(false); connection.setConnectTimeout(30_000); connection.setReadTimeout(30_000);
            connection.setRequestMethod("POST"); connection.setDoOutput(true);
            connection.setRequestProperty("Origin", ORIGIN); connection.setRequestProperty("Content-Type", "application/json");
            byte[] payload = new JSONObject().put("state", expected).put("verifier", proof).toString().getBytes(StandardCharsets.UTF_8);
            try (var output = connection.getOutputStream()) { output.write(payload); }
            if (connection.getResponseCode() != 200) throw new IllegalStateException();
            String path;
            try (var input = connection.getInputStream(); var output = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[4096]; int count;
                while ((count = input.read(buffer)) != -1) { output.write(buffer, 0, count); if (output.size() > 16384) throw new IllegalStateException(); }
                path = new JSONObject(output.toString(StandardCharsets.UTF_8.name())).getString("returnPath");
            }
            if (!path.startsWith("/") || path.startsWith("//") || path.contains("\\")) throw new IllegalStateException();
            List<String> cookies = new ArrayList<>(); boolean session = false;
            for (var header : connection.getHeaderFields().entrySet()) {
                if (!"Set-Cookie".equalsIgnoreCase(header.getKey())) continue;
                for (String raw : header.getValue()) {
                    List<HttpCookie> parsed = HttpCookie.parse(raw);
                    if (parsed.size() != 1) continue;
                    HttpCookie cookie = parsed.get(0);
                    if (!cookie.getName().startsWith("__Secure-arkpedia.") || !cookie.getSecure() || !cookie.isHttpOnly()
                        || (cookie.getDomain() != null && !cookie.getDomain().equals("www.arkpedia.net"))) continue;
                    cookies.add(raw); session |= cookie.getName().equals("__Secure-arkpedia.session_token");
                }
            }
            if (!session) throw new IllegalStateException();
            main.post(() -> {
                if (!Objects.equals(state, expected) || pending == null || !allowed()) return;
                AtomicInteger remaining = new AtomicInteger(cookies.size());
                CookieManager manager = CookieManager.getInstance();
                for (String cookie : cookies) manager.setCookie(ORIGIN, cookie, accepted -> {
                    if (!Objects.equals(state, expected) || pending == null) return;
                    if (!accepted) { fail("Could not save sign-in. Please try again."); return; }
                    if (remaining.decrementAndGet() == 0) {
                        manager.flush(); PluginCall call = pending; clear(); call.resolve(new JSObject().put("returnPath", path));
                    }
                });
            });
        } catch (Exception error) { main.post(() -> { if (Objects.equals(state, expected)) fail("Sign-in could not finish. Please try again."); }); }
        finally { if (connection != null) connection.disconnect(); }
    }
}
