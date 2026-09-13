#!/usr/bin/env python3
"""Contrôles statiques bloquants du client WeTrackam V17."""
import argparse
from pathlib import Path
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
errors = []
parser = argparse.ArgumentParser()
parser.add_argument(
    "--allow-external-missing",
    action="store_true",
    help="autorise uniquement les fichiers de signature/Firebase iOS externes en CI",
)
args = parser.parse_args()

def require(path: str, needle: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    if needle not in text:
        errors.append(f"{path}: élément absent: {needle}")

require("lib/wetrackam/api_client.dart", "_bootstrapClient.get")
require("lib/wetrackam/provisioning_screen.dart", "verifyPairingPinset")
require("lib/wetrackam/tls_pinning.dart", "Set<String> _expectedHosts")
require("lib/wetrackam/tls_pinning.dart", "spkiSha256Base64(cert.der)")
require("lib/wetrackam/api_client.dart", "'X-Session-Epoch': session.sessionEpoch.toString()")
require("lib/wetrackam/api_client.dart", "invalidAuthResponse")
require("lib/wetrackam/state_sync_service.dart", "if (_lastSeq != null && seq <= _lastSeq!)")
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

# VoIP : les candidats ICE distants reçus pendant la sonnerie doivent
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
    "test/spki_sha256_test.dart",
):
    if not (ROOT / test_file).exists():
        errors.append(f"test automatique absent: {test_file}")

android = ROOT / "android/app/google-services.json"
ios = ROOT / "ios/Runner/GoogleService-Info.plist"
if not android.exists():
    errors.append(f"secret officiel absent: {android.relative_to(ROOT)}")
if not ios.exists() and not args.allow_external_missing:
    errors.append(f"secret officiel absent: {ios.relative_to(ROOT)}")
if android.exists():
    try:
        payload = json.loads(android.read_text(encoding="utf-8"))
        packages = {
            c.get("client_info", {}).get("android_client_info", {}).get("package_name")
            for c in payload.get("client", [])
        }
        if "cm.wetrackam.driver" not in packages:
            errors.append("google-services.json ne cible pas cm.wetrackam.driver")
    except Exception as exc:
        errors.append(f"google-services.json invalide: {exc}")

pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
if "name: wetrackam_client" not in pubspec or "version: 17.0.0+170" not in pubspec:
    errors.append("pubspec.yaml: nom ou version V17 incorrect")
project = (ROOT / "ios/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
if "PRODUCT_BUNDLE_IDENTIFIER = cm.wetrackam.driver;" not in project:
    errors.append("identifiant iOS principal incorrect")
if "org.traccar.client" in project:
    errors.append("ancienne identité iOS encore présente")
firebase = json.loads((ROOT / "firebase.json").read_text(encoding="utf-8"))
if "traccar-client-app" in json.dumps(firebase):
    errors.append("firebase.json référence encore l'ancien projet")

if errors:
    print("LIVRABLE NON PRÊT")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)
print("Contrôles statiques V17 OK (les recettes réelles restent obligatoires).")
