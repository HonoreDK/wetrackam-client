import 'package:flutter_test/flutter_test.dart';
import 'package:wetrackam_client/wetrackam/call_policy.dart';

void main() {
  group('decideNativeEvent — délai de la notification (bug « coupe après 20 s »)', () {
    test('délai pendant la sonnerie du même appel : appel manqué, rien d’envoyé', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.timeout,
          eventCallId: 'c1',
          phase: CallPhase.incomingRinging,
          currentCallId: 'c1',
          pendingAcceptId: null,
        ),
        NativeCallAction.missed,
      );
    });
    test('délai de la notification alors que l’appel est DÉCROCHÉ : ignoré', () {
      // C'était LE défaut : la notification d'appel entrant survivait au
      // décrochage fait sur la page Flutter, expirait 30 s après son
      // affichage, et son délai raccrochait la communication.
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.timeout,
          eventCallId: 'c1',
          phase: CallPhase.connected,
          currentCallId: 'c1',
          pendingAcceptId: null,
        ),
        NativeCallAction.ignore,
      );
    });
    test('délai d’un AUTRE appel : ignoré', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.timeout,
          eventCallId: 'ancien',
          phase: CallPhase.incomingRinging,
          currentCallId: 'c2',
          pendingAcceptId: null,
        ),
        NativeCallAction.ignore,
      );
    });
    test('délai sur une acceptation mémorisée : l’acceptation est oubliée', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.timeout,
          eventCallId: 'c1',
          phase: CallPhase.idle,
          currentCallId: null,
          pendingAcceptId: 'c1',
        ),
        NativeCallAction.forgetPending,
      );
    });
  });

  group('decideNativeEvent — accepter', () {
    test('accepter pendant la sonnerie du même appel', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.accept,
          eventCallId: 'c1',
          phase: CallPhase.incomingRinging,
          currentCallId: 'c1',
          pendingAcceptId: null,
        ),
        NativeCallAction.accept,
      );
    });
    test('accepter avant la signalisation (push avant socket) : mémorisé', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.accept,
          eventCallId: 'c1',
          phase: CallPhase.idle,
          currentCallId: null,
          pendingAcceptId: null,
        ),
        NativeCallAction.rememberAccept,
      );
    });
    test('accepter pendant une communication : ignoré (jamais un second appel)', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.accept,
          eventCallId: 'c2',
          phase: CallPhase.connected,
          currentCallId: 'c1',
          pendingAcceptId: null,
        ),
        NativeCallAction.ignore,
      );
    });
  });

  group('decideNativeEvent — refuser et raccrocher', () {
    test('refus natif pendant la sonnerie du même appel', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.decline,
          eventCallId: 'c1',
          phase: CallPhase.incomingRinging,
          currentCallId: 'c1',
          pendingAcceptId: null,
        ),
        NativeCallAction.decline,
      );
    });
    test('refus natif tardif pendant la communication : ignoré', () {
      // La notification d'appel entrant, fermée par le nettoyage, renvoie un
      // « decline » natif : il ne doit jamais raccrocher l'appel en cours.
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.decline,
          eventCallId: 'c1',
          phase: CallPhase.connected,
          currentCallId: 'c1',
          pendingAcceptId: null,
        ),
        NativeCallAction.ignore,
      );
    });
    test('refus natif sans appel : on ferme seulement l’écran orphelin', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.decline,
          eventCallId: 'c9',
          phase: CallPhase.idle,
          currentCallId: null,
          pendingAcceptId: null,
        ),
        NativeCallAction.dismissOnly,
      );
    });
    test('raccrochage natif pendant la communication du même appel', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.ended,
          eventCallId: 'c1',
          phase: CallPhase.connected,
          currentCallId: 'c1',
          pendingAcceptId: null,
        ),
        NativeCallAction.hangUp,
      );
    });
    test('raccrochage natif d’un autre appel : ignoré', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.ended,
          eventCallId: 'ancien',
          phase: CallPhase.connected,
          currentCallId: 'c1',
          pendingAcceptId: null,
        ),
        NativeCallAction.ignore,
      );
    });
    test('« ended » natif après un nettoyage (écho du endCall) : fermeture seule', () {
      expect(
        decideNativeEvent(
          kind: NativeCallEventKind.ended,
          eventCallId: 'c1',
          phase: CallPhase.idle,
          currentCallId: null,
          pendingAcceptId: null,
        ),
        NativeCallAction.dismissOnly,
      );
    });
  });

  group('nextRouteAction — une seule route d’appel, pilotée par la phase', () {
    test('sonnerie entrante au premier plan : page d’appel entrant', () {
      expect(
        nextRouteAction(phase: CallPhase.incomingRinging, current: null, inAppIncomingUi: true),
        CallRouteAction.pushIncoming,
      );
    });
    test('sonnerie entrante gérée par le natif : aucune page', () {
      expect(
        nextRouteAction(phase: CallPhase.incomingRinging, current: null, inAppIncomingUi: false),
        CallRouteAction.none,
      );
    });
    test('décrochage natif : la page d’appel entrant est REMPLACÉE par l’appel en cours', () {
      // Avant : la page « Appel entrant » restait affichée avec ses boutons
      // Accepter/Refuser alors que la communication était établie.
      expect(
        nextRouteAction(phase: CallPhase.connected, current: CallRouteKind.incoming, inAppIncomingUi: true),
        CallRouteAction.replaceWithInCall,
      );
    });
    test('connexion sans aucune page (appel accepté application tuée) : page poussée', () {
      expect(
        nextRouteAction(phase: CallPhase.connected, current: null, inAppIncomingUi: false),
        CallRouteAction.pushInCall,
      );
    });
    test('déjà sur l’appel en cours : rien', () {
      expect(
        nextRouteAction(phase: CallPhase.connected, current: CallRouteKind.inCall, inAppIncomingUi: true),
        CallRouteAction.none,
      );
    });
    test('appel sortant : page d’appel poussée une seule fois', () {
      expect(
        nextRouteAction(phase: CallPhase.outgoingRinging, current: null, inAppIncomingUi: true),
        CallRouteAction.pushInCall,
      );
      expect(
        nextRouteAction(phase: CallPhase.outgoingRinging, current: CallRouteKind.inCall, inAppIncomingUi: true),
        CallRouteAction.none,
      );
    });
    test('retour au repos : la route d’appel est retirée, et seulement elle', () {
      expect(
        nextRouteAction(phase: CallPhase.idle, current: CallRouteKind.inCall, inAppIncomingUi: true),
        CallRouteAction.remove,
      );
      expect(
        nextRouteAction(phase: CallPhase.idle, current: null, inAppIncomingUi: true),
        CallRouteAction.none,
      );
    });
  });

  group('shouldRingInApp', () {
    test('Android au premier plan : dans l’application', () {
      expect(shouldRingInApp(android: true, foreground: true), isTrue);
    });
    test('Android en arrière-plan : écran natif', () {
      expect(shouldRingInApp(android: true, foreground: false), isFalse);
    });
    test('iOS : CallKit, toujours', () {
      expect(shouldRingInApp(android: false, foreground: true), isFalse);
    });
  });

  group('CallSignalQueue — un raccrochage ne se perd plus', () {
    test('seuls les signaux call.* attendent la reconnexion', () {
      expect(CallSignalQueue.isCallSignal({'type': 'call.hangup'}), isTrue);
      expect(CallSignalQueue.isCallSignal({'type': 'chat.send'}), isFalse);
      expect(CallSignalQueue.isCallSignal({'type': 42}), isFalse);
    });
    test('ordre conservé, rejoué une fois', () {
      final q = CallSignalQueue();
      q.enqueue({'type': 'call.candidate', 'callId': 'c1', 'n': 1});
      q.enqueue({'type': 'call.candidate', 'callId': 'c1', 'n': 2});
      final out = q.drain();
      expect(out.map((m) => m['n']), [1, 2]);
      expect(q.drain(), isEmpty);
    });
    test('un raccrochage annule les candidats du même appel', () {
      final q = CallSignalQueue();
      q.enqueue({'type': 'call.candidate', 'callId': 'c1'});
      q.enqueue({'type': 'call.candidate', 'callId': 'c2'});
      q.enqueue({'type': 'call.hangup', 'callId': 'c1'});
      final out = q.drain();
      expect(out.map((m) => m['type']), ['call.candidate', 'call.hangup']);
      expect(out.first['callId'], 'c2');
    });
    test('un signal trop vieux n’est pas rejoué', () {
      final q = CallSignalQueue(ttl: const Duration(seconds: 25));
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      q.enqueue({'type': 'call.hangup', 'callId': 'c1'}, now: t0);
      q.enqueue({'type': 'call.candidate', 'callId': 'c2'}, now: t0.add(const Duration(seconds: 20)));
      final out = q.drain(now: t0.add(const Duration(seconds: 30)));
      expect(out.length, 1);
      expect(out.first['callId'], 'c2');
    });
    test('bornée en nombre : les plus anciens cèdent la place', () {
      final q = CallSignalQueue(maxLength: 3);
      for (var i = 0; i < 5; i++) {
        q.enqueue({'type': 'call.candidate', 'callId': 'c', 'n': i});
      }
      expect(q.drain().map((m) => m['n']), [2, 3, 4]);
    });
  });
}
