package com.wyj.music.lyric_music

import android.Manifest
import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.reflect.Modifier

// AudioServiceActivity restores the intent from the media notification /
// headphone button so tapping it brings the app back to the playing screen.
class MainActivity : AudioServiceActivity() {
    private val power: PowerManager
        get() = getSystemService(Context.POWER_SERVICE) as PowerManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Media-session notifications are exempt from POST_NOTIFICATIONS on
        // Android 13+, but some OEM skins still hide them; asking once makes the
        // playback notification reliable and costs nothing when already granted.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 息屏后断网绝大多数是系统省电策略掐了后台网络，而这件事只有原生侧看得见。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "batteryOptimizationIgnored" -> result.success(ignoringBattery())
                    "powerSaveMode" -> result.success(inPowerSave())
                    "askIgnoreBatteryOptimization" -> result.success(askIgnoring())
                    "openBatterySettings" -> result.success(openBatterySettings())
                    "mediaCardState" -> result.success(mediaCardState())
                    "reattachMediaListener" -> result.success(reattachMediaListener())
                    "openNotificationSettings" -> result.success(openNotificationSettings())
                    "openChannelSettings" -> result.success(openChannelSettings())
                    else -> result.notImplemented()
                }
            }
    }

    /** Android 6 之前没有这套限制，直接当作已放行。 */
    private fun ignoringBattery(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || power.isIgnoringBatteryOptimizations(packageName)

    private fun inPowerSave(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && power.isPowerSaveMode

    @SuppressLint("BatteryLife")
    private fun askIgnoring(): Boolean {
        if (ignoringBattery()) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName"))
            )
            true
        } catch (e: Exception) {
            // 有些国产 ROM 屏蔽了这个系统弹窗，那就直接把她带到能改的地方。
            openBatterySettings()
        }
    }

    /** 厂商的后台管理页没法保证存在，逐级退到通用入口。 */
    private fun openBatterySettings(): Boolean {
        val fallbacks = mutableListOf<Intent>()
        fallbacks.add(
            Intent("miui.intent.action.APP_PERF_EDITOR")
                .setComponent(
                    ComponentName(
                        "com.miui.powerkeeper",
                        "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"
                    )
                )
                .putExtra("package_name", packageName)
                .putExtra("package_label", "听歌小窝")
        )
        fallbacks.add(
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(Uri.parse("package:$packageName"))
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            fallbacks.add(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
        for (intent in fallbacks) {
            try {
                if (intent.component == null && intent.resolveActivity(packageManager) == null) continue
                startActivity(intent)
                return true
            } catch (e: Exception) {
                // 这个 ROM 没有这一页，接着往下试。
            }
        }
        return false
    }

    /** 通知栏控制卡就是条媒体通知，系统总开关关掉时它连影都没有。 */
    private fun notificationsEnabled(): Boolean =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) true
        else getSystemService(NotificationManager::class.java).areNotificationsEnabled()

    /**
     * 那张播放卡到底走到哪一步断掉了，一次问全。
     *
     * 原来只有「总开关 / 通道 / 有没有卡」三份证据，分不出两种病：「压根没发出去」
     * 和「发出去了、手机不给上屏」。前者重发一次能救，后者重发一万次也没用，
     * 还白冤枉自己一回。所以把整罐通知、所有通道、前台服务活没活着都倒出来，
     * 让下一张截图或导出的日志能一锤定音。
     *
     * getActiveNotifications 只回本应用自己发的通知，安卓 8 之后 getRunningServices
     * 也只回本应用自己的服务，两样都不用新权限。
     */
    private fun mediaCardState(): Map<String, Any?> {
        val nm = getSystemService(NotificationManager::class.java)
        val out = mutableMapOf<String, Any?>()
        out["notifications"] = notificationsEnabled()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // 「暂停通知」是系统级一键静音：通知照发、就是不上屏，
            // 在她眼里和「卡片没贴上去」一模一样。
            out["paused"] = try {
                nm.areNotificationsPaused()
            } catch (e: Exception) {
                null
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 通道被静默（importance=0）时通知不会再显示，而总开关仍是开着的。
            out["channel"] = nm.getNotificationChannel(PLAYBACK_CHANNEL)?.importance
            // 通道是播放服务第一次建通知那一刻才创建的：一个都没有，
            // 说明服务根本没走到发通知那步，和「发了又被撤掉」是两回事。
            out["channels"] = nm.notificationChannels.orEmpty().map {
                mapOf("id" to it.id, "imp" to it.importance)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val notes = nm.activeNotifications.map { entry ->
                val n = entry.notification
                mapOf(
                    "id" to entry.id,
                    "ch" to n.channelId,
                    // 前台服务的通知带这个标记。服务活着、列表里却没有它，
                    // 就是 ROM 拦住了上屏，不是我们没发。
                    "fgs" to (n.flags and Notification.FLAG_FOREGROUND_SERVICE != 0),
                )
            }
            out["notes"] = notes
            out["posted"] = notes.any { it["ch"] == PLAYBACK_CHANNEL }
        }
        val svc = audioServiceState()
        out["service"] = svc["fg"]
        // 「被绑住」和「起过服务」是两回事：进入播放态那一趟第一步就是 startForegroundService，
        // 没起过 = 那一趟连第一步都没走到；起过却不在前台 = 走到了、后半段出的事。
        out["serviceStarted"] = svc["started"]
        out["music"] = getSystemService(AudioManager::class.java).isMusicActive
        // 卡上的按钮走的是另一条路（listener），它死了的时候卡照样能显示、歌照样在放，
        // 除了按了没反应之外一点征兆都没有 —— 所以这一项必须自己报出来。
        out["listener"] = listenerAlive()
        return out
    }

    /**
     * 播放服务此刻的两种活法。国产 ROM 会为了省电把这类查询返回空表，
     * 那时候只能报未知，不许当成「没活着」。
     */
    @Suppress("DEPRECATION")
    private fun audioServiceState(): Map<String, Any?> {
        val services = try {
            (getSystemService(ActivityManager::class.java) ?: return emptyMap()).getRunningServices(80)
        } catch (e: Exception) {
            return emptyMap()
        }
        var seen = false
        var fg = false
        var started = false
        for (info in services) {
            val cls = info?.service?.className ?: continue
            if (!cls.endsWith(".AudioService")) continue
            seen = true
            if (info.foreground) fg = true
            if (info.started) started = true
        }
        if (!seen) return emptyMap()
        return mapOf("fg" to fg, "started" to started)
    }

    /**
     * 原生那半截桥还在不在：audio_service 里那个 listener 有没有被清空。
     *
     * 播放器一旦报出 idle，AudioService 收到状态就自己 stopSelf()，onDestroy 里顺手把
     * 静态 listener 置空（AudioService.java:565、:363）。之后卡上的每一个键都落在这个
     * null 上（同文件 :921 往后那一串 `if (listener == null) return`），而卡片照旧能贴出来
     * ——通知是 setState 经静态 instance 发的，用不着 listener。所以她看到的是
     * 「卡有了、歌在放、按钮全都不理人」，而 Dart 侧连一点异常都收不到。
     *
     * 这个字段是私有的，只能反射读。这里连 AudioService 的类型都不写：它是
     * MediaBrowserServiceCompat 的子类，而 androidx.media 只在那个 aar 的传递依赖里，
     * 我们应用模块的编译类路径上没有 —— Kotlin 只要碰这个类型就报
     * 「Cannot access 'androidx.media.MediaBrowserServiceCompat' which is a supertype of
     * 'AudioService'」（:app:compileReleaseKotlin 实测撞过）。类和接口都按名字找，
     * 字段按形状挑，插件哪天改名也不影响。
     */
    private fun listenerAlive(): Boolean? {
        val svc = audioServiceClass() ?: return null
        val iface = serviceListener(svc) ?: return null
        return try {
            staticListener(svc, iface) != null
        } catch (e: Exception) {
            null
        }
    }

    /**
     * 把桥接回去。返回 ok/alive/missing/error 四种结果之一，让 Dart 那边能把话说准。
     *
     * 唯一装这个 listener 的地方是插件 configure 里那句「audioHandlerInterface == null 才
     * AudioService.init(...)」（AudioServicePlugin.java:492），而那个静态对象进程活着就
     * 一直不为 null —— 也就是说服务被 idle 拆掉之后，Dart 侧没有任何公开接口能重装它，
     * 重启应用除外。这里把插件自己那个 ServiceListener 找回来交还给 AudioService.init：
     * 它只是一个静态赋值，下一次进入播放态时 mediaSession 会重新 setActive，
     * 按键立刻又能落到应用里。
     */
    private fun reattachMediaListener(): String {
        val svc = audioServiceClass() ?: return "missing"
        val iface = serviceListener(svc) ?: return "missing"
        if (staticListener(svc, iface) != null) return "alive"
        val plugin = try {
            Class.forName("com.ryanheise.audioservice.AudioServicePlugin")
        } catch (e: Exception) {
            return "missing"
        }
        // 插件那半截是私有嵌套类的静态字段（AudioServicePlugin.java:137），
        // 嵌套类 implements ServiceListener，所以按接口挑得到；取不出来就是改名了。
        val listener = staticListener(plugin, iface) ?: return "missing"
        val init = svc.methods.firstOrNull {
            it.name == "init" && it.parameterTypes.size == 1 && it.parameterTypes[0] == iface
        } ?: return "missing"
        return try {
            init.invoke(null, listener)
            "ok"
        } catch (e: Exception) {
            "error"
        }
    }

    private fun audioServiceClass(): Class<*>? = try {
        Class.forName("com.ryanheise.audioservice.AudioService")
    } catch (e: Exception) {
        null
    }

    /** AudioService 里那个 ServiceListener 接口（Java 里是 public 嵌套接口）。 */
    private fun serviceListener(svc: Class<*>): Class<*>? =
        svc.declaredClasses.firstOrNull { it.isInterface && it.simpleName == "ServiceListener" }

    /** 在某个类里找那个静态的 ServiceListener 字段值；取不到值就接着找下一个字段。 */
    private fun staticListener(owner: Class<*>, iface: Class<*>): Any? {
        for (f in owner.declaredFields) {
            if (!Modifier.isStatic(f.modifiers)) continue
            if (!iface.isAssignableFrom(f.type)) continue
            try {
                f.isAccessible = true
                val value = f.get(null) ?: continue
                if (iface.isInstance(value)) return value
            } catch (e: Exception) {
                // 反射在个别 ROM 上会吃 SecurityException，跳过这一个字段就够了。
            }
        }
        return null
    }

    private fun openNotificationSettings(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                )
                return true
            } catch (e: Exception) {
                // 个别 ROM 没这页，退到应用信息页。
            }
        }
        return try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).setData(Uri.parse("package:$packageName"))
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /** 通道被静默时要把她直接带到那一栏，整罐通知设置里自己翻太考人。 */
    private fun openChannelSettings(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                // 这一跳的 extra 名在 SDK 里没有公开常量，只能照系统源码写死。
                // 注意键名是 Settings.EXTRA_CHANNEL_ID 的值「android.provider.extra.CHANNEL_ID」，
                // 不是 APP_CHANNEL_ID —— 写错了页面照样打开，只是落不到那一栏上，没人会发现。
                startActivity(
                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                        .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                        .putExtra("android.provider.extra.CHANNEL_ID", PLAYBACK_CHANNEL)
                )
                return true
            } catch (e: Exception) {
                // 这个 ROM 不认直达通道这一跳，退到应用通知页。
            }
        }
        return openNotificationSettings()
    }

    companion object {
        private const val CHANNEL = "com.wyj.music.lyric_music/power"

        /** 与 lib/main.dart 里 JustAudioBackground.init 的通道 id 是同一个字符串。 */
        private const val PLAYBACK_CHANNEL = "com.wyj.music.lyric_music.playback"
    }
}
