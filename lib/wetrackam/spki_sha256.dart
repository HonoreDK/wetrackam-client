import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class DerFormatException implements Exception {
  const DerFormatException(this.message);
  final String message;
  @override
  String toString() => 'DerFormatException: $message';
}

class _DerElement {
  const _DerElement(this.contentStart, this.contentLength, this.totalLength);
  final int contentStart;
  final int contentLength;
  final int totalLength;
}

_DerElement _readElement(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 2 > bytes.length) {
    throw const DerFormatException('en-tête DER tronqué');
  }
  final lengthByte = bytes[offset + 1];
  var headerLength = 2;
  var contentLength = 0;
  if (lengthByte & 0x80 == 0) {
    contentLength = lengthByte;
  } else {
    final count = lengthByte & 0x7f;
    if (count == 0 || count > 4 || offset + 2 + count > bytes.length) {
      throw const DerFormatException('longueur DER invalide');
    }
    headerLength += count;
    for (var i = 0; i < count; i++) {
      contentLength = (contentLength << 8) | bytes[offset + 2 + i];
    }
  }
  final totalLength = headerLength + contentLength;
  if (offset + totalLength > bytes.length) {
    throw const DerFormatException('élément DER tronqué');
  }
  return _DerElement(offset + headerLength, contentLength, totalLength);
}

/// Extrait le SubjectPublicKeyInfo sans supposer que `version [0]` existe.
Uint8List extractSubjectPublicKeyInfo(Uint8List certificateDer) {
  if (certificateDer.isEmpty || certificateDer[0] != 0x30) {
    throw const DerFormatException('certificat X.509 attendu');
  }
  final certificate = _readElement(certificateDer, 0);
  final tbsOffset = certificate.contentStart;
  if (certificateDer[tbsOffset] != 0x30) {
    throw const DerFormatException('TBSCertificate absent');
  }
  final tbs = _readElement(certificateDer, tbsOffset);
  var position = tbs.contentStart;
  final tbsEnd = tbs.contentStart + tbs.contentLength;
  if (position < tbsEnd && certificateDer[position] == 0xa0) {
    position += _readElement(certificateDer, position).totalLength;
  }
  for (var i = 0; i < 5; i++) {
    if (position >= tbsEnd) {
      throw const DerFormatException('TBSCertificate incomplet');
    }
    position += _readElement(certificateDer, position).totalLength;
  }
  if (position >= tbsEnd || certificateDer[position] != 0x30) {
    throw const DerFormatException('SubjectPublicKeyInfo absent');
  }
  final spki = _readElement(certificateDer, position);
  if (position + spki.totalLength > tbsEnd) {
    throw const DerFormatException('SubjectPublicKeyInfo hors limites');
  }
  return Uint8List.fromList(
      certificateDer.sublist(position, position + spki.totalLength));
}

String spkiSha256Base64(List<int> certificateDer) {
  final spki = extractSubjectPublicKeyInfo(Uint8List.fromList(certificateDer));
  return base64.encode(sha256.convert(spki).bytes);
}
