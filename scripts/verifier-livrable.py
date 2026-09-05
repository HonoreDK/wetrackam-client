#!/usr/bin/env python3
"""Contrôles statiques bloquants du client WeTrackam v15."""
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
errors = []

def require(path: str, needle: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    if needle not in text:
        errors.append(f"{path}: élément absent: {needle}")

require("lib/wetrackam/api_client.dart", "_bootstrapClient.get")
require("lib/wetrackam/provisioning_screen.dart", "verifyPairingPinset")
require("lib/wetrackam/tls_pinning.dart", "Set<String> _expectedHosts")
require("lib/wetrackam/discovery_service.dart", "TlsPinning.setExpectedHost(value)")
require("lib/wetrackam/realtime_service.dart", "_readyCompleter")
require("lib/wetrackam/call_service.dart", "_pendingLocalCandidates")
require("lib/wetrackam/chat_service.dart", "case 'chat.messages':")
require("lib/wetrackam/chat_service.dart", "_lastTypingSentByPeer")
require("lib/wetrackam/chat_service.dart", "'status': 'failed'")
require("lib/wetrackam/voice_note_service.dart", "ChatService.sendVoice")
require("lib/wetrackam/conversation_screen.dart", "_insertOrUpdate(message)")
require("lib/wetrackam/conversation_screen.dart", "_driveLocked")
require("lib/main.dart", "VoiceNoteService.purgeAll")
require("ios/Runner/Runner.entitlements", "$(APS_ENVIRONMENT)")

# v15 — VoIP : les candidats ICE distants reçus pendant la sonnerie doivent
# être mémorisés puis appliqués, sinon l'appel décroche mais reste muet.
require("lib/wetrackam/call_service.dart", "_pendingRemoteCandidates")
require("lib/wetrackam/call_service.dart", "_flushRemoteCandidates()")
# Carte des collègues : conversion nœuds -> km/h centralisée et testée.
require("lib/wetrackam/fleet_units.dart", "kmhFromSocketKnots")
require("lib/wetrackam/fleet_screen.dart", "FleetUnits.kmhFromSocketKnots")
# Prise de service : les trois modes du contrat doivent rester traités.
for mode in ("ASSIGNED_WITH_FALLBACK", "FREE_POOL", "pendingAssignment"):
    require("lib/wetrackam/eligibility_screen.dart", mode)

# Tests automatiques : leur absence est bloquante (ils tournent chez
# l'intégrateur avec `flutter test`, sans téléphone ni serveur).
for test_file in (
    "test/fleet_units_test.dart",
    "test/rtc_policy_test.dart",
    "test/chat_queue_test.dart",
    "test/error_catalog_test.dart",
):
    if not (ROOT / test_file).exists():
        errors.append(f"test automatique absent: {test_file}")

android = ROOT / "android/app/google-services.json"
ios = ROOT / "ios/Runner/GoogleService-Info.plist"
for path in (android, ios):
    if not path.exists():
        errors.append(f"secret officiel absent: {path.relative_to(ROOT)}")
if android.exists():
    try:
        payload = json.loads(android.read_text(encoding="utf-8"))
        packages = {
            c.get("client_info", {}).get("android_client_info", {}).get("package_name")
            for c in payload.get("client", [])
        }
        if "org.traccar.client" not in packages:
            errors.append("google-services.json ne cible pas org.traccar.client")
    except Exception as exc:
        errors.append(f"google-services.json invalide: {exc}")

if errors:
    print("LIVRABLE NON PRÊT")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)
print("Contrôles statiques OK (les recettes réelles restent obligatoires).")