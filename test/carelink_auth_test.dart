import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:minimed_pixel_bridge/services/carelink_service.dart';
import 'package:minimed_pixel_bridge/services/credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _makeJwt({
  required int expEpochSeconds,
  String username = 'user@example.com',
  String country = 'PT',
}) {
  final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'RS256'})));
  final payload = base64Url.encode(utf8.encode(jsonEncode({
    'exp': expEpochSeconds,
    'token_details': {
      'preferred_username': username,
      'country': country,
    },
  })));
  return '$header.$payload.sig';
}

Map<String, dynamic> _sampleDiscoverResponse() => {
      'supportedCountries': [
        {
          'PT': {'region': 'EU'}
        }
      ],
      'CP': [
        {
          'region': 'EU',
          'UseSSOConfiguration': 'Auth0SSOConfiguration',
          'Auth0SSOConfiguration':
              'https://carelink.minimed.eu/configs/v1/carepartner_auth0_ous_sso_config_v1.json',
          'baseUrlCareLink': 'https://carelink.minimed.eu/api/carepartner/v2',
          'baseUrlCumulus':
              'https://clcloud.minimed.eu/connect/carepartner/v13',
        }
      ],
    };

Map<String, dynamic> _sampleSsoConfig() => {
      'server': {
        'hostname': 'carelink-login.minimed.eu',
        'port': 443,
        'prefix': '',
      },
      'system_endpoints': {
        'token_endpoint_path': '/oauth/token',
      },
    };

