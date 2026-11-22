package com.xmokecursed.xtify.vault;

import android.os.Handler;
import android.os.Looper;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Hands the app's master key to the Android Keystore for safekeeping. This is a plugin and not
 * code in MainActivity because the audio service can start its own Flutter engine without any
 * activity, and that engine needs the key as well.
 */
public final class XtifyVaultPlugin implements FlutterPlugin, MethodCallHandler {
    private static final String CHANNEL = "xtify/vault";

    private final KeyBox box = new KeyBox(new DeviceKeys());
    private final Handler main = new Handler(Looper.getMainLooper());
    private ExecutorService worker;
    private MethodChannel channel;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        worker = Executors.newSingleThreadExecutor(task -> {
            Thread thread = new Thread(task, "xtify-vault");
            thread.setDaemon(true);
            return thread;
        });
        channel = new MethodChannel(binding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        if (worker != null) worker.shutdown();
        worker = null;
    }

    @Override
    public void onMethodCall(MethodCall call, Result result) {
        if ("kind".equals(call.method)) {
            result.success("android-keystore");
            return;
        }
        final boolean wrap = "wrap".equals(call.method);
        if (!wrap && !"unwrap".equals(call.method)) {
            result.notImplemented();
            return;
        }
        final Object argument = call.arguments;
        if (!(argument instanceof byte[])) {
            result.error("bad_arguments", "expected bytes", null);
            return;
        }
        final byte[] input = (byte[]) argument;
        final ExecutorService run = worker;
        if (run == null) {
            result.error("detached", "the key storage is not attached", null);
            return;
        }
        try {
            run.execute(() -> {
                try {
                    final byte[] out = wrap ? box.wrap(input) : box.unwrap(input);
                    main.post(() -> result.success(out));
                } catch (KeyBoxException e) {
                    main.post(() -> result.error(e.code, e.getMessage(), null));
                } catch (Throwable e) {
                    final String text = e.getClass().getSimpleName() + ": " + e.getMessage();
                    main.post(() -> result.error("keystore", text, null));
                }
            });
        } catch (RuntimeException e) {
            result.error("detached", "the key storage is not available", null);
        }
    }
}
