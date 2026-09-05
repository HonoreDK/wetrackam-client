package cm.wetrackam.driver

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * v13 — pont minimal entre la machine à états d'appel (Dart, source de
 * vérité unique) et le service de premier plan « microphone » exigé par
 * Android 14+ pendant un appel WebRTC.
 *
 * Deux méthodes seulement, volontairement : `start` et `stop`. Toute logique
 * supplémentaire ici créerait un second état d'appel côté natif, donc des
 * divergences impossibles à déboguer.
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
                    else -> result.notImplemented()
                }
            }
    }
}
