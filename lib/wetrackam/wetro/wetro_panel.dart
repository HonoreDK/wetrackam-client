import 'package:flutter/material.dart';

import 'wetro_controller.dart';
import 'wetro_dialogue.dart';
import 'wetro_models.dart';
import 'wetro_wave.dart';

/// Le panneau de conversation avec Wetro. Jamais modal : l'application
/// reste utilisable derrière, et le bouton reste visible pour le refermer.
class WetroPanel extends StatefulWidget {
  const WetroPanel({super.key, required this.controller});

  final WetroController controller;

  @override
  State<WetroPanel> createState() => _WetroPanelState();
}

class _WetroPanelState extends State<WetroPanel> {
  final _champ = TextEditingController();
  final _defilement = ScrollController();
  final _focus = FocusNode();
  int _nbMessages = 0;

  WetroController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onChange);
    _nbMessages = c.messages.length;
  }

  @override
  void dispose() {
    c.removeListener(_onChange);
    _champ.dispose();
    _defilement.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    final n = c.messages.length;
    setState(() {});
    if (n != _nbMessages || c.busy) {
      _nbMessages = n;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_defilement.hasClients) return;
        _defilement.animateTo(
          _defilement.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _envoie([String? texte]) {
    final q = (texte ?? _champ.text).trim();
    if (q.isEmpty || c.busy) return;
    _champ.clear();
    c.send(q);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sources = c.state.sources.map(wetroSourceLibelle).toList();
    final conduite = c.host?.driving ?? false;
    final sousTitre = conduite
        ? 'Mode conduite : parlez-moi, je vous réponds à voix haute'
        : (sources.isEmpty
            ? 'Rien à consulter pour le moment'
            : 'Je connais : ${sources.join(', ')}');
    final vocal = c.voiceActive;

    return Material(
      elevation: 12,
      color: scheme.surface,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // ------------------------------------------------------ en-tête
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            color: scheme.primaryContainer,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.primary,
                  child: Icon(Icons.auto_awesome, size: 18, color: scheme.onPrimary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Wetro', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                      Text(
                        sousTitre,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer.withValues(alpha: 0.8)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: c.wakeEnabled ? '« Wetro » à l’oreille : activé' : '« Wetro » à l’oreille : désactivé',
                  isSelected: c.wakeEnabled,
                  onPressed: () => c.setWakeEnabled(!c.wakeEnabled),
                  icon: const Icon(Icons.hearing_outlined),
                  selectedIcon: const Icon(Icons.hearing),
                ),
                IconButton(
                  tooltip: c.speakEnabled ? 'Réponses lues à voix haute' : 'Réponses silencieuses',
                  isSelected: c.speakEnabled,
                  onPressed: () => c.setSpeakEnabled(!c.speakEnabled),
                  icon: const Icon(Icons.volume_off_outlined),
                  selectedIcon: const Icon(Icons.volume_up),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  onPressed: c.closePanel,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),

          // ---------------------------------------------------------- fil
          Expanded(
            child: ListView(
              controller: _defilement,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              children: [
                if (c.messages.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      conduite
                          ? 'Bonjour, je suis Wetro. Vous roulez : appuyez sur le micro ou dites « Wetro », je vous écoute.'
                          : 'Bonjour, je suis Wetro. Posez-moi votre question, ou appuyez sur le micro et parlez.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (c.note != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(c.note!, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                for (final m in c.messages) _Bulle(message: m, controller: c),
                if (c.busy)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text('Wetro réfléchit…', style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                if (c.messages.isEmpty && c.suggestions.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final s in c.suggestions)
                        ActionChip(
                          label: Text(s),
                          onPressed: c.busy ? null : () => _envoie(s),
                        ),
                    ],
                  ),
              ],
            ),
          ),

          if (c.avis != null)
            _Bandeau(texte: c.avis!, couleur: scheme.tertiaryContainer, surCouleur: scheme.onTertiaryContainer),
          if (c.error != null)
            _Bandeau(texte: c.error!, couleur: scheme.errorContainer, surCouleur: scheme.onErrorContainer),

          // -------------------------------------------------------- saisie
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: vocal
                ? _ZoneVocale(controller: c)
                : (conduite
                    ? _ZoneConduite(key: const ValueKey('conduite'), occupe: c.busy, onMicro: c.startVoice)
                    : _ZoneTexte(
                        key: const ValueKey('texte'),
                        champ: _champ,
                        focus: _focus,
                        occupe: c.busy,
                        onEnvoyer: _envoie,
                        onMicro: c.startVoice,
                      )),
          ),
        ],
      ),
    );
  }

}

