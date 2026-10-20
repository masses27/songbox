package com.wyj.music.lyric_music

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                    "notificationsEnabled" -> result.success(notificationsEnabled())
                    "openNotificationSettings" -> result.success(openNotificationSettings())
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

    companion object {
        private const val CHANNEL = "com.wyj.music.lyric_music/power"
    }
}
