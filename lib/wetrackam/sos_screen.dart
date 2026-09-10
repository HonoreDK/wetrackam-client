// lib/wetrackam/sos_screen.dart
//
// Écran SOS du chauffeur.
//
// POURQUOI CET ÉCRAN EXISTE
// -------------------------
// Toute la chaîne de détresse était déjà en place — `POST /api/distress`
// (idempotent, arme l'escalade, réveille les véhicules voisins),
// DistressService avec sa reprise hors ligne — mais RIEN dans l'application
// ne permettait de la déclencher : le seul point d'entrée était un raccourci
// du lanceur Android (appui long sur l'icône), invisible pour un chauffeur,
// et qui fermait l'application aussitôt sans lui dire si l'alerte était
// partie. Une fonction de sécurité que personne ne trouve n'existe pas.
//
// DEUX EXIGENCES QUI S'OPPOSENT, ET COMMENT ELLES SONT TRANCHÉES
// --------------------------------------------------------------
//  1. Joignable en une seconde, une seule main, sans réfléchir.
//  2. Impossible à déclencher par accident — un téléphone posé sur le siège
//     d'un camion sur une piste subit des chocs permanents, et une fausse
//     alerte réveille des voisins, arme une escalade et détruit la confiance
//     dans le bouton lui-même.
// D'où l'APPUI MAINTENU de 3 secondes avec retour visuel continu : rien ne
// part sur un contact fortuit, et le geste reste immédiat et sans menu.
//
// La nature de l'alerte est choisie AVANT l'appui, jamais après : en
// situation réelle on n'a pas le temps de répondre à des questions.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../location_cache.dart';
import 'api_client.dart';
import 'app_logger.dart';
import 'distress_service.dart';
import 'theme.dart';

/// Catalogue FERMÉ, strictement aligné sur `Distress.KINDS` côté serveur.
/// Une nature inconnue y serait silencieusement ramenée à « sos » : autant
/// n'en proposer que des valides.
const _kinds = <({String code, String label, IconData icon})>[
  (code: 'sos', label: 'Détresse', icon: Icons.priority_high),
  (code: 'accident', label: 'Accident', icon: Icons.car_crash),
  (code: 'medical', label: 'Urgence médicale', icon: Icons.medical_services),
  (code: 'security', label: 'Agression', icon: Icons.shield),
  (code: 'breakdown', label: 'Panne', icon: Icons.build),
];

class SosScreen extends StatefulWidget {
  const SosScreen({super.key});

  @override
  State<SosScreen> createState() => _SosScreenState();
}

enum _SosState { ready, sending, sent, queued }

