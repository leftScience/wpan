package com.wpan.server;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

/**
 * 开机自启。部分机型 / Android 12+ 会限制从后台拉起前台服务，
 * 失败就安静跳过，用户手动打开 App 一样能起来。
 */
public class BootReceiver extends BroadcastReceiver {

    private static final String TAG = "WpanBoot";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) {
            return;
        }
        String action = intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)
                && !"android.intent.action.QUICKBOOT_POWERON".equals(action)) {
            return;
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(new Intent(context, ServerService.class)
                        .setAction(ServerService.ACTION_START));
            } else {
                context.startService(new Intent(context, ServerService.class)
                        .setAction(ServerService.ACTION_START));
            }
            Log.i(TAG, "boot: requested server start");
        } catch (Throwable t) {
            Log.w(TAG, "boot: cannot start foreground service: " + t.getMessage());
        }
    }
}
