import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;

import 'l10n/app_localizations.dart';
import 'password_service.dart';
import 'wetrackam/app_logger.dart';
import 'wetrackam/driver_identity_service.dart';
import 'wetrackam/shift_service.dart';

class QuickActionsInitializer extends StatefulWidget {
  const QuickActionsInitializer({super.key});

  @override
  State<QuickActionsInitializer> createState() => _QuickActionsInitializerState();
}

class _QuickActionsInitializerState extends State<QuickActionsInitializer> {
  final QuickActions quickActions = QuickActions();

  @override
  void initState() {
    super.initState();
    quickActions.initialize((shortcutType) async {
      AppLogger.breadcrumb('quick_action: $shortcutType');
      // Anomalies corrigées (audit sécurité) :
      //  1. Ces raccourcis appelaient directement le plugin de
      //     géolocalisation, sans authentification — n'importe qui avec le
      //     téléphone en main pouvait démarrer/arrêter le suivi ou déclencher
      //     une alerte SOS depuis l'écran verrouillé, sans mot de passe.
      //  2. `start`/`stop` contournaient ShiftService, la seule source de
      //     vérité pour "aucun envoi hors service" (§8.1 règle 1,
      //     geolocation_service.dart::onLocation) : le raccourci "Start"
      //     activait bien le plugin, mais aucune position n'était jamais
      //     réellement transmise au serveur (ShiftService.isActive restait
      //     false) — le chauffeur croyait être suivi sans l'être. Le
      //     raccourci "SOS" avait le même défaut : une position capturée
      //     hors service n'était jamais envoyée, échec silencieux d'une
      //     fonction de sécurité.
      // Correction : authentification obligatoire, puis passage par le même
      // chemin authentifié que l'écran d'éligibilité (ShiftService), qui
      // seul sait mettre à jour `deviceUniqueId`/`isActive` correctement.
      if (!mounted) return;
      final authenticated = await PasswordService.authenticate(context);
      if (!authenticated) {
        AppLogger.breadcrumb('quick_action_denied_bad_password:$shortcutType');
        if (mounted) SystemNavigator.pop();
        return;
      }
      switch (shortcutType) {
        case 'start':
          if (!DriverIdentityService.isAuthenticated) {
            AppLogger.breadcrumb('quick_action_start_denied_no_session');
          } else if (!ShiftService.isActive) {
            try {
              await ShiftService.start();
            } catch (error) {
              AppLogger.error('quick_action_start_failed', error);
            }
          }
        case 'stop':
          if (ShiftService.isActive) {
            try {
              await ShiftService.end();
            } catch (error) {
              AppLogger.error('quick_action_stop_failed', error);
            }
          }
        case 'sos':
          // §8.1 règle 1 : une position capturée hors service ne serait de
          // toute façon jamais envoyée — mieux vaut le signaler clairement
          // que de laisser croire au chauffeur qu'une alerte est partie.
          if (!ShiftService.isActive) {
            AppLogger.breadcrumb('quick_action_sos_skipped_no_active_shift');
          } else {
            try {
              await bg.BackgroundGeolocation.getCurrentPosition(samples: 1, persist: true, extras: {'alarm': 'sos'});
            } catch (error) {
              developer.log('Failed to send alert', error: error);
            }
          }
      }
      if (mounted) {
        AppLogger.breadcrumb('quick_action_exit');
        SystemNavigator.pop();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final localizations = AppLocalizations.of(context)!;
    quickActions.setShortcutItems(<ShortcutItem>[
      ShortcutItem(type: 'start', localizedTitle: localizations.startAction, icon: 'play'),
      ShortcutItem(type: 'stop', localizedTitle: localizations.stopAction, icon: 'stop'),
      ShortcutItem(type: 'sos', localizedTitle: localizations.sosAction, icon: 'exclamation'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
