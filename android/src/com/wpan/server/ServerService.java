package com.wpan.server;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.ServiceInfo;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.Socket;
import java.net.Inet4Address;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TimeZone;

/**
 * 前台服务：把打包在 APK 里的 Go 服务端二进制（lib/arm64-v8a/libwpan-server.so）
 * 当子进程跑起来，负责环境变量、唤醒锁、日志、状态回写与存活监控。
 */
public class ServerService extends Service {

    public static final String ACTION_START = "com.wpan.server.START";
    public static final String ACTION_STOP = "com.wpan.server.STOP";

    private static final String TAG = "WpanServer";
    private static final String CHANNEL_ID = "wpan-server";
    private static final int NOTIF_ID = 1001;
    private static final int PORT = 18090;
    private static final String PREFS = "wpan_server";

    private Process process;
    private Thread monitorThread;
    private volatile boolean stopping;
    private PowerManager.WakeLock wakeLock;
    private WifiManager.MulticastLock multicastLock;
    private SharedPreferences prefs;
    /** 子进程退出码；Integer.MIN_VALUE 表示还没退出（用于区分"崩溃退出"与"卡着不监听"）。 */
    private volatile int lastExitCode = Integer.MIN_VALUE;
    /** 本次启动写入 server.out 的起始字节偏移，用来只截取"这一轮"的输出。 */
    private volatile long runStartOffset = 0;

    @Override
    public void onCreate() {
        super.onCreate();
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        createChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopServer();
            stopSelf();
            return START_NOT_STICKY;
        }

