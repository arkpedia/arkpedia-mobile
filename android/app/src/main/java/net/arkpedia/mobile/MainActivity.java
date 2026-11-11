package net.arkpedia.mobile;

import com.getcapacitor.BridgeActivity;
import android.os.Bundle;
import androidx.activity.OnBackPressedCallback;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(ArkpediaAudioPlugin.class);
        super.onCreate(savedInstanceState);
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                if (bridge != null && bridge.getWebView().canGoBack()) {
                    bridge.getWebView().goBack();
                } else {
                    finish();
                }
            }
        });
    }
}
