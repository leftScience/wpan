package com.wpan.server;

import android.Manifest;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.URL;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * 极简控制面板：启动/停止服务端、显示地址、健康检查、看日志、电池优化白名单。
 */
public class MainActivity extends Activity {

    private static final int PORT = 18090;
    private static final int REQ_NOTIFICATION = 10;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private TextView statusView;
    private TextView detailView;
    private TextView urlView;
    private Button startButton;
    private Button stopButton;
    private SharedPreferences prefs;
    private volatile String health = "";

    private final Runnable ticker = new Runnable() {
        @Override
        public void run() {
            refresh();
            handler.postDelayed(this, 1500);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("wpan_server", MODE_PRIVATE);

        setContentView(buildLayout());
        requestNotificationPermissionIfNeeded();
        handler.post(ticker);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh();
    }

    @Override
    protected void onDestroy() {
        handler.removeCallbacks(ticker);
        super.onDestroy();
    }

    // ------------------------------------------------------------------- UI

    private View buildLayout() {
        int pad = dp(20);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.parseColor("#12161C"));
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("wpan 服务端");
        title.setTextColor(Color.WHITE);
        title.setTextSize(22f);
        root.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("在手机上本地运行，App 连 http://127.0.0.1:" + PORT);
        subtitle.setTextColor(Color.parseColor("#9AA4B2"));
        subtitle.setTextSize(12f);
        subtitle.setPadding(0, dp(4), 0, dp(16));
        root.addView(subtitle);

        statusView = new TextView(this);
        statusView.setTextSize(16f);
        statusView.setTextColor(Color.parseColor("#8AB4F8"));
        statusView.setPadding(0, 0, 0, dp(6));
        root.addView(statusView);

        detailView = new TextView(this);
        detailView.setTextSize(12f);
        detailView.setTextColor(Color.parseColor("#C7CDD6"));
        detailView.setPadding(0, 0, 0, dp(14));
        root.addView(detailView);

        LinearLayout buttonRow = new LinearLayout(this);
        buttonRow.setOrientation(LinearLayout.HORIZONTAL);
        startButton = makeButton("启动", "#2E7D32");
        stopButton = makeButton("停止", "#B03030");
        buttonRow.addView(startButton, weightParams());
        buttonRow.addView(makeButton("复制地址", "#39414D"), weightParams());
        root.addView(buttonRow);

        startButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                ServerService.start(MainActivity.this);
                toast("正在启动…");
                handler.postDelayed(ticker, 500);
            }
        });

        stopButton.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                ServerService.stop(MainActivity.this);
                toast("正在停止…");
            }
        });

        root.addView(makeButton("打开检查接口（确认服务端活着）", "#39414D"), fullParams());
        root.addView(makeButton("查看日志", "#39414D"), fullParams());
        root.addView(makeButton("复制日志到剪贴板", "#39414D"), fullParams());
        root.addView(makeButton("加入电池优化白名单（保活）", "#39414D"), fullParams());

        urlView = new TextView(this);
        urlView.setTextSize(13f);
        urlView.setTextColor(Color.parseColor("#9AA4B2"));
        urlView.setPadding(0, dp(16), 0, dp(8));
        root.addView(urlView);

        TextView note = new TextView(this);
        note.setText("首次启动会初始化数据库（十几秒）。默认账号 admin / 123，登录后请立即改密码。"
                + "小米/华为/OPPO 等机型请在本机设置里允许本应用自启动与后台运行，否则熄屏后可能被系统杀掉。");
        note.setTextSize(11f);
        note.setTextColor(Color.parseColor("#7A8390"));
        root.addView(note);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.parseColor("#12161C"));
        scroll.addView(root);
        return scroll;
    }

    private Button makeButton(String text, String color) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(Color.WHITE);
        b.setTextSize(13f);
        b.setBackgroundColor(Color.parseColor(color));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, dp(48));
        lp.setMargins(dp(2), dp(6), dp(2), dp(6));
        b.setLayoutParams(lp);
        final String label = text;
        if (label.startsWith("复制地址")) {
            b.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                    if (cm != null) {
                        cm.setPrimaryClip(ClipData.newPlainText("wpan", "http://127.0.0.1:" + PORT));
                        toast("已复制 http://127.0.0.1:" + PORT);
                    }
                }
            });
        } else if (label.startsWith("打开检查")) {
            b.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    try {
                        startActivity(new Intent(Intent.ACTION_VIEW,
                                Uri.parse("http://127.0.0.1:" + PORT + "/api/v1/public/discovery")));
                    } catch (Throwable t) {
                        toast("没有可用的浏览器：" + t.getMessage());
                    }
                }
            });
        } else if (label.startsWith("查看日志")) {
            b.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    showLog();
                }
            });
        } else if (label.startsWith("复制日志")) {
            b.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    String text = readLogs();
                    ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                    if (cm != null) {
                        cm.setPrimaryClip(ClipData.newPlainText("wpan-log", text));
                        toast("日志已复制，粘贴发给开发者即可");
                    }
                }
            });
        } else if (label.startsWith("加入电池")) {
            b.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    requestIgnoreBatteryOptimizations();
                }
            });
        }
        return b;
    }

    private LinearLayout.LayoutParams weightParams() {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, dp(48), 1f);
        lp.setMargins(dp(2), dp(6), dp(2), dp(6));
        return lp;
    }

    private LinearLayout.LayoutParams fullParams() {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(48));
        lp.setMargins(dp(2), dp(4), dp(2), dp(4));
        return lp;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    }

    // ---------------------------------------------------------------- 状态刷新

    private void refresh() {
        String status = prefs.getString("status", "stopped");
        String message = prefs.getString("message", "未启动");
        int pid = prefs.getInt("pid", -1);

        if ("running".equals(status)) {
            statusView.setText("● 运行中" + (pid > 0 ? "（pid " + pid + "）" : ""));
            statusView.setTextColor(Color.parseColor("#4CD07D"));
        } else if ("starting".equals(status)) {
            statusView.setText("● 正在启动…");
            statusView.setTextColor(Color.parseColor("#E8B44C"));
        } else if ("error".equals(status)) {
            statusView.setText("● 启动失败");
            statusView.setTextColor(Color.parseColor("#F06A6A"));
        } else {
            statusView.setText("● 未运行");
            statusView.setTextColor(Color.parseColor("#9AA4B2"));
        }

        detailView.setText(message);
        detailView.setTextColor("error".equals(status)
                ? Color.parseColor("#F0A0A0") : Color.parseColor("#C7CDD6"));

        StringBuilder sb = new StringBuilder();
        sb.append("连接地址\n  本机：http://127.0.0.1:").append(PORT);
        for (String ip : lanAddresses()) {
            sb.append("\n  局域网：http://").append(ip).append(":").append(PORT);
        }
        if (!health.isEmpty()) {
            sb.append("\n\n自检：").append(health);
        }
        urlView.setText(sb.toString());

        startButton.setEnabled(!"running".equals(status) && !"starting".equals(status));
        stopButton.setEnabled("running".equals(status) || "starting".equals(status));

        checkHealthAsync();
    }

    /** 直接打服务端 /discovery，这比看进程状态更可信。 */
    private void checkHealthAsync() {
        new Thread(new Runnable() {
            @Override
            public void run() {
                String result;
                try {
                    HttpURLConnection conn = (HttpURLConnection) new URL(
                            "http://127.0.0.1:" + PORT + "/api/v1/public/discovery").openConnection();
                    conn.setConnectTimeout(1500);
                    conn.setReadTimeout(1500);
                    int code = conn.getResponseCode();
                    if (code == 200) {
                        BufferedReader reader = new BufferedReader(
                                new java.io.InputStreamReader(conn.getInputStream()));
                        StringBuilder text = new StringBuilder();
                        String line;
                        while ((line = reader.readLine()) != null && text.length() < 400) {
                            text.append(line);
                        }
                        reader.close();
                        String body = text.toString();
                        String version = extractVersion(body);
                        result = "接口正常" + (version.isEmpty() ? "" : "，版本 " + version);
                    } else {
                        result = "接口返回 HTTP " + code;
                    }
                    conn.disconnect();
                } catch (Throwable t) {
                    result = "无响应（服务端未运行或仍在初始化）";
                }
                if (!result.equals(health)) {
                    health = result;
                    handler.post(new Runnable() {
                        @Override
                        public void run() {
                            refreshUrlsOnly();
                        }
                    });
                }
            }
        }, "wpan-health").start();
    }

    private void refreshUrlsOnly() {
        StringBuilder sb = new StringBuilder();
        sb.append("连接地址\n  本机：http://127.0.0.1:").append(PORT);
        for (String ip : lanAddresses()) {
            sb.append("\n  局域网：http://").append(ip).append(":").append(PORT);
        }
        if (!health.isEmpty()) {
            sb.append("\n\n自检：").append(health);
        }
        urlView.setText(sb.toString());
    }

    private static String extractVersion(String json) {
        int idx = json.indexOf("\"version\"");
        if (idx < 0) {
            return "";
        }
        int start = json.indexOf('"', json.indexOf(':', idx)) + 1;
        int end = json.indexOf('"', start);
        if (start <= 0 || end <= start) {
            return "";
        }
        return json.substring(start, end);
    }

    private List<String> lanAddresses() {
        List<String> ips = new ArrayList<>();
        try {
            for (NetworkInterface nif : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nif.isUp() || nif.isLoopback()) {
                    continue;
                }
                for (InetAddress addr : Collections.list(nif.getInetAddresses())) {
                    if (addr instanceof Inet4Address && !addr.isLoopbackAddress()) {
                        ips.add(addr.getHostAddress());
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        return ips;
    }

    // -------------------------------------------------------------- 附加功能

    /** 把 server.out 与 boot.log 的末尾拼起来，供查看/复制。 */
    private String readLogs() {
        StringBuilder sb = new StringBuilder();
        File dir = new File(getFilesDir(), "wpan/log");
        appendTail(sb, new File(dir, "boot.log"), 30, "【启动痕迹 boot.log】");
        appendTail(sb, new File(dir, "server.out"), 200, "【服务端输出 server.out（最近 200 行）】");
        if (sb.length() == 0) {
            sb.append("还没有日志文件");
        }
        return sb.toString();
    }

    private void appendTail(StringBuilder sb, File file, int maxLines, String title) {
        sb.append(title).append('\n');
        try {
            BufferedReader reader = new BufferedReader(new FileReader(file));
            List<String> lines = new ArrayList<>();
            String line;
            while ((line = reader.readLine()) != null) {
                lines.add(line);
            }
            reader.close();
            int from = Math.max(0, lines.size() - maxLines);
            for (int i = from; i < lines.size(); i++) {
                sb.append(lines.get(i)).append('\n');
            }
        } catch (Throwable t) {
            sb.append("（无：").append(t.getMessage()).append("）\n");
        }
        sb.append('\n');
    }

    private void showLog() {
        String text = readLogs();

        ScrollView scroll = new ScrollView(this);
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(10f);
        tv.setTextIsSelectable(true);
        tv.setPadding(dp(12), dp(12), dp(12), dp(12));
        scroll.addView(tv);

        new android.app.AlertDialog.Builder(this)
                .setTitle("运行日志")
                .setView(scroll)
                .setPositiveButton("复制", new android.content.DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(android.content.DialogInterface dialog, int which) {
                        String all = readLogs();
                        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                        if (cm != null) {
                            cm.setPrimaryClip(ClipData.newPlainText("wpan-log", all));
                            toast("已复制");
                        }
                    }
                })
                .setNegativeButton("关闭", null)
                .show();
    }

    private void requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, REQ_NOTIFICATION);
        }
    }

    private void requestIgnoreBatteryOptimizations() {
        try {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            if (pm != null && pm.isIgnoringBatteryOptimizations(getPackageName())) {
                toast("已在白名单中");
                return;
            }
            Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            intent.setData(Uri.parse("package:" + getPackageName()));
            startActivity(intent);
        } catch (Throwable t) {
            try {
                startActivity(new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS));
            } catch (Throwable ignored) {
                toast("请手动在系统设置里允许后台运行");
            }
        }
    }
}
