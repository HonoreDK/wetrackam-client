// lib/wetrackam/call_navigator.dart
//
// Lot 8 — un appel entrant peut survenir depuis n'importe quel écran de
// l'app (ou juste après un réveil par push, avant même que l'app soit au
// premier plan). CallService n'a pas de BuildContext ; ce fichier fait le
// pont via une clé de navigation globale (main.dart, MaterialApp.navigatorKey).
import 'package:flutter/material.dart';

import 'app_logger.dart';
import 'call_service.dart';
import 'incoming_call_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class CallNavigator {
  CallNavigator._();

  static bool _listening = false;

  static void start() {
    if (_listening) return;
    _listening = true;
    CallService.incomingCalls.listen((_) {
      final nav = navigatorKey.currentState;
      if (nav == null) {
        AppLogger.error('call_navigator_no_navigator', 'incoming call could not be displayed');
        return;
      }
      nav.push(MaterialPageRoute(builder: (_) => const IncomingCallScreen()));
    });
  }
}