/// Mode conduite (§8) : la saisie est verrouillee au-dessus du seuil de
/// vitesse de l'espace, comme dans la conversation. Un seul grand bouton :
/// le micro. Wetro repond a voix haute.
class _ZoneConduite extends StatelessWidget {
  const _ZoneConduite({super.key, required this.occupe, required this.onMicro});

  final bool occupe;
  final VoidCallback onMicro;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Saisie désactivée pendant la conduite.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          FilledButton.icon(
            onPressed: occupe ? null : onMicro,
            icon: const Icon(Icons.mic),
            label: const Text('Parler'),
          ),
        ],
      ),
    );
  }
}

class _ZoneTexte extends StatelessWidget {
  const _ZoneTexte({
    super.key,
    required this.champ,
    required this.focus,
    required this.occupe,
    required this.onEnvoyer,
    required this.onMicro,
  });

  final TextEditingController champ;
  final FocusNode focus;
  final bool occupe;
  final void Function([String? texte]) onEnvoyer;
  final Future<void> Function() onMicro;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: champ,
              focusNode: focus,
              minLines: 1,
              maxLines: 4,
              maxLength: wetroMaxQuestion,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onEnvoyer(),
              decoration: const InputDecoration(
                hintText: 'Votre question…',
                isDense: true,
                counterText: '',
                border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Parler à Wetro',
            onPressed: occupe ? null : () => onMicro(),
            icon: const Icon(Icons.mic),
          ),
          IconButton.filled(
            tooltip: 'Envoyer',
            onPressed: occupe ? null : () => onEnvoyer(),
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

class _ZoneVocale extends StatelessWidget {
  const _ZoneVocale({required this.controller});

  final WetroController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = controller;
    return Padding(
      key: const ValueKey('vocal'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          WetroWave(phase: c.phase, level: c.level),
          Row(
            children: [
              Expanded(
                child: Text(
                  c.voiceHint,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (c.phase == WetroVoicePhase.wake)
                TextButton.icon(
                  onPressed: c.startVoice,
                  icon: const Icon(Icons.mic, size: 18),
                  label: const Text('Parler'),
                )
              else
                TextButton.icon(
                  onPressed: () => c.stopVoice(),
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('Stop'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bandeau extends StatelessWidget {
  const _Bandeau({required this.texte, required this.couleur, required this.surCouleur});

  final String texte;
  final Color couleur;
  final Color surCouleur;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: couleur, borderRadius: BorderRadius.circular(10)),
      child: Text(texte, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: surCouleur)),
    );
  }
}

class _Bulle extends StatelessWidget {
  const _Bulle({required this.message, required this.controller});

  final WetroMessage message;
  final WetroController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final deMoi = message.deMoi;
    final action = message.action;
    final montrePuce = action != null && !message.actionDone && !deMoi;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: deMoi ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: deMoi ? scheme.primary : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(deMoi ? 14 : 4),
                  bottomRight: Radius.circular(deMoi ? 4 : 14),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (message.vocal)
                    Padding(
                      padding: const EdgeInsets.only(right: 6, top: 2),
                      child: Icon(Icons.mic, size: 14, color: deMoi ? scheme.onPrimary : scheme.onSurfaceVariant),
                    ),
                  Flexible(
                    child: SelectableText(
                      message.content,
                      style: theme.textTheme.bodyMedium?.copyWith(color: deMoi ? scheme.onPrimary : scheme.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (montrePuce)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 6,
                children: [
                  ActionChip(
                    avatar: Icon(_icone(action.type), size: 16),
                    label: Text(action.libelle),
                    onPressed: () => controller.runAction(action),
                  ),
                  if (action.needsConfirmation)
                    ActionChip(
                      label: const Text('Annuler'),
                      onPressed: () => controller.declineAction(action),
                    ),
                ],
              ),
            ),
          if (message.actionRefused && action == null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Action non permise dans votre entreprise.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  static IconData _icone(WetroActionType t) => switch (t) {
        WetroActionType.callDriver => Icons.call,
        WetroActionType.callManager => Icons.support_agent,
        WetroActionType.messageDriver => Icons.send,
        WetroActionType.openConversation => Icons.chat_bubble_outline,
        WetroActionType.openScreen => Icons.open_in_new,
        WetroActionType.sos => Icons.sos,
      };
}
