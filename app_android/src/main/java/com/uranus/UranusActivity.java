package com.uranus;

import android.app.NativeActivity;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

public class UranusActivity extends NativeActivity {

    private static final String TAG = "Uranus";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Load the native library that was built by build_android.sh.
        System.loadLibrary("uranus");
        // The native side (ANativeActivity_onCreate) will run the game.
        // Any ROM path is passed via the native activity's intent extras
        // or by reading a file from /data/local/tmp.
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
    }
}
