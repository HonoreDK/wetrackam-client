import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wetrackam_client/wetrackam/spki_sha256.dart';

void main() {
  const certificate =
      'MIIDEzCCAfugAwIBAgIUNX1m/sfUOEPQzsq8QVbGDvkFoUAwDQYJKoZIhvcNAQELBQAwGTEXMBUGA1UEAwwOd2V0cmFja2FtLnRlc3QwHhcNMjYwOTA3MTEzNDU4WhcNMjYwOTA4MTEzNDU4WjAZMRcwFQYDVQQDDA53ZXRyYWNrYW0udGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANScp8atExPREXE0t5XJBzJAdeB2czVX8lrn+6No7zmzwyAiridN9Y5bFShzJNW5hI2wwpZRrAvzUtl9Lexdt3cCHSmU5ukNC6ZhuySOHjRefoy7F8Efk/TcDq8sCZuaF9obNc35LBSqzTBukNsICmy0kvNtiA3JVaktK9t8SYRovYjy68g/Zldz63CcBdTLdgYJFB61vZSDx1nOc8rllLWqulj3ci8vCCXYMz1hF67m2PeJPh7lizkE1A/wTPEibfobp1MLnhyaJ/799Fd67Sjg+Zli3vG9y9OCA5oeRVvFlp81xIvhw//K/llIeWExbKBdpV320i8nK3wPZsjt2/0CAwEAAaNTMFEwHQYDVR0OBBYEFD/TVr9rqmjypkZEHti/91Ct9oGgMB8GA1UdIwQYMBaAFD/TVr9rqmjypkZEHti/91Ct9oGgMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAHWU5T/bSUDyjRKoeNzWDoatKio8v3OgVzG/bJleFIv8kDp3T0HU/5l7TY4PLpvIDy9lka+CtKm9bAUD/+GtnShgw7+8q/FN9p2STPZaeJjAeKkss4VHWWP8twDV7ruu4SZp7UL/Z8r7nzlgJz03KLekww3TP0VB2pUW03xON0QP3pEfpv1ISUYYA9yva23AWfqNar8irGTNaKkVJA7AV2pxGy+06/TnSca7eiMgzZjbtVA+nf/B4x4XnF/wPKGx49KhIqtRhraz2G0ad8lD6+wv9KhdbAnN3hqU7ydZ2P6ic78o2kdpFO6GMR+bUcg/FAgPfDhOR9T0toWdnRlF4xc=';

  test('calcule le même hash SPKI qu OpenSSL', () {
    expect(spkiSha256Base64(base64.decode(certificate)),
        'xJlUrvN8Y6NkAR8gL3KzuKYFpTfudrqI5Po0o4/2YXA=');
  });

  test('refuse un certificat tronqué', () {
    expect(() => extractSubjectPublicKeyInfo(base64.decode(certificate).sublist(0, 40)),
        throwsA(isA<DerFormatException>()));
  });
}
