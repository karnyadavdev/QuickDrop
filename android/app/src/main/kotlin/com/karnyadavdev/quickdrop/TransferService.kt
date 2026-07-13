package com.karnyadavdev.quickdrop

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.IBinder
import android.os.PowerManager

class TransferService : Service() {
    companion object {
        const val START = "quickdrop.startTransfer"
        const val UPDATE = "quickdrop.updateTransfer"
        const val CANCEL = "quickdrop.cancelTransfer"
        const val TITLE = "title"
        const val FILE_NAME = "fileName"
        const val PROGRESS = "progress"

        var cancelTransfer: (() -> Unit)? = null

        private const val channelId = "quickdrop_transfers"
        private const val notificationId = 50005
        private const val sixHours = 6L * 60L * 60L * 1000L
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var title = "QuickDrop transfer"
    private var fileName = "File"
    private var progress = -1
    private var started = false

    override fun onCreate() {
        super.onCreate()
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(
            NotificationChannel(
                channelId,
                "File transfers",
                NotificationManager.IMPORTANCE_LOW
            )
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY
        when (intent.action) {
            CANCEL -> cancelFromNotification()
            UPDATE -> {
                readStatus(intent)
                if (started) showNotification() else startTransfer()
            }
            START -> {
                readStatus(intent)
                startTransfer()
            }
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        started = false
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        cancelTransfer?.invoke()
        stopSelf()
    }

    private fun readStatus(intent: Intent) {
        val nextTitle = intent.getStringExtra(TITLE)
        if (!nextTitle.isNullOrBlank()) title = nextTitle

        val nextFileName = intent.getStringExtra(FILE_NAME)
        if (!nextFileName.isNullOrBlank()) fileName = nextFileName

        progress = intent.getIntExtra(PROGRESS, progress).coerceIn(-1, 100)
    }

    private fun keepCpuAwake() {
        if (wakeLock?.isHeld == true) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "QuickDrop:FileTransfer"
        ).apply {
            acquire(sixHours)
        }
    }

    private fun startTransfer() {
        keepCpuAwake()
        startForeground(
            notificationId,
            buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )
        started = true
    }

    private fun releaseWakeLock() {
        val lock = wakeLock
        wakeLock = null
        if (lock?.isHeld == true) lock.release()
    }

    private fun showNotification() {
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.notify(notificationId, buildNotification())
    }

    private fun buildNotification(canCancel: Boolean = true): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = Notification.Builder(this, channelId)
            .setSmallIcon(R.drawable.ic_transfer_notification)
            .setContentTitle(title)
            .setContentText(fileName)
            .setContentIntent(openApp)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)
            .setOngoing(true)

        if (progress >= 0) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(100, 0, true)
        }

        if (canCancel) {
            val cancel = PendingIntent.getService(
                this,
                1,
                Intent(this, TransferService::class.java).setAction(CANCEL),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val icon = Icon.createWithResource(
                this,
                android.R.drawable.ic_menu_close_clear_cancel
            )
            val action = Notification.Action.Builder(icon, "Cancel", cancel).build()
            builder.addAction(action)
        }
        return builder.build()
    }

    private fun cancelFromNotification() {
        title = "Cancelling transfer"
        progress = -1
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.notify(
            notificationId,
            buildNotification(canCancel = false)
        )
        cancelTransfer?.invoke()
        stopSelf()
    }
}
