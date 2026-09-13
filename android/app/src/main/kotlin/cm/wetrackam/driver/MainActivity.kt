package cm.wetrackam.driver

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * v13 — pont minimal entre la machine à états d'appel (Dart, source de
 * vérité unique) et le natif Android exigé par un appel WebRTC :
 *   - `start` / `stop`     : service de premier plan « microphone »
 *                            (obligatoire depuis Android 14 pour capturer
 *                            hors premier plan) ;
 *   - `ringStart`/`ringStop` (v17) : sonnerie + vibration de l'appel entrant
 *                            quand l'application est AU PREMIER PLAN — la
 *                            page Flutter d'appel entrant est alors la seule
 *                            surface, elle ne sait pas sonner toute seule.
 *
 * Aucune logique d'appel ici : le natif exécute, Dart décide. Toute logique
 * supplémentaire créerait un second état d'appel côté natif, donc des
 * divergences impossibles à déboguer (c'est exactement ce qui se produisait
 * avec la notification native affichée « en plus » de la page Flutter).
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "wetrackam/call_fgs"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val peer = call.argument<String>("peer") ?: "Appel en cours"
                        val intent = Intent(this, CallForegroundService::class.java).apply {
                            action = CallForegroundService.ACTION_START
                            putExtra(CallForegroundService.EXTRA_PEER, peer)
                        }
                        // startForegroundService est requis dès Android O ; le
                        // service DOIT ensuite appeler startForeground() sous 5 s,
                        // ce que fait CallForegroundService.onStartCommand.
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        val intent = Intent(this, CallForegroundService::class.java).apply {
                            action = CallForegroundService.ACTION_STOP
                        }
                        // On passe par le service plutôt que stopService() afin
                        // qu'il retire lui-même sa notification : un stopService
                        // brutal laisse parfois la notification d'appel affichée.
                        startService(intent)
                        result.success(null)
                    }
                    "ringStart" -> {
                        CallRinger.start(applicationContext)
                        result.success(null)
                    }
                    "ringStop" -> {
                        CallRinger.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        // L'activité disparaît (processus tué, changement de configuration
        // extrême) : aucune sonnerie ne doit lui survivre.
        CallRinger.stop()
        super.onDestroy()
    }
}