        startInForeground(buildNotification("正在启动…", true));
        if (process != null && process.isAlive()) {
            return START_STICKY;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                boot();
            }
        }, "wpan-boot").start();
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        stopServer();
        super.onDestroy();
    }

    // ---------------------------------------------------------------- 启动流程

    private void boot() {
        File base = new File(getFilesDir(), "wpan");
        try {
            setStatus("starting", "正在准备运行环境…", -1);
            prepareRuntime(base);

            File exe = new File(getApplicationInfo().nativeLibraryDir, "libwpan-server.so");
            String abi = Build.SUPPORTED_ABIS != null && Build.SUPPORTED_ABIS.length > 0
                    ? Build.SUPPORTED_ABIS[0] : "?";
            appendBootLog(base, "nativeLibraryDir=" + getApplicationInfo().nativeLibraryDir
                    + " abi=" + abi + " sdk=" + Build.VERSION.SDK_INT);
            if (!exe.exists()) {
                fail("APK 内没有服务端二进制（是否装成了非 arm64 版本？）");
                return;
            }
            appendBootLog(base, "exe size=" + exe.length() + " canExecute=" + exe.canExecute());
            makeExecutable(exe);
            appendBootLog(base, "canExecute(after chmod)=" + exe.canExecute());

            if (isPortOpen(PORT)) {
                appendBootLog(base, "端口 " + PORT + " 已有进程在监听，按“已在运行”处理");
                acquireLocks();
                setStatus("running", "服务端运行中（端口已有进程监听，不会重复拉起）", -1);
                updateNotification("运行中 · http://127.0.0.1:" + PORT, false);
                startMonitor(base);
                return;
            }

            spawn(base);
            acquireLocks();
            Log.i(TAG, "server process started, pid=" + getPid());

            boolean ok = waitForPort(PORT, 60);
            if (stopping) {
                return;
            }
            if (ok) {
                setStatus("running", "服务端运行中", getPid());
                updateNotification("运行中 · http://127.0.0.1:" + PORT, false);
                startMonitor(base);
                return;
            }
            // 给日志线程一点时间落盘并回写退出码，再判断到底"崩了"还是"卡着"
            sleep(800);
            int code = lastExitCode;
            String head = logRunHead(base, runStartOffset, 14);
            String reason = code != Integer.MIN_VALUE
                    ? "服务端进程启动后立即退出（exit code=" + code + "）"
                    : "服务端 60 秒内没有监听 " + PORT + " 端口（进程仍在运行）";
            if (head.isEmpty()) {
                head = "（子进程没有任何输出，等于 exec 成功但立刻死掉，看 boot.log）";
            }
            fail(reason + "\n\n本次启动日志开头：\n" + head);
        } catch (Throwable t) {
            Log.e(TAG, "boot failed", t);
            fail("启动失败：" + t.getClass().getSimpleName() + " " + String.valueOf(t.getMessage())
                    + "\n\n日志末尾：\n" + logTail(base, 10));
        }
    }

    /**
     * 从本次启动的偏移开始，挑出真正有用的行：Go 的 panic/fatal error 首行、我们的 [stage] 阶段标记、
     * 以及开头几行。zeroconf 之类的噪音可能几十行，按顺序截断会把 panic 首行挤掉，所以按关键字筛。
     */
    private String logRunHead(File base, long from, int maxLines) {
        File logFile = new File(base, "log/server.out");
        if (!logFile.exists()) {
            return "";
        }
        String[] keys = {"panic", "fatal error", "[stage]", "错误", "异常", "failed", "error", "denied", "permitted"};
        try {
            java.io.RandomAccessFile raf = new java.io.RandomAccessFile(logFile, "r");
            try {
                long len = raf.length();
                if (from <= 0 || from >= len) {
                    return "";
                }
                raf.seek(from);
                byte[] buf = new byte[(int) Math.min(16384, len - from)];
                raf.readFully(buf);
                String all = new String(buf, "UTF-8");
                String[] lines = all.split("\n");
                StringBuilder sb = new StringBuilder();
                int used = 0;
                int firstLines = 0;
                for (int i = 0; i < lines.length && used < maxLines; i++) {
                    String line = lines[i].trim();
                    if (line.isEmpty()) {
                        continue;
                    }
                    boolean keep = firstLines < 3;
                    if (!keep) {
                        String low = line.toLowerCase(Locale.US);
                        for (String k : keys) {
                            if (low.contains(k)) {
                                keep = true;
                                break;
                            }
                        }
                    }
                    if (!keep) {
                        continue;
                    }
                    sb.append(line).append('\n');
                    used++;
                    firstLines++;
                }
                return sb.toString().trim();
            } finally {
                raf.close();
            }
        } catch (Throwable t) {
            return "";
        }
    }

    /** 读 server.out 末尾若干行，用于把失败原因直接显示在界面上，不用手动翻日志。 */
    private String logTail(File base, int maxLines) {
        File logFile = new File(base, "log/server.out");
        if (!logFile.exists()) {
            return "（还没有 server.out）";
        }
        try {
            java.io.RandomAccessFile raf = new java.io.RandomAccessFile(logFile, "r");
            try {
                long len = raf.length();
                long from = Math.max(0, len - 2048);
                raf.seek(from);
                byte[] buf = new byte[(int) (len - from)];
                raf.readFully(buf);
                String all = new String(buf, "UTF-8");
                String[] lines = all.split("\n");
                StringBuilder sb = new StringBuilder();
                int start = Math.max(0, lines.length - maxLines);
                for (int i = start; i < lines.length; i++) {
                    String line = lines[i].trim();
                    if (!line.isEmpty()) {
                        sb.append(line).append('\n');
                    }
                }
                String text = sb.toString().trim();
                if (text.length() > 900) {
                    text = text.substring(text.length() - 900);
                }
                return text;
            } finally {
                raf.close();
            }
        } catch (Throwable t) {
            return "（读日志失败：" + t.getMessage() + "）";
        }
    }

    /** 服务端自身的启动痕迹，出错时也能看出卡在哪一步。 */
    private void appendBootLog(File base, String line) {
        try {
            File dir = new File(base, "log");
            if (!dir.exists()) {
                dir.mkdirs();
            }
            File f = new File(dir, "boot.log");
            if (f.exists() && f.length() > 512 * 1024) {
                f.delete();
            }
            SimpleDateFormat fmt = new SimpleDateFormat("MM-dd HH:mm:ss", Locale.US);
            FileOutputStream fos = new FileOutputStream(f, true);
            try {
                fos.write((fmt.format(new Date()) + " " + line + "\n").getBytes("UTF-8"));
                fos.flush();
            } finally {
                fos.close();
            }
        } catch (Throwable ignored) {
        }
    }

    /** 首次运行把 assets 里的配置/证书/SQL 释放到私有目录，后续不覆盖用户改动。 */
    private void prepareRuntime(File base) throws IOException {
        mkdirs(new File(base, "conf"));
        mkdirs(new File(base, "data"));
        mkdirs(new File(base, "log"));
        mkdirs(new File(base, "run"));
        mkdirs(new File(base, "sql"));
        mkdirs(new File(base, "certs"));

        copyAssetIfMissing("conf/config.yaml", new File(base, "conf/config.yaml"));
        copyAssetIfMissing("sql/init_data.sql", new File(base, "sql/init_data.sql"));
        copyAssetIfMissing("certs/cacert.pem", new File(base, "certs/cacert.pem"));
    }

    private void copyAssetIfMissing(String asset, File target) throws IOException {
        if (target.exists() && target.length() > 0) {
            return;
        }
        InputStream in = getAssets().open(asset);
        try {
            OutputStream out = new FileOutputStream(target);
            try {
                byte[] buf = new byte[8192];
                int n;
                while ((n = in.read(buf)) > 0) {
                    out.write(buf, 0, n);
                }
                out.flush();
            } finally {
                out.close();
            }
        } finally {
            in.close();
        }
    }

    /** 打包时用 zip 存入的二进制可能丢失执行位，这里尝试补回来。 */
    private void makeExecutable(File exe) {
        if (exe.canExecute()) {
            return;
        }
        try {
            Runtime.getRuntime().exec(new String[]{"/system/bin/chmod", "755", exe.getAbsolutePath()}).waitFor();
        } catch (Throwable ignored) {
            // 原生库目录一般本来就带执行权限，失败则交给后面的启动报错兜底
        }
    }

    /** Android 9+ 隐藏了 Process.pid()，用反射拿；拿不到也不影响运行。 */
    private void readAccessiblePid(Process p) {
        try {
            java.lang.reflect.Method m = Process.class.getMethod("pid");
            Object v = m.invoke(p);
            if (v instanceof Long) {
                prefs.edit().putInt("pid", ((Long) v).intValue()).apply();
            }
        } catch (Throwable ignored) {
        }
    }

    private int getPid() {
        return prefs.getInt("pid", -1);
    }

    /**
     * 拉起子进程。stdout/stderr 直接重定向到文件，不经过 App 进程的管道——这是关键修正：
     * 之前用管道 readLine，一旦 App 进程被系统冻结/回收，读端消失、管道 64KB 写满，
     * 服务端就会永久卡在 write 上（或直接吃 SIGPIPE），表现就是“进程还在、接口一直无响应”。
     */
    private void spawn(File base) throws IOException {
        File exe = new File(getApplicationInfo().nativeLibraryDir, "libwpan-server.so");
        File logFile = new File(base, "log/server.out");
        truncateIfLarge(logFile);
        runStartOffset = logFile.exists() ? logFile.length() : 0;

        ProcessBuilder pb = new ProcessBuilder(exe.getAbsolutePath());
        pb.directory(base);
        pb.redirectErrorStream(true);
        pb.redirectOutput(ProcessBuilder.Redirect.appendTo(logFile));

        Map<String, String> env = pb.environment();
        env.clear();
        env.put("PATH", "/system/bin:/system/xbin");
        env.put("OHOME_BASE_DIR", base.getAbsolutePath());
        env.put("GIN_MODE", "release");
        env.put("SSL_CERT_FILE", new File(base, "certs/cacert.pem").getAbsolutePath());
        env.put("TZ", TimeZone.getDefault().getID());
        env.put("WPAN_DNS", collectDnsServers());
        appendBootLog(base, "spawn cd=" + base.getAbsolutePath() + " TZ=" + env.get("TZ")
                + " DNS=" + env.get("WPAN_DNS"));

        process = pb.start();
        readAccessiblePid(process);
    }

    /**
     * 看护线程：每 5 秒打一次 /discovery。进程死了就如实报；进程活着但接口连续 60 秒不应答，
     * 就杀掉重启——这样界面状态永远不会停在“运行中”骗人。
     */
    private void startMonitor(final File base) {
        monitorThread = new Thread(new Runnable() {
            @Override
            public void run() {
                int failCount = 0;
                int restarts = 0;
                while (!stopping) {
                    sleep(5000);
                    if (stopping) {
                        return;
                    }
                    Process p = process;
                    int code = -1;
                    boolean alive = false;
                    if (p != null) {
                        try {
                            alive = p.isAlive();
                        } catch (Throwable ignored) {
                        }
                    }
                    if (p != null && !alive) {
                        try {
                            code = p.waitFor();
                        } catch (Throwable ignored) {
                        }
                        lastExitCode = code;
                        // 非用户主动停止的话，先自己救几次（手机上看护服务被系统杀、子进程被回收很常见）
                        if (!stopping && restarts < 3) {
                            restarts++;
                            appendBootLog(base, "watchdog: 进程已退出(code=" + code + ")，第 " + restarts
                                    + " 次自动重启");
                            restartChild(base);
                            continue;
                        }
                        if (!"error".equals(prefs.getString("status", ""))) {
                            setStatus("stopped", "服务端进程已退出（exit code=" + code + "）\n\n日志末尾：\n"
                                    + logTail(base, 6), -1);
                            updateNotification("已退出（code=" + code + "），点开查看日志", false);
                        }
                        releaseLocks();
                        return;
                    }

                    if (isHttpOk()) {
                        failCount = 0;
                        if (!"running".equals(prefs.getString("status", ""))) {
                            setStatus("running", "服务端运行中", getPid());
                            updateNotification("运行中 · http://127.0.0.1:" + PORT, false);
                        }
                        continue;
                    }

                    failCount++;
                    int silent = failCount * 5;
                    if (failCount >= 2) {
                        setStatus("error", "服务端进程" + (p == null ? "未拉起" : "还在") + "，但接口已 "
                                + silent + " 秒无响应" + (failCount >= 12 ? "，已触发自动重启" : "，继续观察中…"),
                                getPid());
                    }
                    if (failCount >= 12) {
                        appendBootLog(base, "watchdog: 接口连续 " + silent + " 秒无响应，重启子进程");
                        restartChild(base);
                        failCount = 0;
                    }
                }
            }
        }, "wpan-monitor");
        monitorThread.start();
    }

    private void restartChild(File base) {
        Process p = process;
        process = null;
        if (p != null) {
            try {
                p.destroyForcibly();
                p.waitFor();
            } catch (Throwable ignored) {
            }
        }
        sleep(1500);
        try {
            spawn(base);
            acquireLocks();
            if (waitForPort(PORT, 60)) {
                setStatus("running", "服务端运行中（已自动重启）", getPid());
                updateNotification("运行中 · http://127.0.0.1:" + PORT, false);
            } else {
                fail("自动重启后仍然没有监听端口\n\n日志末尾：\n" + logTail(base, 8));
            }
        } catch (Throwable t) {
            fail("自动重启失败：" + t.getClass().getSimpleName() + " " + t.getMessage());
        }
    }

    private boolean isHttpOk() {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new java.net.URL(
                    "http://127.0.0.1:" + PORT + "/api/v1/public/discovery").openConnection();
            conn.setConnectTimeout(2000);
            conn.setReadTimeout(2000);
            int code = conn.getResponseCode();
            return code == 200;
        } catch (Throwable t) {
            return false;
        } finally {
            if (conn != null) {
                conn.disconnect();
            }
        }
    }

    private boolean isPortOpen(int port) {
        Socket socket = new Socket();
        try {
            socket.connect(new java.net.InetSocketAddress("127.0.0.1", port), 800);
            return true;
        } catch (Throwable t) {
            return false;
        } finally {
            try {
                socket.close();
            } catch (Throwable ignored) {
            }
        }
    }

    private void truncateIfLarge(File logFile) {
        try {
            if (logFile.exists() && logFile.length() > 4L * 1024 * 1024) {
                logFile.delete();
            }
        } catch (Throwable ignored) {
        }
    }

    /** 读系统当前网络的 DNS，交给服务端做解析（Android 没有 /etc/resolv.conf）。 */
    private String collectDnsServers() {
        List<String> v4 = new ArrayList<>();
        List<String> v6 = new ArrayList<>();
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null) {
                Network network = cm.getActiveNetwork();
                LinkProperties lp = network == null ? null : cm.getLinkProperties(network);
                if (lp != null) {
                    for (InetAddress addr : lp.getDnsServers()) {
                        if (addr == null) {
                            continue;
                        }
                        String host = addr.getHostAddress();
                        if (host == null) {
                            continue;
                        }
                        int pct = host.indexOf('%');
                        if (pct > 0) {
                            host = host.substring(0, pct);
                        }
                        if (addr instanceof Inet4Address) {
                            v4.add(host);
                        } else {
                            v6.add(host);
                        }
                    }
                }
            }
        } catch (Throwable ignored) {
        }
        List<String> all = new ArrayList<>(v4);
        all.addAll(v6);
        if (all.isEmpty()) {
            all.add("223.5.5.5");
            all.add("119.29.29.29");
        }
        return join(all, " ");
    }

    private boolean waitForPort(int port, int seconds) {
        long deadline = System.currentTimeMillis() + seconds * 1000L;
        while (System.currentTimeMillis() < deadline) {
            if (process != null && !process.isAlive()) {
                return false;
            }
            Socket socket = new Socket();
            try {
                socket.connect(new java.net.InetSocketAddress("127.0.0.1", port), 800);
                return true;
            } catch (Throwable ignored) {
            } finally {
                try {
                    socket.close();
                } catch (Throwable ignored) {
                }
            }
            sleep(500);
        }
        return false;
    }

    // ----------------------------------------------------------------- 停止

    private void stopServer() {
        stopping = true;
        Process p = process;
        process = null;
        if (p != null) {
            try {
                p.destroy();
                for (int i = 0; i < 10 && p.isAlive(); i++) {
                    sleep(300);
                }
                if (p.isAlive()) {
                    p.destroyForcibly();
                }
            } catch (Throwable ignored) {
            }
        }
        releaseLocks();
        prefs.edit().putString("status", "stopped").putString("message", "服务端已停止").putInt("pid", -1).apply();
        stopForegroundCompat();
    }

    private void releaseLocks() {
        try {
            if (wakeLock != null && wakeLock.isHeld()) {
                wakeLock.release();
            }
        } catch (Throwable ignored) {
        }
        try {
            if (multicastLock != null && multicastLock.isHeld()) {
                multicastLock.release();
            }
        } catch (Throwable ignored) {
        }
        wakeLock = null;
        multicastLock = null;
    }

    private void acquireLocks() {
        try {
            PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
            if (pm != null) {
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wpan:server");
                wakeLock.setReferenceCounted(false);
                wakeLock.acquire();
            }
        } catch (Throwable ignored) {
        }
        try {
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                multicastLock = wm.createMulticastLock("wpan:mdns");
                multicastLock.setReferenceCounted(false);
                multicastLock.acquire();
            }
        } catch (Throwable ignored) {
        }
    }

    // -------------------------------------------------------------- 通知与状态

    private void createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null) {
            return;
        }
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID, "wpan 服务端", NotificationManager.IMPORTANCE_LOW);
        channel.setDescription("本机运行的 wpan 服务端状态");
        channel.setShowBadge(false);
        nm.createNotificationChannel(channel);
    }

    private Notification buildNotification(String text, boolean withStopAction) {
        Intent open = new Intent(this, MainActivity.class);
        open.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        PendingIntent contentIntent = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | pendingImmutable());

        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        builder.setContentTitle("wpan 服务端")
                .setContentText(text)
                .setSmallIcon(R.drawable.icon)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentIntent);

        if (withStopAction) {
            Intent stop = new Intent(this, ServerService.class).setAction(ACTION_STOP);
            PendingIntent stopIntent = PendingIntent.getService(this, 1, stop,
                    PendingIntent.FLAG_UPDATE_CURRENT | pendingImmutable());
            builder.addAction(new Notification.Action.Builder(
                    android.graphics.drawable.Icon.createWithResource(this, R.drawable.icon),
                    "停止", stopIntent).build());
        }
        return builder.build();
    }

    private int pendingImmutable() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ? PendingIntent.FLAG_IMMUTABLE : 0;
    }

    private void startInForeground(Notification notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(NOTIF_ID, notification);
        }
    }

    private void updateNotification(String text, boolean withStopAction) {
        try {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null) {
                nm.notify(NOTIF_ID, buildNotification(text, withStopAction));
            }
        } catch (Throwable ignored) {
        }
    }

    private void stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } else {
            stopForeground(true);
        }
    }

    private void setStatus(String status, String message, int pid) {
        prefs.edit().putString("status", status).putString("message", message).putInt("pid", pid).apply();
    }

    private void fail(String message) {
        setStatus("error", message, -1);
        updateNotification(message, false);
        releaseLocks();
        Log.e(TAG, message);
    }

    // ------------------------------------------------------------------ 工具

    private static void mkdirs(File dir) {
        if (!dir.exists() && !dir.mkdirs() && !dir.exists()) {
            Log.w(TAG, "mkdirs failed: " + dir.getAbsolutePath());
        }
    }

    private static String join(List<String> items, String sep) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < items.size(); i++) {
            if (i > 0) {
                sb.append(sep);
            }
            sb.append(items.get(i));
        }
        return sb.toString();
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        }
    }

    public static void start(Context context) {
        Intent intent = new Intent(context, ServerService.class).setAction(ACTION_START);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent);
        } else {
            context.startService(intent);
        }
    }

    public static void stop(Context context) {
        Intent intent = new Intent(context, ServerService.class).setAction(ACTION_STOP);
        context.startService(intent);
    }
}
