package cm.wetrackam.driver

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * v17 — sonnerie d'appel entrant quand l'application est AU PREMIER PLAN.
 *
 * POURQUOI. L'écran d'appel entrant Flutter (incoming_call_screen.dart) ne sait
 * pas sonner. Avant, on affichait EN PLUS la notification d'appel native pour
 * qu'elle sonne : deux surfaces (la page et la notification), et une
 * notification qui survivait au décrochage avec son minuteur d'expiration —
 * qui raccrochait l'appel au bout de 20 s. Cette classe sonne, et rien
 * d'autre : pas de notification, pas d'état d'appel.
 *
 * RÈGLES.
 *  - Respecte le mode sonnerie du téléphone : silencieux = rien, vibreur =
 *    vibration seule, normal = sonnerie par défaut + vibration.
 *  - `stop()` est idempotent et TOUJOURS sûr : appelé à chaque transition
 *    (décrochage, refus, raccrochage du pair, délai) par la machine à états
 *    Dart, jamais oublié parce qu'unique.
 *  - Aucune boucle qui survit au processus : un seul objet, une seule
 *    sonnerie, remplacée si `start()` est rappelé.
 */
object CallRinger {

    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null

    @Synchronized
    fun start(context: Context) {
        stop()
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        when (audio.ringerMode) {
            AudioManager.RINGER_MODE_SILENT -> return
            AudioManager.RINGER_MODE_VIBRATE -> {
                vibrate(context)
                return
            }
        }
        vibrate(context)
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                ?: return
            val tone = RingtoneManager.getRingtone(context, uri) ?: return
            tone.audioAttributes = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                tone.isLooping = true
            }
            tone.play()
            ringtone = tone
        } catch (e: Exception) {
            // Une sonnerie indisponible ne doit jamais empêcher l'appel :
            // la vibration et l'écran suffisent à prévenir.
        }
    }

    @Synchronized
    fun stop() {
        try {
            ringtone?.stop()
        } catch (e: Exception) {
        }
        ringtone = null
        try {
            vibrator?.cancel()
        } catch (e: Exception) {
        }
        vibrator = null
    }

    private fun vibrate(context: Context) {
        val v: Vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        }
        if (!v.hasVibrator()) return
        val pattern = longArrayOf(0L, 900L, 700L)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(pattern, 0)
            }
            vibrator = v
        } catch (e: Exception) {
        }
    }
}
