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
  // La NATURE et la PRÉCISION sont persistées avec l'identifiant : sans elles,
  // une alerte déclenchée hors réseau repartait au retour du signal en simple
  // « sos », perdant le « accident » ou le « agression » choisi par le
  // chauffeur — c'est-à-dire exactement l'information qui oriente les secours.
  static const _pendingKindKey = 'wetrackam_pending_distress_kind';
  static const _pendingNoteKey = 'wetrackam_pending_distress_note';

  static Future<Map<String, dynamic>> raiseSos({String kind = 'sos', String? note}) async {
    final prefs = await SharedPreferences.getInstance();
    var alertId = prefs.getString(_pendingAlertKey);
    if (alertId == null || alertId.isEmpty) {
      alertId = const Uuid().v4();
      await prefs.setString(_pendingAlertKey, alertId);
      await prefs.setString(_pendingKindKey, kind);
      if (note != null && note.trim().isNotEmpty) {
        await prefs.setString(_pendingNoteKey, note.trim());
      } else {
        await prefs.remove(_pendingNoteKey);
      }
    }
    final location = LocationCache.get();
    try {
      final result = await WetrackamApiClient.raiseDistress(
        alertId: alertId,
        kind: kind,
        latitude: location?.latitude,
        longitude: location?.longitude,
        note: note,
      );
      await _clearPending(prefs);
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
      await raiseSos(
        // Alerte antérieure à cette version, ou nature jamais enregistrée :
        // « sos » est le repli du serveur lui-même, donc le bon défaut.
        kind: prefs.getString(_pendingKindKey) ?? 'sos',
        note: prefs.getString(_pendingNoteKey),
      );
    } catch (_) {
      // Best-effort : le même identifiant reste prêt pour le prochain retour.
    }
  }

  /// Y a-t-il une alerte déclenchée mais pas encore confirmée par le serveur ?
  /// Sert à le SIGNALER au chauffeur : une alerte silencieusement en attente
  /// lui ferait croire que les secours sont prévenus alors qu'ils ne le sont
  /// pas encore.
  static Future<bool> hasPending() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_pendingAlertKey) ?? '').isNotEmpty;
  }

  static Future<void> _clearPending(SharedPreferences prefs) async {
    await prefs.remove(_pendingAlertKey);
    await prefs.remove(_pendingKindKey);
    await prefs.remove(_pendingNoteKey);
  }
}
