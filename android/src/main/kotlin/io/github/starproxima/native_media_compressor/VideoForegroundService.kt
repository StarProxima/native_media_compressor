package io.github.starproxima.native_media_compressor

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import kotlin.math.roundToInt

/**
 * Holds the process in the foreground while videos are compressed, so the system
 * does not stop the work when the app goes to the background. The compression
 * runs in the plugin's worker either way; the service only shows the notification.
 *
 * The companion is driven from the main thread only.
 */
internal class VideoForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        starting = false
        // A service started with startForegroundService must call startForeground even
        // when the videos are already done, or the system crashes the app.
        val content = settings ?: lastSettings
        val started = content != null && runCatching {
            val notification = build(this, content)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }.isSuccess
        if (!started) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = this
        if (!isWanted()) stop()
        return START_NOT_STICKY
    }

    // Android 15 limits dataSync services to six hours a day and crashes the app
    // if the service outlives the limit; the compression goes on without it.
    override fun onTimeout(startId: Int, fgsType: Int) {
        stop()
    }

    override fun onDestroy() {
        if (running === this) running = null
        super.onDestroy()
    }

    private fun refresh() {
        val content = settings ?: return
        runCatching { notificationManager(this).notify(NOTIFICATION_ID, build(this, content)) }
    }

    private fun stop() {
        if (running === this) running = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    companion object {
        private const val NOTIFICATION_ID = 0x4e4d43
        private const val CHANNEL_ID = "native_media_compressor_video"

        private var settings: ForegroundNotification? = null

        // What a service that comes up after the settings were cleared still shows
        // for the moment it must be in the foreground.
        private var lastSettings: ForegroundNotification? = null
        private var activeVideos = 0
        private var percent: Int? = null
        private var running: VideoForegroundService? = null
        private var starting = false
        private var channelName: String? = null

        fun configure(context: Context, notification: ForegroundNotification?) {
            settings = notification
            if (notification != null) lastSettings = notification
            update(context)
        }

        /** A video was queued; queued ones count too, as they need the process alive to run. */
        fun videoStarted(context: Context) {
            activeVideos++
            update(context)
        }

        fun videoProgress(progress: Double) {
            val next = (progress * 100).roundToInt().coerceIn(0, 100)
            if (next == percent) return
            percent = next
            running?.refresh()
        }

        fun videoFinished(context: Context) {
            activeVideos = (activeVideos - 1).coerceAtLeast(0)
            percent = null
            update(context)
        }

        private fun isWanted() = settings != null && activeVideos > 0

        private fun update(context: Context) {
            val service = running
            when {
                isWanted() && service != null -> service.refresh()
                isWanted() && !starting -> start(context.applicationContext)
                !isWanted() && service != null -> service.stop()
            }
        }

        private fun start(context: Context) {
            if (!declaresPermissions(context)) return
            val intent = Intent(context, VideoForegroundService::class.java)
            // Throws when the app is in the background on Android 8+ (12+ for a
            // foreground service); videos then run without the service.
            val component = runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            }.getOrNull()
            starting = component != null
        }

        // Without these the system throws from startForeground; it is the app's
        // choice to declare them, so their absence means no service.
        @Suppress("DEPRECATION")
        private fun declaresPermissions(context: Context): Boolean {
            val required = mutableListOf(Manifest.permission.FOREGROUND_SERVICE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                required += Manifest.permission.FOREGROUND_SERVICE_DATA_SYNC
            }
            val declared = runCatching {
                context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS).requestedPermissions
            }.getOrNull() ?: return false
            return declared.toSet().containsAll(required)
        }

        private fun notificationManager(context: Context) =
            context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        private fun build(context: Context, content: ForegroundNotification): Notification {
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (channelName != content.channelName) {
                    val channel = NotificationChannel(CHANNEL_ID, content.channelName, NotificationManager.IMPORTANCE_LOW)
                    notificationManager(context).createNotificationChannel(channel)
                    channelName = content.channelName
                }
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context).setPriority(Notification.PRIORITY_LOW)
            }
            val progress = percent
            builder
                .setSmallIcon(icon(context, content.iconResource))
                .setContentTitle(content.title)
                .setContentText(content.text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_PROGRESS)
                .setProgress(100, progress ?: 0, progress == null)
            launchIntent(context)?.let(builder::setContentIntent)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            return builder.build()
        }

        private fun icon(context: Context, name: String?): Int {
            val named = name?.let { context.resources.getIdentifier(it, "drawable", context.packageName) } ?: 0
            if (named != 0) return named
            val appIcon = context.applicationInfo.icon
            return if (appIcon != 0) appIcon else android.R.drawable.stat_sys_upload
        }

        private fun launchIntent(context: Context): PendingIntent? {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
            return PendingIntent.getActivity(context, 0, intent, flags)
        }
    }
}
