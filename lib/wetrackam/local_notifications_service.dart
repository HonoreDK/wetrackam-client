// lib/wetrackam/local_notifications_service.dart
//
// Remplace intégralement push_service.dart (Firebase Cloud Messaging).
// Toutes les notifications sont locales, déclenchées soit par une
// temporisation locale (fatigue, ralenti), soit par le résultat d'un
// polling REST (score publié, permis, WS driverScoreUpdate). Aucun canal
// push cloud — conforme au contrat §6 et à l'anti-pattern §14.
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'app_logger.dart';

enum WetrackamNotificationKind {
  fatigueWarning, // A14 : pré-alerte T-30
  fatigue,
  idleEngine,
  geofenceUrban,
  licenseExpiry,
  scorePublished,
  maintenanceDue,
  unidentifiedDriver,
  tenantDisabled,
}

class LocalNotificationsService {
  LocalNotificationsService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // Anti-spam : dernière notification affichée par type (§13 checklist QA :
  // pas de re-notif ralenti avant 1h, une seule pré-alerte fatigue, etc.).
  static final Map<WetrackamNotificationKind, DateTime> _lastShown = {};

  static Future<void> init() async {
    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Africa/Douala'));
    } catch (error) {
      // Base tz embarquée incomplète sur cet appareil — repli sur le
      // fuseau système. Les alertes J-30/J-7/J-0 restent correctes tant
      // que le téléphone est configuré sur l'heure locale Cameroun.
      AppLogger.error('timezone_douala_unavailable', error);
    }
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );
    AppLogger.breadcrumb('local_notifications_init');
  }

  static Future<void> requestPermissions() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static bool _shouldSuppress(WetrackamNotificationKind kind, Duration minInterval) {
    final last = _lastShown[kind];
    if (last == null) return false;
    return DateTime.now().difference(last) < minInterval;
  }

  static Future<void> _show({
    required WetrackamNotificationKind kind,
    required String title,
    required String body,
    Duration antiSpam = Duration.zero,
  }) async {
    if (antiSpam > Duration.zero && _shouldSuppress(kind, antiSpam)) {
      return;
    }
    _lastShown[kind] = DateTime.now();
    const androidDetails = AndroidNotificationDetails(
      'wetrackam_channel',
      'WeTrackam',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(kind.index, title, body, details);
    // ⚠️ Ne jamais inclure driverUniqueId, plaque ou coordonnées GPS dans
    // ce breadcrumb — seul le type d'événement est journalisé.
    AppLogger.breadcrumb('notification_shown:${kind.name}');
  }

  /// Lot 4 — notification pilotée par le serveur (FCM), titre/corps déjà
  /// fournis par le payload (`message.notification`), canal réel transmis
  /// via `data.channel` plutôt que le canal générique unique utilisé par
  /// les anciennes méthodes ci-dessous. C'est ce qui permet au chauffeur
  /// de couper le coaching sans perdre les alertes de sécurité (§8.5) —
  /// un mérite perdu si tout passait par un seul canal.
  static Future<void> showGeneric({
    required String title,
    required String body,
    required String channelId,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelId, // le nom du canal a déjà été fixé à sa création (7 canaux, push_notifications_service.dart) — cette valeur n'est utilisée que si Android doit créer le canal à la volée
      importance: Importance.high,
      priority: Priority.high,
    );
    final details = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(),
    );
    // ID unique par notification (pas de kind fixe ici, contrairement à
    // _show()) pour ne pas écraser une notification en attente avec une
    // autre du même canal.
    final id = DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
    await _plugin.show(id, title, body, details);
    AppLogger.breadcrumb('push_notification_shown:$channelId');
  }

  /// Fatigue > 4h (ignition ON continu) — A14 pré-alerte à T-30 puis alarme réelle.
  static Future<void> fatigueWarning() => _show(
        kind: WetrackamNotificationKind.fatigueWarning,
        title: 'Pause conseillée',
        body: 'Pause conseillée dans 30 minutes.',
        antiSpam: const Duration(hours: 4), // une seule pré-alerte par plage
      );

  static Future<void> fatigueAlarm() => _show(
        kind: WetrackamNotificationKind.fatigue,
        title: 'Fatigue au volant',
        body: 'Plus de 4h de conduite continue. Faites une pause.',
        antiSpam: const Duration(hours: 4),
      );

  static Future<void> idleEngine() => _show(
        kind: WetrackamNotificationKind.idleEngine,
        title: 'Ralenti prolongé',
        body: 'Moteur au ralenti depuis plus de 5 minutes.',
        antiSpam: const Duration(hours: 1),
      );

  static Future<void> geofenceUrban(String zoneName) => _show(
        kind: WetrackamNotificationKind.geofenceUrban,
        title: 'Zone urbaine',
        body: 'Entrée dans $zoneName — limite 50 km/h.',
      );

  static Future<void> licenseExpiry(int daysLeft) => _show(
        kind: WetrackamNotificationKind.licenseExpiry,
        title: 'Permis de conduire',
        body: daysLeft <= 0
            ? 'Votre permis a expiré. Contactez votre gestionnaire.'
            : 'Votre permis expire dans $daysLeft jour(s).',
      );

  static Future<void> scorePublished(int score) => _show(
        kind: WetrackamNotificationKind.scorePublished,
        title: 'Score du jour',
        body: 'Votre score du jour est disponible : $score/100.',
        antiSpam: const Duration(minutes: 4), // évite le doublon polling/WS
      );

  static Future<void> maintenanceDue() => _show(
        kind: WetrackamNotificationKind.maintenanceDue,
        title: 'Entretien véhicule',
        body: 'Le véhicule approche de son intervalle d\'entretien.',
        antiSpam: const Duration(hours: 12),
      );

  static Future<void> tenantDisabled() => _show(
        kind: WetrackamNotificationKind.tenantDisabled,
        title: 'Service temporairement indisponible',
        body: 'Contactez votre gestionnaire.',
      );

  /// ⚠️ v4 : plus appelée depuis le retrait de license_service.dart (le
  /// permis est désormais entièrement piloté par le serveur — voir
  /// `/eligibility` `blockReason: licenseExpired` et le champ
  /// `licenseExpiry`, contrat §6.4/§5). Méthode conservée intacte en cas
  /// de besoin futur d'un rappel local, mais actuellement du code mort.
  /// Planifie une alerte à une date/heure future précise (ex. 00:08 heure
  /// locale Cameroun). Si `when` est déjà passé, ne planifie rien (évite
  /// un déclenchement immédiat non désiré si l'app est réinstallée après
  /// coup).
  static Future<void> scheduleLicenseAlert({
    required int id,
    required DateTime when,
    required String label,
    required int daysLeft,
  }) async {
    if (when.isBefore(DateTime.now())) return;
    final scheduled = tz.TZDateTime.from(when, tz.local);
    const androidDetails = AndroidNotificationDetails(
      'wetrackam_channel',
      'WeTrackam',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    final body = daysLeft <= 0
        ? 'Votre permis a expiré. Contactez votre gestionnaire.'
        : 'Votre permis expire dans $daysLeft jour(s).';
    await _plugin.zonedSchedule(
      id,
      'Permis de conduire',
      body,
      scheduled,
      details,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
    AppLogger.breadcrumb('license_alert_scheduled:$label');
  }

  static Future<void> cancel(int id) => _plugin.cancel(id);
}