class _SosScreenState extends State<SosScreen> with SingleTickerProviderStateMixin {
  static const _holdDuration = Duration(seconds: 3);

  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: _holdDuration,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) _fire();
    });

  String _kind = 'sos';
  final _noteController = TextEditingController();
  _SosState _state = _SosState.ready;
  Map<String, dynamic>? _result;
  String? _failure;

  /// Relevé UNE fois, jamais depuis build(). LocationCache lit les
  /// préférences, qui peuvent ne pas être initialisées : une exception levée
  /// pendant la construction ferait planter l'écran SOS à son ouverture —
  /// exactement l'instant où il ne doit surtout pas défaillir.
  bool _hasPosition = false;

  @override
  void initState() {
    super.initState();
    try {
      _hasPosition = LocationCache.get() != null;
    } catch (error) {
      AppLogger.error('sos_position_unavailable', error);
      _hasPosition = false;
    }
  }

  @override
  void dispose() {
    _hold.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _startHold() {
    if (_state != _SosState.ready) return;
    HapticFeedback.selectionClick();
    _hold.forward();
  }

  void _cancelHold() {
    if (_hold.isAnimating) _hold.reverse();
  }

  Future<void> _fire() async {
    if (_state != _SosState.ready) return;
    // Vibration franche : le chauffeur sait que c'est parti sans regarder
    // l'écran — il a probablement autre chose à faire à cet instant.
    HapticFeedback.heavyImpact();
    setState(() {
      _state = _SosState.sending;
      _failure = null;
    });
    AppLogger.breadcrumb('sos_triggered:$_kind');
    try {
      final result = await DistressService.raiseSos(
        kind: _kind,
        note: _noteController.text,
      );
      if (!mounted) return;
      setState(() {
        _state = _SosState.sent;
        _result = result;
      });
    } on NetworkException {
      // L'alerte n'est PAS perdue : DistressService a conservé son alertId et
      // la rejouera au retour du réseau, sans jamais créer de doublon. On le
      // dit clairement plutôt que d'afficher un échec qui pousserait le
      // chauffeur à marteler le bouton.
      if (!mounted) return;
      setState(() => _state = _SosState.queued);
    } catch (error) {
      AppLogger.error('sos_failed', error);
      if (!mounted) return;
      setState(() {
        _state = _SosState.ready;
        _failure = error is ApiException && error.reason != null
            ? 'Envoi refusé (${error.reason}). Prévenez votre gestionnaire.'
            : 'Envoi impossible. Réessayez.';
      });
      _hold.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: WetrackamColors.ink,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Alerte SOS'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: switch (_state) {
            _SosState.sent || _SosState.queued => _confirmationView(),
            _ => _triggerView(),
          },
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Déclenchement
  // ---------------------------------------------------------------------
  Widget _triggerView() {
    final sending = _state == _SosState.sending;
    return Column(
      children: [
        const SizedBox(height: 8),
        _kindSelector(sending),
        const SizedBox(height: 20),
        Expanded(child: Center(child: _holdButton(sending))),
        if (_failure != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _failure!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: WetrackamColors.error),
            ),
          ),
        _noteField(sending),
        const SizedBox(height: 12),
        _positionHint(),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _kindSelector(bool disabled) {
    return SizedBox(
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _kinds.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final kind = _kinds[index];
          final selected = kind.code == _kind;
          return InkWell(
            onTap: disabled ? null : () => setState(() => _kind = kind.code),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 92,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(
                color: selected ? WetrackamColors.error : Colors.white10,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? WetrackamColors.error : Colors.white24,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(kind.icon, color: Colors.white, size: 26),
                  const SizedBox(height: 6),
                  Text(
                    kind.label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _holdButton(bool sending) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Listener (événements pointeur BRUTS) et non GestureDetector : un
        // TapGestureRecognizer abandonne le geste dès que le doigt glisse de
        // quelques pixels. Sur la piste, un chauffeur qui maintient le bouton
        // pendant 3 secondes bouge forcément — son SOS se serait annulé tout
        // seul, encore et encore, sans qu'il comprenne pourquoi. Ici, seul le
        // relâchement réel (ou une annulation système) interrompt l'appui.
        Listener(
          onPointerDown: (_) => _startHold(),
          onPointerUp: (_) => _cancelHold(),
          onPointerCancel: (_) => _cancelHold(),
          child: AnimatedBuilder(
            animation: _hold,
            builder: (context, child) {
              return SizedBox(
                width: 208,
                height: 208,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Anneau de progression : le chauffeur VOIT le compte à
                    // rebours et peut relâcher tant qu'il n'est pas plein.
                    SizedBox(
                      width: 208,
                      height: 208,
                      child: CircularProgressIndicator(
                        value: sending ? null : _hold.value,
                        strokeWidth: 8,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation(WetrackamColors.error),
                      ),
                    ),
                    Container(
                      width: 168,
                      height: 168,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: WetrackamColors.error,
                      ),
                      child: Center(
                        child: Text(
                          sending ? 'Envoi...' : 'SOS',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 40,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 18),
        Text(
          sending ? 'Transmission de votre alerte' : 'Maintenez appuyé 3 secondes',
          style: const TextStyle(color: WetrackamColors.slate),
        ),
      ],
    );
  }

  Widget _noteField(bool disabled) {
    return TextField(
      controller: _noteController,
      enabled: !disabled,
      maxLength: 200,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: 'Précision (facultatif)',
        hintStyle: const TextStyle(color: WetrackamColors.slate),
        counterText: '',
        filled: true,
        fillColor: Colors.white10,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// Dire la vérité sur la position transmise. Le serveur sait se rabattre sur
  /// la dernière position connue du véhicule, mais le chauffeur doit savoir ce
  /// qui part réellement — surtout s'il est hors couverture depuis longtemps.
  Widget _positionHint() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(_hasPosition ? Icons.my_location : Icons.location_disabled,
            size: 15, color: WetrackamColors.slate),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            _hasPosition
                ? 'Votre position sera transmise avec l\'alerte'
                : 'Position inconnue : la dernière position du véhicule sera utilisée',
            style: const TextStyle(color: WetrackamColors.slate, fontSize: 12),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Confirmation — le chauffeur doit savoir, sans ambiguïté, que c'est parti
  // ---------------------------------------------------------------------
  Widget _confirmationView() {
    final queued = _state == _SosState.queued;
    final neighbors = (_result?['neighborsNotified'] as num?)?.toInt() ?? 0;
    final duplicate = _result?['duplicate'] == true;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          queued ? Icons.cloud_off : Icons.check_circle,
          size: 92,
          color: queued ? WetrackamColors.warning : WetrackamColors.success,
        ),
        const SizedBox(height: 20),
        Text(
          queued ? 'Alerte en attente de réseau' : 'Alerte transmise',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Text(
          queued
              ? 'Elle partira automatiquement dès le retour du signal, sans que vous ayez à y revenir. Si vous le pouvez, appelez directement votre gestionnaire.'
              : duplicate
                  ? 'Cette alerte était déjà enregistrée : vos secours n\'ont pas été prévenus deux fois.'
                  : neighbors > 0
                      ? 'Votre gestionnaire est prévenu, ainsi que $neighbors véhicule${neighbors > 1 ? 's' : ''} à proximité.'
                      : 'Votre gestionnaire est prévenu.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: WetrackamColors.slate, height: 1.4),
        ),
        const SizedBox(height: 36),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: const Text('Retour'),
          ),
        ),
      ],
    );
  }
}
