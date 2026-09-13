package cm.wetrackam.driver

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * v13 — service de premier plan tenu pendant toute la durée d'un appel WebRTC.
 *
 * POURQUOI. Depuis Android 14 (API 34), la capture micro hors premier plan
 * exige un service de premier plan déclaré `foregroundServiceType="microphone"`.
 * Sans lui, le système coupe silencieusement le flux audio dès que le
 * chauffeur verrouille son écran ou bascule vers Waze : l'appel « passe »
 * mais l'interlocuteur n'entend plus rien. C'est un des symptômes rapportés.
 *
 * Le service ne fait AUCUNE logique d'appel : il ne fait que maintenir le
 * processus éligible à la capture micro et afficher la notification
 * obligatoire. Toute la machine à états reste dans CallService (Dart), source
 * de vérité unique — c'est ce qui évite les états divergents natif/Dart.
 */
class CallForegroundService : Service() {

    companion object {
        const val ACTION_START = "cm.wetrackam.driver.CALL_FGS_START"
        const val ACTION_STOP = "cm.wetrackam.driver.CALL_FGS_STOP"
        const val EXTRA_PEER = "peer"
        private const val CHANNEL_ID = "wetrackam_call_ongoing"
        private const val NOTIFICATION_ID = 4711
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val peer = intent?.getStringExtra(EXTRA_PEER) ?: "Appel en cours"
        startForegroundCompat(peer)
        // START_NOT_STICKY : si le système tue le processus, l'appel est de
        // toute façon terminé côté serveur (la socket est tombée). Redémarrer
        // le service ressusciterait une notification d'appel fantôme.
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(peer: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Appel en cours",
                NotificationManager.IMPORTANCE_LOW // silencieux : l'appel sonne déjà
            ).apply {
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            (getSystemService(NotificationManager::class.java)).createNotificationChannel(channel)
        }

        val tapIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        val pending = tapIntent?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("WeTrackam — appel en cours")
            .setContentText(peer)
            .setSmallIcon(android.R.drawable.stat_sys_phone_call)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .build()

        // FOREGROUND_SERVICE_TYPE_MICROPHONE existe depuis l'API 30 (R), pas Q.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
