import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../location_cache.dart';
import 'api_client.dart';
import 'app_logger.dart';

/// Envoi SOS durable et idempotent. L'identifiant reste en local tant que le
/// serveur n'a pas confirmé : un second appui ou un retour réseau rejoue la
/// même alerte, que `/api/distress` déduplique sans réarmer l'escalade.
class DistressService {
  DistressService._();

  static const _pendingAlertKey = 'wetrackam_pending_distress_alert_id';

  static Future<Map<String, dynamic>> raiseSos({String? note}) async {
    final prefs = await SharedPreferences.getInstance();
    var alertId = prefs.getString(_pendingAlertKey);
    if (alertId == null || alertId.isEmpty) {
      alertId = const Uuid().v4();
      await prefs.setString(_pendingAlertKey, alertId);
    }
    final location = LocationCache.get();
    try {
      final result = await WetrackamApiClient.raiseDistress(
        alertId: alertId,
        latitude: location?.latitude,
        longitude: location?.longitude,
        note: note,
      );
      await prefs.remove(_pendingAlertKey);
      AppLogger.breadcrumb('distress_confirmed:$alertId');
      return result;
    } catch (error) {
      AppLogger.error('distress_pending:$alertId', error);
      rethrow;
    }
  }

  static Future<void> retryPending() async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getString(_pendingAlertKey) ?? '').isEmpty) return;
    try {
      await raiseSos();
    } catch (_) {
      // Best-effort : le même identifiant reste prêt pour le prochain retour.
    }
  }
}
