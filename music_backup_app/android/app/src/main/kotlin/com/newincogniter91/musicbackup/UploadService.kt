package com.newincogniter91.musicbackup

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service che tiene vivo il processo (con wakelock e wifi lock)
 * mentre il backup carica i file, così l'upload continua anche con l'app
 * in background o lo schermo spento. Il lavoro vero resta in Dart; qui c'è
 * solo la notifica di avanzamento.
 */
class UploadService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            releaseLocks()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        createChannel()
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Backup in corso…"
        val percent = intent?.getIntExtra(EXTRA_PERCENT, -1) ?: -1
        val notification = buildNotification(text, percent)

        if (wakeLock == null) {
            startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            acquireLocks()
        } else {
            getSystemService(NotificationManager::class.java).notify(NOTIF_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }

    private fun acquireLocks() {
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "musicbackup:upload")
            .apply { acquire(6 * 60 * 60 * 1000L) }
        wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
            .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "musicbackup:upload")
            .apply { acquire() }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
    }

    private fun createChannel() {
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Backup", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun buildNotification(text: String, percent: Int): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Music Backup")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, percent.coerceAtLeast(0), percent < 0)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "backup"
        private const val NOTIF_ID = 1
        const val ACTION_STOP = "com.newincogniter91.musicbackup.STOP"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PERCENT = "percent"
    }
}
