import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wetrackam_client/main.dart';
import 'package:wetrackam_client/password_service.dart';
import 'package:wetrackam_client/preferences.dart';
import 'package:flutter_background_geolocation/flutter_background_geolocation.dart' as bg;

import 'l10n/app_localizations.dart';
import 'status_screen.dart';
import 'settings_screen.dart';
import 'wetrackam/app_logger.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool trackingEnabled = false;
  bool? isMoving;

  @override
  void initState() {
    super.initState();
    _initState();
  }

  void _initState() async {
    final state = await bg.BackgroundGeolocation.state;
    setState(() {
      trackingEnabled = state.enabled;
      isMoving = state.isMoving;
    });
    bg.BackgroundGeolocation.onEnabledChange((bool enabled) {
      setState(() {
        trackingEnabled = enabled;
      });
    });
    bg.BackgroundGeolocation.onMotionChange((bg.Location location) {
      setState(() {
        isMoving = location.isMoving;
      });
    });
  }

  Future<void> _checkBatteryOptimizations(BuildContext context) async {
    try {
      if (!await bg.DeviceSettings.isIgnoringBatteryOptimizations) {
        final request = await bg.DeviceSettings.showIgnoreBatteryOptimizations();
        if (!request.seen && context.mounted) {
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              scrollable: true,
              content: Text(AppLocalizations.of(context)!.optimizationMessage),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    bg.DeviceSettings.show(request);
                  },
                  child: Text(AppLocalizations.of(context)!.okButton),
                ),
              ],
            ),
          );
        }
      }
    } catch (error) {
      debugPrint(error.toString());
    }
  }

  Widget _buildTrackingCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.trackingTitle),
              titleTextStyle: Theme.of(context).textTheme.headlineMedium,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.idLabel),
              subtitle: Text(Preferences.instance.getString(Preferences.id) ?? ''),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.trackingLabel),
              value: trackingEnabled,
              activeTrackColor: isMoving == false ? Theme.of(context).colorScheme.secondary : null,
              onChanged: (bool value) async {
                if (await PasswordService.authenticate(context) && mounted) {
                  if (value) {
                    try {
                      AppLogger.breadcrumb('tracking_toggle_start');
                      await bg.BackgroundGeolocation.start();
                      if (mounted) {
                        _checkBatteryOptimizations(context);
                      }
                    } on PlatformException catch (error) {
                        final providerState = await bg.BackgroundGeolocation.providerState;
                        final isPermissionError = providerState.status == bg.ProviderChangeEvent.AUTHORIZATION_STATUS_DENIED ||
                          providerState.status == bg.ProviderChangeEvent.AUTHORIZATION_STATUS_RESTRICTED;
                        if (!mounted) return;
                        messengerKey.currentState?.showSnackBar(
                          SnackBar(
                            content: Text(error.message ?? error.code),
                            duration: const Duration(seconds: 4),
                            action: isPermissionError
                                ? SnackBarAction(
                                    label: AppLocalizations.of(context)!.settingsTitle,
                                    onPressed: () => AppSettings.openAppSettings(
                                      type: AppSettingsType.settings,
                                    ),
                                  )
                                : null,
                          ),
                        );
                    }
                  } else {
                    AppLogger.breadcrumb('tracking_toggle_stop');
                    bg.BackgroundGeolocation.stop();
                  }
                }
              },
            ),
            const SizedBox(height: 8),
            OverflowBar(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    try {
                      await bg.BackgroundGeolocation.getCurrentPosition(samples: 1, persist: true, extras: {'manual': true});
                    } on PlatformException catch (error) {
                      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(error.message ?? error.code)));
                    }
                  },
                  child: Text(AppLocalizations.of(context)!.locationButton),
                ),
                FilledButton.tonal(
                  onPressed: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const StatusScreen()));
                  },
                  child: Text(AppLocalizations.of(context)!.statusButton),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ⚠️ v4 : cet écran (MainScreen) n'est plus atteint par le flux normal
  // de l'app — voir main_navigation_gate.dart. Le contrat v4 §3.1 exige
  // que l'URL serveur provienne EXCLUSIVEMENT du provisionnement (QR/lien),
  // jamais d'un réglage libre modifiable par le chauffeur ; la carte
  // "Mon espace chauffeur" (Ma journée/Mon score/Permis/Changer de
  // chauffeur) de la v1 a été retirée car ces écrans n'existent plus dans
  // le modèle v4 (score/historique hors périmètre mobile, §19 ; permis et
  // changement de véhicule entièrement pilotés par /eligibility).
  //
  // Ce fichier est conservé tel quel (non supprimé) pour limiter le risque
  // de casser des références internes non tracées, mais reste du code mort
  // dans le flux v4. Décision produit à prendre : le supprimer purement,
  // ou le repurposer en écran de diagnostic support (accès cachés).

  Widget _buildSettingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.settingsTitle),
              titleTextStyle: Theme.of(context).textTheme.headlineMedium,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(AppLocalizations.of(context)!.urlLabel),
              subtitle: Text(Preferences.instance.getString(Preferences.url) ?? ''),
            ),
            const SizedBox(height: 8),
            OverflowBar(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () async {
                    if (await PasswordService.authenticate(context) && mounted) {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                      setState(() {});
                    }
                  },
                  child: Text(AppLocalizations.of(context)!.settingsButton),
                ),
              ],
            ),
          ]
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WeTrackam'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildTrackingCard(),
            const SizedBox(height: 16),
            _buildSettingsCard(),
          ],
        ),
      ),
    );
  }
}