Map<String, dynamic> _samplePatientMessageJson({int sg = 128}) => {
      'patientData': {
        'lastSG': {
          'sg': sg,
          'datetime': '2026-11-17T20:00:00.000Z',
        },
        'lastSGTrend': 'NONE',
        'activeInsulin': {'amount': 1.25},
        'sgs': [
          {'sg': 122, 'datetime': '2026-11-17T19:55:00.000Z'},
          {'sg': sg, 'datetime': '2026-11-17T20:00:00.000Z'},
        ],
      },
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Valid CareLink token fetches telemetry without unnecessary refresh',
      () async {
    final now = DateTime.utc(2026, 11, 17, 20, 0);
    final validJwt = _makeJwt(
      expEpochSeconds:
          now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000,
    );
    int refreshCalls = 0;

    final client = MockClient((req) async {
      final url = req.url.toString();
      if (url.contains('discover/android')) {
        return http.Response(jsonEncode(_sampleDiscoverResponse()), 200);
      }
      if (url.contains('sso_config')) {
        return http.Response(jsonEncode(_sampleSsoConfig()), 200);
      }
      if (url.contains('/oauth/token')) {
        refreshCalls++;
        return http.Response('{}', 500);
      }
      if (url.endsWith('/users/me')) {
        return http.Response(jsonEncode({'role': 'PATIENT'}), 200);
      }
      if (url.endsWith('/display/message')) {
        return http.Response(
            jsonEncode(_samplePatientMessageJson(sg: 142)), 200);
      }
      return http.Response('Not found', 404);
    });

    final store = InMemoryCredentialStore();
    final service = CareLinkService(
      httpClient: client,
      credentialStore: store,
      nowProvider: () => now,
    );

    await service.saveRawLoginData(jsonEncode({
      'access_token': validJwt,
      'refresh_token': 'ref_valid_1',
      'client_id': 'cid_1',
    }));

    final telemetry = await service.fetchLatestTelemetry(throwOnError: true);
    expect(refreshCalls, 0);
    expect(telemetry.sgValue, 142);
    expect(
      await service.getSessionStatus(),
      CareLinkSessionStatus.connected,
    );
  });

  test('Expired token automatically refreshes and replaces rotated refresh_token',
      () async {
    final now = DateTime.utc(2026, 11, 17, 20, 0);
    final expiredJwt = _makeJwt(
      expEpochSeconds:
          now.subtract(const Duration(minutes: 5)).millisecondsSinceEpoch ~/
              1000,
    );
    final freshJwt = _makeJwt(
      expEpochSeconds:
          now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000,
    );

    int refreshCalls = 0;
    String? sentGrantType;
    String? sentClientSecret;
    String? sentMagHeader;

    final client = MockClient((req) async {
      final url = req.url.toString();
      if (url.contains('discover/android')) {
        return http.Response(jsonEncode(_sampleDiscoverResponse()), 200);
      }
      if (url.contains('sso_config')) {
        return http.Response(jsonEncode(_sampleSsoConfig()), 200);
      }
      if (url.endsWith('/oauth/token')) {
        refreshCalls++;
        final params = Uri.splitQueryString(req.body);
        sentGrantType = params['grant_type'];
        sentClientSecret = params['client_secret'];
        sentMagHeader = req.headers['mag-identifier'];
        return http.Response(
          jsonEncode({
            'access_token': freshJwt,
            'refresh_token': 'ref_rotated_2',
            'expires_in': 7200,
          }),
          200,
        );
      }
      if (url.endsWith('/users/me')) {
        expect(req.headers['Authorization'], 'Bearer $freshJwt');
        return http.Response(jsonEncode({'role': 'PATIENT'}), 200);
      }
      if (url.endsWith('/display/message')) {
        return http.Response(
            jsonEncode(_samplePatientMessageJson(sg: 156)), 200);
      }
      return http.Response('Not found', 404);
    });

    final store = InMemoryCredentialStore();
    final service = CareLinkService(
      httpClient: client,
      credentialStore: store,
      nowProvider: () => now,
    );

    await service.saveRawLoginData(jsonEncode({
      'access_token': expiredJwt,
      'refresh_token': 'ref_initial_1',
      'client_id': 'cid_1',
      'client_secret': 'dyn_secret_1',
      'mag-identifier': 'mag_abc',
    }));

    final telemetry = await service.fetchLatestTelemetry(throwOnError: true);
    expect(refreshCalls, 1);
    expect(sentGrantType, 'refresh_token');
    expect(sentClientSecret, 'dyn_secret_1');
    expect(sentMagHeader, 'mag_abc');
    expect(telemetry.sgValue, 156);

    final updated = await service.loadStoredTokenBundle();
    expect(updated, isNotNull);
    expect(updated!.accessToken, freshJwt);
    expect(updated.refreshToken, 'ref_rotated_2');
    expect(updated.reauthRequired, isFalse);
  });

  test('Concurrent requests trigger only ONE synchronized OAuth2 refresh',
      () async {
    final now = DateTime.utc(2026, 11, 17, 20, 0);
    // Expiring in 5 minutes (< 600s proactive refresh buffer)
    final expiringJwt = _makeJwt(
      expEpochSeconds:
          now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000,
    );
    final freshJwt = _makeJwt(
      expEpochSeconds:
          now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000,
    );

    int refreshCalls = 0;

    final client = MockClient((req) async {
      final url = req.url.toString();
      if (url.contains('discover/android')) {
        return http.Response(jsonEncode(_sampleDiscoverResponse()), 200);
      }
      if (url.contains('sso_config')) {
        return http.Response(jsonEncode(_sampleSsoConfig()), 200);
      }
      if (url.endsWith('/oauth/token')) {
        refreshCalls++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return http.Response(
          jsonEncode({
            'access_token': freshJwt,
            'refresh_token': 'ref_once',
          }),
          200,
        );
      }
      if (url.endsWith('/users/me')) {
        return http.Response(jsonEncode({'role': 'PATIENT'}), 200);
      }
      if (url.endsWith('/display/message')) {
        return http.Response(
            jsonEncode(_samplePatientMessageJson(sg: 118)), 200);
      }
      return http.Response('Not found', 404);
    });

    final store = InMemoryCredentialStore();
    final service = CareLinkService(
      httpClient: client,
      credentialStore: store,
      nowProvider: () => now,
    );

    await service.saveRawLoginData(jsonEncode({
      'access_token': expiringJwt,
      'refresh_token': 'ref_old',
      'client_id': 'cid_sync',
    }));

    final results = await Future.wait([
      service.ensureValidTokenBundle(),
      service.ensureValidTokenBundle(),
      service.ensureValidTokenBundle(),
    ]);

    expect(refreshCalls, 1);
    for (final b in results) {
      expect(b.accessToken, freshJwt);
      expect(b.refreshToken, 'ref_once');
    }
  });

  test('Invalid/revoked refresh token sets reauthRequired state', () async {
    final now = DateTime.utc(2026, 11, 17, 20, 0);
    final expiredJwt = _makeJwt(
      expEpochSeconds:
          now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
              1000,
    );

    final client = MockClient((req) async {
      final url = req.url.toString();
      if (url.contains('discover/android')) {
        return http.Response(jsonEncode(_sampleDiscoverResponse()), 200);
      }
      if (url.contains('sso_config')) {
        return http.Response(jsonEncode(_sampleSsoConfig()), 200);
      }
      if (url.endsWith('/oauth/token')) {
        return http.Response(
          jsonEncode({'error': 'invalid_grant'}),
          400,
        );
      }
      return http.Response('Not found', 404);
    });

    final store = InMemoryCredentialStore();
    final service = CareLinkService(
      httpClient: client,
      credentialStore: store,
      nowProvider: () => now,
    );

    await service.saveRawLoginData(jsonEncode({
      'access_token': expiredJwt,
      'refresh_token': 'ref_revoked',
      'client_id': 'cid_1',
    }));

    await expectLater(
      service.fetchLatestTelemetry(throwOnError: true),
      throwsA(
        isA<CareLinkAuthException>().having(
          (e) => e.kind,
          'kind',
          CareLinkAuthErrorKind.reauthRequired,
        ),
      ),
    );

    expect(
      await service.getSessionStatus(),
      CareLinkSessionStatus.reauthRequired,
    );
    final saved = await service.loadStoredTokenBundle();
    expect(saved!.reauthRequired, isTrue);
  });

  test('Network failure sets offline status while preserving refresh_token',
      () async {
    final now = DateTime.utc(2026, 11, 17, 20, 0);
    final expiredJwt = _makeJwt(
      expEpochSeconds:
          now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
              1000,
    );

    final client = MockClient((req) async {
      throw const SocketException('No internet');
    });

    final store = InMemoryCredentialStore();
    final service = CareLinkService(
      httpClient: client,
      credentialStore: store,
      nowProvider: () => now,
    );

    await service.saveRawLoginData(jsonEncode({
      'access_token': expiredJwt,
      'refresh_token': 'ref_keep_me',
      'client_id': 'cid_1',
    }));

    await expectLater(
      service.fetchLatestTelemetry(throwOnError: true),
      throwsA(
        isA<CareLinkAuthException>().having(
          (e) => e.kind,
          'kind',
          CareLinkAuthErrorKind.networkError,
        ),
      ),
    );

    expect(
      await service.getSessionStatus(),
      CareLinkSessionStatus.offline,
    );
    final stored = await service.loadStoredTokenBundle();
    expect(stored!.refreshToken, 'ref_keep_me');
    expect(stored.reauthRequired, isFalse);
  });

  test('Migrates legacy plaintext SharedPreferences token into encrypted storage and sanitizes logs',
      () async {
    final futureJwt = _makeJwt(expEpochSeconds: 2000000000);
    final rawLegacy = jsonEncode({
      'access_token': futureJwt,
      'refresh_token': 'ref_secret_value',
      'client_id': 'cid_1',
      'client_secret': 'super_secret_xyz',
    });

    SharedPreferences.setMockInitialValues({
      CareLinkService.prefKeyLegacyAuthToken: rawLegacy,
    });

    final store = InMemoryCredentialStore();
    final service = CareLinkService(credentialStore: store);

    final migrated = await service.loadStoredTokenBundle();
    expect(migrated, isNotNull);
    expect(migrated!.refreshToken, 'ref_secret_value');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(CareLinkService.prefKeyLegacyAuthToken), isNull);
    expect(store.snapshot.containsKey(CareLinkService.secureKeyTokenBundle),
        isTrue);

    final sanitized = CareLinkService.sanitizeErrorText(
      'Authorization: Bearer $futureJwt refresh_token=ref_secret_value',
    );
    expect(sanitized.contains('ref_secret_value'), isFalse);
    expect(sanitized.contains('eyJ'), isFalse);
  });

  test('parseLoginDataOrToken strips BOM, handles variants, and preserves all OAuth params', () {
    final jwt = _makeJwt(expEpochSeconds: 2000000000, username: 'jose@example.pt');
    const bom = '\uFEFF';
    final raw = '$bom${jsonEncode({
      'access_token': jwt,
      'refresh_token': 'ref_keep_99',
      'client_id': 'PeAhkbhQWlQRxJiQxWfcFBiGus1lxfe9',
      'mag-identifier': 'mag_device_01',
      'client_secret': 'secret_01',
      'scope': 'profile openid roles country',
    })}';

    final parsed = CareLinkService.parseLoginDataOrToken(raw);
    expect(parsed, isNotNull);
    expect(parsed!.refreshToken, 'ref_keep_99');
    expect(parsed.clientId, 'PeAhkbhQWlQRxJiQxWfcFBiGus1lxfe9');
    expect(parsed.magIdentifier, 'mag_device_01');
    expect(parsed.clientSecret, 'secret_01');
    expect(parsed.scope, 'profile openid roles country');
  });

  test('inspectBundleRefresh never claims verified solely because refresh_token exists and reports exact missing fields', () async {
    final validJwt = _makeJwt(expEpochSeconds: 2000000000);

    // 1. Raw access_token only -> incomplete & names exact missing fields
    final rawOnly = CareLinkService.parseLoginDataOrToken(validJwt);
    final rawDiag = CareLinkService.inspectBundleRefresh(rawOnly);
    expect(rawDiag.readiness, CareLinkRefreshReadiness.incomplete);
    expect(rawDiag.missingFields, containsAll(['refresh_token', 'client_id']));
    expect(rawDiag.detailPt.contains(validJwt), isFalse);

    // 2. Full Auth0 parameters imported -> readyToTest (NOT verified yet!)
    final completeImport = CareLinkService.parseLoginDataOrToken(jsonEncode({
      'access_token': validJwt,
      'refresh_token': 'ref_abc',
      'client_id': 'cid_auth0',
    }));
    final untestedDiag = CareLinkService.inspectBundleRefresh(completeImport);
    expect(untestedDiag.readiness, CareLinkRefreshReadiness.readyToTest);
    expect(untestedDiag.isVerified, isFalse);
    expect(untestedDiag.missingFields, isEmpty);
  });

  test('testRefresh resolves Auth0 SSO client_id, persists rotated tokens, and keeps active session alive on refresh failure', () async {
    final now = DateTime.utc(2026, 11, 17, 20, 0);
    final activeJwt = _makeJwt(
      expEpochSeconds:
          now.add(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000,
    );
    final rotatedJwt = _makeJwt(
      expEpochSeconds:
          now.add(const Duration(hours: 6)).millisecondsSinceEpoch ~/ 1000,
    );
    bool rejectNextRefresh = false;

    final client = MockClient((req) async {
      final url = req.url.toString();
      if (url.contains('discover/android')) {
        return http.Response(jsonEncode(_sampleDiscoverResponse()), 200);
      }
      if (url.contains('sso_config')) {
        return http.Response(
          jsonEncode({
            ..._sampleSsoConfig(),
            'client': {
              'client_id': 'PeAhkbhQWlQRxJiQxWfcFBiGus1lxfe9',
              'client_secret': '',
              'scope': 'profile openid roles country',
            },
          }),
          200,
        );
      }
      if (url.endsWith('/oauth/token')) {
        if (rejectNextRefresh) {
          return http.Response(
            jsonEncode({'error': 'invalid_grant', 'error_description': 'Expired refresh token'}),
            400,
          );
        }
        expect(req.bodyFields['client_id'], 'PeAhkbhQWlQRxJiQxWfcFBiGus1lxfe9');
        expect(req.bodyFields['refresh_token'], isNotEmpty);
        return http.Response(
          jsonEncode({
            'access_token': rotatedJwt,
            'refresh_token': 'ref_rotated_ok',
            'expires_in': 21600,
          }),
          200,
        );
      }
      return http.Response('Not found', 404);
    });

    final store = InMemoryCredentialStore();
    final service = CareLinkService(
      httpClient: client,
      credentialStore: store,
      nowProvider: () => now,
    );

    // Save Auth0 bundle missing client_id locally -> SSO discovery resolves it and testRefresh verifies!
    await service.saveRawLoginData(jsonEncode({
      'access_token': activeJwt,
      'refresh_token': 'ref_initial_ok',
    }));

    final preDiag = await service.inspectStoredRefresh();
    expect(preDiag.readiness, CareLinkRefreshReadiness.incomplete);
    expect(preDiag.missingFields, equals(['client_id']));

    final testOk = await service.testRefresh();
    expect(testOk.readiness, CareLinkRefreshReadiness.verified);
    expect(testOk.isVerified, isTrue);

    final afterOk = await service.loadStoredTokenBundle();
    expect(afterOk!.clientId, 'PeAhkbhQWlQRxJiQxWfcFBiGus1lxfe9');
    expect(afterOk.refreshToken, 'ref_rotated_ok');
    expect(afterOk.accessToken, rotatedJwt);
    expect(afterOk.lastRefreshTestSucceeded, isTrue);

    // Subsequent failing testRefresh while access_token is still valid must NOT mark reauthRequired
    rejectNextRefresh = true;
    final testFail = await service.testRefresh();
    expect(testFail.readiness, CareLinkRefreshReadiness.failed);
    expect(testFail.preservedActiveSession, isTrue);
    expect(testFail.detailPt.contains('ref_rotated_ok'), isFalse);

    final afterFail = await service.loadStoredTokenBundle();
    expect(afterFail!.reauthRequired, isFalse);
    expect(afterFail.accessToken, rotatedJwt);
  });
}
