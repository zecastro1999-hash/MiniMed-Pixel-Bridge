import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/pump_telemetry.dart';
import 'credential_store.dart';

enum CareLinkSessionStatus {
  connected('CareLink ligada'),
  refreshing('A renovar sessão'),
  offline('Sem ligação'),
  reauthRequired('Necessária nova autenticação'),
  xdrip('xDrip+ local'),
  unconfigured('Não configurado');

  final String labelPt;
  const CareLinkSessionStatus(this.labelPt);
}

enum CareLinkAuthErrorKind {
  invalidFormat,
  reauthRequired,
  networkError,
  serverError,
  missingUsername,
}

class CareLinkAuthException implements Exception {
  final CareLinkAuthErrorKind kind;
  final String message;
  final int? statusCode;

  CareLinkAuthException(this.kind, this.message, {this.statusCode});

  @override
  String toString() => message;
}

class CareLinkEndpointConfig {
  final String region;
  final String baseUrlCareLink;
  final String baseUrlCumulus;
  final String tokenUrl;
  final String ssoConfigKey;
  final bool isAuth0;
  final String? ssoClientId;
  final String? ssoScope;

  const CareLinkEndpointConfig({
    required this.region,
    required this.baseUrlCareLink,
    required this.baseUrlCumulus,
    required this.tokenUrl,
    this.ssoConfigKey = 'Auth0SSOConfiguration',
    this.isAuth0 = true,
    this.ssoClientId,
    this.ssoScope,
  });
}

enum CareLinkRefreshReadiness {
  verified('Ativa e verificada'),
  readyToTest('Parâmetros presentes (não testada)'),
  incomplete('Indisponível (campos em falta)'),
  failed('Falha na verificação / Reautenticação'),
  unconfigured('Não configurada');

  final String labelPt;
  const CareLinkRefreshReadiness(this.labelPt);
}

class CareLinkRefreshDiagnostics {
  final CareLinkRefreshReadiness readiness;
  final bool isAuth0Flow;
  final List<String> presentFields;
  final List<String> missingFields;
  final String? clientIdSource;
  final String? tokenUrl;
  final DateTime? lastVerifiedAt;
  final String summaryPt;
  final String detailPt;
  final bool preservedActiveSession;

  const CareLinkRefreshDiagnostics({
    required this.readiness,
    required this.isAuth0Flow,
    this.presentFields = const [],
    this.missingFields = const [],
    this.clientIdSource,
    this.tokenUrl,
    this.lastVerifiedAt,
    required this.summaryPt,
    required this.detailPt,
    this.preservedActiveSession = false,
  });

  bool get isVerified => readiness == CareLinkRefreshReadiness.verified;
}

class CareLinkTokenBundle {
  final String accessToken;
  final String? refreshToken;
  final String? clientId;
  final String? clientSecret;
  final String? magIdentifier;
  final String? scope;
  final String? username;
  final String? country;
  final DateTime? expiresAt;
  final DateTime? lastRefreshedAt;
  final DateTime? lastRefreshVerifiedAt;
  final bool? lastRefreshTestSucceeded;
  final String? lastRefreshTestMessage;
  final bool reauthRequired;

  const CareLinkTokenBundle({
    required this.accessToken,
    this.refreshToken,
    this.clientId,
    this.clientSecret,
    this.magIdentifier,
    this.scope,
    this.username,
    this.country,
    this.expiresAt,
    this.lastRefreshedAt,
    this.lastRefreshVerifiedAt,
    this.lastRefreshTestSucceeded,
    this.lastRefreshTestMessage,
    this.reauthRequired = false,
  });

  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !now.isBefore(expiresAt!);

  bool get isExpired => isExpiredAt(DateTime.now());

  /// Proactive 10-minute (600s) renewal buffer matching `carelink-python-client`.
  bool needsProactiveRefreshAt(
    DateTime now, {
    Duration buffer = const Duration(seconds: 600),
  }) {
    if (expiresAt == null) return false;
    return !now.add(buffer).isBefore(expiresAt!);
  }

  bool get needsProactiveRefresh => needsProactiveRefreshAt(DateTime.now());

  bool get hasRefreshToken =>
      refreshToken != null && refreshToken!.trim().isNotEmpty;

  bool get hasMagCredentials =>
      (magIdentifier != null && magIdentifier!.trim().isNotEmpty) ||
      (clientSecret != null && clientSecret!.trim().isNotEmpty);

  /// True when minimum stored credentials exist to perform `_do_refresh()`
  /// without needing extra parameters. Note: Auth0 flows can also supply a
  /// public `client_id` dynamically via SSO discovery when omitted from JSON.
  bool get canRefresh {
    if (!hasRefreshToken) return false;
    if (hasMagCredentials) {
      return clientId != null &&
          clientId!.trim().isNotEmpty &&
          clientSecret != null &&
          clientSecret!.trim().isNotEmpty &&
          magIdentifier != null &&
          magIdentifier!.trim().isNotEmpty;
    }
    return clientId != null && clientId!.trim().isNotEmpty;
  }

  CareLinkTokenBundle copyWith({
    String? accessToken,
    String? refreshToken,
    String? clientId,
    String? clientSecret,
    String? magIdentifier,
    String? scope,
    String? username,
    String? country,
    DateTime? expiresAt,
    DateTime? lastRefreshedAt,
    DateTime? lastRefreshVerifiedAt,
    bool clearLastRefreshVerifiedAt = false,
    bool? lastRefreshTestSucceeded,
    bool clearLastRefreshTestSucceeded = false,
    String? lastRefreshTestMessage,
    bool clearLastRefreshTestMessage = false,
    bool? reauthRequired,
  }) {
    return CareLinkTokenBundle(
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      clientId: clientId ?? this.clientId,
      clientSecret: clientSecret ?? this.clientSecret,
      magIdentifier: magIdentifier ?? this.magIdentifier,
      scope: scope ?? this.scope,
      username: username ?? this.username,
      country: country ?? this.country,
      expiresAt: expiresAt ?? this.expiresAt,
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
      lastRefreshVerifiedAt: clearLastRefreshVerifiedAt
          ? null
          : (lastRefreshVerifiedAt ?? this.lastRefreshVerifiedAt),
      lastRefreshTestSucceeded: clearLastRefreshTestSucceeded
          ? null
          : (lastRefreshTestSucceeded ?? this.lastRefreshTestSucceeded),
      lastRefreshTestMessage: clearLastRefreshTestMessage
          ? null
          : (lastRefreshTestMessage ?? this.lastRefreshTestMessage),
      reauthRequired: reauthRequired ?? this.reauthRequired,
    );
  }

  Map<String, dynamic> toJson() => {
        'access_token': accessToken,
        if (refreshToken != null && refreshToken!.isNotEmpty)
          'refresh_token': refreshToken,
        if (clientId != null && clientId!.isNotEmpty) 'client_id': clientId,
        if (clientSecret != null && clientSecret!.isNotEmpty)
          'client_secret': clientSecret,
        if (magIdentifier != null && magIdentifier!.isNotEmpty)
          'mag-identifier': magIdentifier,
        if (scope != null && scope!.isNotEmpty) 'scope': scope,
        if (username != null && username!.isNotEmpty) 'username': username,
        if (country != null && country!.isNotEmpty) 'country': country,
        if (expiresAt != null)
          'expires_at_ms': expiresAt!.toUtc().millisecondsSinceEpoch,
        if (lastRefreshedAt != null)
          'last_refreshed_ms': lastRefreshedAt!.toUtc().millisecondsSinceEpoch,
        if (lastRefreshVerifiedAt != null)
          'last_refresh_verified_ms':
              lastRefreshVerifiedAt!.toUtc().millisecondsSinceEpoch,
        if (lastRefreshTestSucceeded != null)
          'last_refresh_test_ok': lastRefreshTestSucceeded,
        if (lastRefreshTestMessage != null &&
            lastRefreshTestMessage!.isNotEmpty)
          'last_refresh_test_message': lastRefreshTestMessage,
        'reauth_required': reauthRequired,
      };

  factory CareLinkTokenBundle.fromJson(Map<String, dynamic> json) {
    final rawAccess = json['access_token']?.toString() ?? '';
    final jwtClaims = CareLinkService.decodeJwtClaims(rawAccess);

    final expMs = (json['expires_at_ms'] as num?)?.toInt();
    final expiresAt = expMs != null
        ? DateTime.fromMillisecondsSinceEpoch(expMs, isUtc: true)
        : jwtClaims.expiresAt;

    final lastRefMs = (json['last_refreshed_ms'] as num?)?.toInt();
    final lastVerifiedMs = (json['last_refresh_verified_ms'] as num?)?.toInt();

    return CareLinkTokenBundle(
      accessToken: rawAccess,
      refreshToken: _nonEmptyOrNull(json['refresh_token']),
      clientId: _nonEmptyOrNull(json['client_id']),
      clientSecret: _nonEmptyOrNull(json['client_secret']),
      magIdentifier: _nonEmptyOrNull(json['mag-identifier'] ??
          json['mag_identifier'] ??
          json['magIdentifier']),
      scope: _nonEmptyOrNull(json['scope']),
      username: _nonEmptyOrNull(json['username']) ?? jwtClaims.username,
      country: _nonEmptyOrNull(json['country']) ?? jwtClaims.country,
      expiresAt: expiresAt,
      lastRefreshedAt: lastRefMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastRefMs, isUtc: true)
          : null,
      lastRefreshVerifiedAt: lastVerifiedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastVerifiedMs, isUtc: true)
          : null,
      lastRefreshTestSucceeded: json['last_refresh_test_ok'] is bool
          ? json['last_refresh_test_ok'] as bool
          : null,
      lastRefreshTestMessage: _nonEmptyOrNull(json['last_refresh_test_message']),
      reauthRequired: json['reauth_required'] == true,
    );
  }

  static String? _nonEmptyOrNull(Object? value) {
    if (value == null) return null;
    final str = value.toString().trim();
    return str.isEmpty ? null : str;
  }
}

class JwtClaims {
  final String? username;
  final String? country;
  final DateTime? expiresAt;

  const JwtClaims({this.username, this.country, this.expiresAt});
}

class CareLinkService {
  static const String careLinkConfigUrl =
      'https://clcloud.minimed.eu/connect/carepartner/v13/discover/android/3.6';
  static const String careLinkEuV13Url =
      'https://clcloud.minimed.eu/connect/carepartner/v13/display/message';
  static const String careLinkEuV11Url =
      'https://clcloud.minimed.eu/connect/carepartner/v11/display/message';
  static const String careLinkEuUrl =
      'https://clcloud.minimed.eu/connect/carepartner/v6/display/message';
  static const String defaultXdripUrl = 'http://127.0.0.1:17580/sgv.json';

  static const String secureKeyTokenBundle = 'carelink_secure_token_bundle_v2';
  static const String prefKeyUsername = 'carelink_username';
  static const String prefKeyPatientId = 'carelink_patient_id';
  static const String prefKeyLegacyAuthToken = 'carelink_auth_token';
  static const String prefKeyUseXdrip = 'use_xdrip_local';
  static const String prefKeyXdripUrl = 'xdrip_local_url';
  static const String prefKeyCachedTelemetry = 'cached_pump_telemetry_json';
  static const String prefKeyCachedRole = 'carelink_cached_role';
  static const String prefKeyLastSessionStatus = 'carelink_session_status';
  static const String prefKeyLastRefreshIso = 'carelink_last_refresh_iso';
  static const String prefKeyLastError = 'carelink_last_sanitized_error';

  static const Duration proactiveRefreshBuffer = Duration(seconds: 600);

  /// Shared single-flight refresh futures keyed by credential store identity so
  /// concurrent callers within the isolate share a single OAuth2 token exchange.
  static final Map<int, Future<CareLinkTokenBundle>> _inFlightRefreshes = {};

  final http.Client _httpClient;
  final CredentialStore _credentialStore;
  final DateTime Function() _nowProvider;
  final Future<SharedPreferences?> Function() _prefsProvider;
  final void Function(CareLinkSessionStatus status)? onStatusChanged;

  CareLinkEndpointConfig? _cachedEndpointConfig;
  DateTime? _endpointCachedAt;

  CareLinkService({
    http.Client? httpClient,
    CredentialStore? credentialStore,
    DateTime Function()? nowProvider,
    Future<SharedPreferences?> Function()? prefsProvider,
    this.onStatusChanged,
  })  : _httpClient = httpClient ?? http.Client(),
        _credentialStore = credentialStore ?? SecureCredentialStore(),
        _nowProvider = nowProvider ?? DateTime.now,
        _prefsProvider = prefsProvider ?? _defaultPrefs;

  static Future<SharedPreferences?> _defaultPrefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// Decodes JWT claims safely without logging sensitive token material.
  static JwtClaims decodeJwtClaims(String token) {
    final clean = token.startsWith('Bearer ') ? token.substring(7).trim() : token;
    final parts = clean.split('.');
    if (parts.length < 2) return const JwtClaims();
    try {
      var payloadB64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (payloadB64.length % 4 != 0) {
        payloadB64 += '=';
      }
      final decodedJson = utf8.decode(base64Decode(payloadB64));
      final payload =
          Map<String, dynamic>.from(jsonDecode(decodedJson) as Map);
      final tokenDetails = payload['token_details'] is Map
          ? Map<String, dynamic>.from(payload['token_details'] as Map)
          : null;
      final username = (tokenDetails?['preferred_username'] ??
              payload['preferred_username'])
          ?.toString()
          .trim();
      final country = tokenDetails?['country']?.toString().trim();
      final exp = (payload['exp'] as num?)?.toInt();
      final expiresAt = exp != null
          ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true)
          : null;
      return JwtClaims(
        username: (username != null && username.isNotEmpty) ? username : null,
        country: (country != null && country.isNotEmpty) ? country : null,
        expiresAt: expiresAt,
      );
    } catch (_) {
      return const JwtClaims();
    }
  }

  /// Parses `logindata.json` (exported by `carelink-python-client`) or a raw
  /// Bearer token into [CareLinkTokenBundle], preserving `refresh_token`,
  /// `client_id`, `client_secret` (when provided in the file), `scope`, and
  /// `mag-identifier`.
  static CareLinkTokenBundle? parseLoginDataOrToken(
    String rawInput, {
    DateTime? now,
  }) {
    var trimmed = rawInput.replaceFirst('\uFEFF', '').trim();
    if (trimmed.isEmpty) return null;

    String accessToken = trimmed;
    String? refreshToken;
    String? clientId;
    String? clientSecret;
    String? magIdentifier;
    String? scope;
    String? username;
    String? country;
    DateTime? expiresAt;

    if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
      try {
        final decodedRoot = Map<String, dynamic>.from(jsonDecode(trimmed) as Map);
        var obj = decodedRoot;
        // Support wrapped exports (e.g. {"token_data": {...}}) gracefully.
        for (final nestedKey in const ['token_data', 'tokens', 'auth', 'credentials']) {
          final nested = decodedRoot[nestedKey];
          if (obj['access_token'] == null &&
              obj['accessToken'] == null &&
              nested is Map) {
            obj = Map<String, dynamic>.from(nested);
            break;
          }
        }

        accessToken = (obj['access_token'] ?? obj['accessToken'])?.toString().trim() ?? '';
        refreshToken = CareLinkTokenBundle._nonEmptyOrNull(
          obj['refresh_token'] ?? obj['refreshToken'],
        );
        clientId = CareLinkTokenBundle._nonEmptyOrNull(
          obj['client_id'] ?? obj['clientId'],
        );
        clientSecret = CareLinkTokenBundle._nonEmptyOrNull(
          obj['client_secret'] ?? obj['clientSecret'],
        );
        magIdentifier = CareLinkTokenBundle._nonEmptyOrNull(
          obj['mag-identifier'] ??
              obj['mag_identifier'] ??
              obj['magIdentifier'],
        );
        scope = CareLinkTokenBundle._nonEmptyOrNull(obj['scope']);
        username = CareLinkTokenBundle._nonEmptyOrNull(
          obj['username'] ?? obj['preferred_username'],
        );
        country = CareLinkTokenBundle._nonEmptyOrNull(obj['country']);

        final expMs = (obj['expires_at_ms'] as num?)?.toInt();
        final expIn = (obj['expires_in'] as num?)?.toInt();
        final expIso = obj['expires_at']?.toString();
        if (expMs != null) {
          expiresAt = DateTime.fromMillisecondsSinceEpoch(expMs, isUtc: true);
        } else if (expIso != null && expIso.trim().isNotEmpty) {
          expiresAt = DateTime.tryParse(expIso.trim())?.toUtc();
        } else if (expIn != null && expIn > 0) {
          expiresAt = (now ?? DateTime.now()).toUtc().add(
                Duration(seconds: expIn),
              );
        }
      } catch (_) {
        return null;
      }
    }

    if (accessToken.startsWith('Bearer ')) {
      accessToken = accessToken.substring(7).trim();
    }
    if (accessToken.isEmpty) return null;

    final claims = decodeJwtClaims(accessToken);
    return CareLinkTokenBundle(
      accessToken: accessToken,
      refreshToken: refreshToken,
      clientId: clientId,
      clientSecret: clientSecret,
      magIdentifier: magIdentifier,
      scope: scope,
      username: username ?? claims.username,
      country: country ?? claims.country,
      expiresAt: claims.expiresAt ?? expiresAt,
      reauthRequired: false,
    );
  }

  /// Inspects stored or imported credentials WITHOUT leaking any token values,
  /// naming exact missing parameters and distinguishing untested credentials
  /// from an actually verified OAuth2 refresh flow.
  static CareLinkRefreshDiagnostics inspectBundleRefresh(
    CareLinkTokenBundle? bundle, {
    CareLinkEndpointConfig? endpoints,
  }) {
    if (bundle == null || bundle.accessToken.trim().isEmpty) {
      return const CareLinkRefreshDiagnostics(
        readiness: CareLinkRefreshReadiness.unconfigured,
        isAuth0Flow: true,
        summaryPt: 'CareLink não configurada',
        detailPt: 'Importa o ficheiro logindata.json para configurar a ligação.',
      );
    }

    final isAuth0 = endpoints != null
        ? endpoints.isAuth0
        : !bundle.hasMagCredentials;

    final present = <String>['access_token'];
    final missing = <String>[];

    if (bundle.hasRefreshToken) {
      present.add('refresh_token');
    } else {
      missing.add('refresh_token');
    }

    String? clientIdSource;
    if (bundle.clientId != null && bundle.clientId!.trim().isNotEmpty) {
      present.add('client_id');
      clientIdSource = 'logindata.json';
    } else if (isAuth0 &&
        endpoints?.ssoClientId != null &&
        endpoints!.ssoClientId!.trim().isNotEmpty) {
      present.add('client_id (SSO Auth0)');
      clientIdSource = 'Descoberta SSO Auth0';
    } else {
      missing.add('client_id');
    }

    if (isAuth0) {
      if (bundle.scope != null && bundle.scope!.trim().isNotEmpty) {
        present.add('scope');
      }
    } else {
      if (bundle.clientSecret != null &&
          bundle.clientSecret!.trim().isNotEmpty) {
        present.add('client_secret');
      } else {
        missing.add('client_secret');
      }
      if (bundle.magIdentifier != null &&
          bundle.magIdentifier!.trim().isNotEmpty) {
        present.add('mag-identifier');
      } else {
        missing.add('mag-identifier');
      }
      if (bundle.scope != null && bundle.scope!.trim().isNotEmpty) {
        present.add('scope');
      }
    }

    if (bundle.reauthRequired) {
      return CareLinkRefreshDiagnostics(
        readiness: CareLinkRefreshReadiness.failed,
        isAuth0Flow: isAuth0,
        presentFields: present,
        missingFields: missing,
        clientIdSource: clientIdSource,
        tokenUrl: endpoints?.tokenUrl,
        lastVerifiedAt: bundle.lastRefreshVerifiedAt,
        summaryPt: 'Necessária nova autenticação',
        detailPt: bundle.lastRefreshTestMessage ??
            'A sessão foi rejeitada ou expirou sem renovação.',
      );
    }

    if (missing.isNotEmpty) {
      final onlyMissingClientIdOffline = missing.length == 1 &&
          missing.first == 'client_id' &&
          isAuth0 &&
          endpoints == null;
      return CareLinkRefreshDiagnostics(
        readiness: CareLinkRefreshReadiness.incomplete,
        isAuth0Flow: isAuth0,
        presentFields: present,
        missingFields: missing,
        clientIdSource: clientIdSource,
        tokenUrl: endpoints?.tokenUrl,
        lastVerifiedAt: bundle.lastRefreshVerifiedAt,
        summaryPt: 'Indisponível (em falta: ${missing.join(", ")})',
        detailPt: onlyMissingClientIdOffline
            ? 'Falta client_id guardado; toca em "Testar renovação" para tentar obtê-lo via descoberta SSO Auth0 e validar o refresh_token.'
            : 'Campos ausentes nas credenciais guardadas: ${missing.join(", ")}. Importa um logindata.json completo gerado por carelink_carepartner_api_login.py.',
      );
    }

    if (bundle.lastRefreshTestSucceeded == false) {
      return CareLinkRefreshDiagnostics(
        readiness: CareLinkRefreshReadiness.failed,
        isAuth0Flow: isAuth0,
        presentFields: present,
        missingFields: missing,
        clientIdSource: clientIdSource,
        tokenUrl: endpoints?.tokenUrl,
        lastVerifiedAt: bundle.lastRefreshVerifiedAt,
        summaryPt: 'Falha ao testar renovação',
        detailPt: bundle.lastRefreshTestMessage ??
            'O servidor OAuth recusou a renovação no último teste.',
        preservedActiveSession: !bundle.isExpired,
      );
    }

    if (bundle.lastRefreshTestSucceeded == true &&
        bundle.lastRefreshVerifiedAt != null) {
      return CareLinkRefreshDiagnostics(
        readiness: CareLinkRefreshReadiness.verified,
        isAuth0Flow: isAuth0,
        presentFields: present,
        missingFields: missing,
        clientIdSource: clientIdSource,
        tokenUrl: endpoints?.tokenUrl,
        lastVerifiedAt: bundle.lastRefreshVerifiedAt,
        summaryPt: 'Verificada com sucesso',
        detailPt: bundle.lastRefreshTestMessage ??
            'Renovação OAuth2 confirmada com o servidor CareLink.',
      );
    }

    return CareLinkRefreshDiagnostics(
      readiness: CareLinkRefreshReadiness.readyToTest,
      isAuth0Flow: isAuth0,
      presentFields: present,
      missingFields: missing,
      clientIdSource: clientIdSource,
      tokenUrl: endpoints?.tokenUrl,
      summaryPt: 'Parâmetros presentes (não testada)',
      detailPt:
          'Os parâmetros OAuth existem, mas a renovação automática ainda não foi confirmada. Toca em "Testar renovação".',
    );
  }

  /// Redacts tokens and credentials before printing or storing diagnostic text.
  static String sanitizeErrorText(String raw) {
    var clean = raw
        .replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false), 'Bearer [REDACTED]')
        .replaceAll(RegExp(r'(access_token|refresh_token|client_secret|mag-identifier)["\s:=]+[^"\s,}]+', caseSensitive: false), r'$1=[REDACTED]')
        .replaceAll(RegExp(r'eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]*'), '[JWT_REDACTED]');
    if (clean.length > 220) {
      clean = '${clean.substring(0, 220)}...';
    }
    return clean;
  }

  void _requireHttps(Uri uri, {bool allowLoopbackHttp = false}) {
    if (uri.scheme == 'https') return;
    if (allowLoopbackHttp &&
        uri.scheme == 'http' &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost')) {
      return;
    }
    throw CareLinkAuthException(
      CareLinkAuthErrorKind.invalidFormat,
      'Ligação recusada: apenas HTTPS permitido para endpoints CareLink.',
    );
  }

  /// Loads stored CareLink credentials from encrypted storage, performing a
  /// one-time migration if legacy unencrypted SharedPreferences still hold them.
  Future<CareLinkTokenBundle?> loadStoredTokenBundle() async {
    final encryptedRaw = await _credentialStore.read(secureKeyTokenBundle);
    if (encryptedRaw != null && encryptedRaw.trim().isNotEmpty) {
      try {
        final json =
            Map<String, dynamic>.from(jsonDecode(encryptedRaw) as Map);
        final bundle = CareLinkTokenBundle.fromJson(json);
        if (bundle.accessToken.isNotEmpty) {
          return bundle;
        }
      } catch (_) {}
    }

    // Legacy migration from SharedPreferences -> encrypted storage
    final prefs = await _prefsProvider();
    final legacyRaw = prefs?.getString(prefKeyLegacyAuthToken)?.trim();
    if (legacyRaw != null && legacyRaw.isNotEmpty) {
      final migrated = parseLoginDataOrToken(legacyRaw, now: _nowProvider());
      if (migrated != null) {
        await saveTokenBundle(migrated);
      }
      await prefs?.remove(prefKeyLegacyAuthToken);
      return migrated;
    }

    return null;
  }

  Future<void> saveTokenBundle(CareLinkTokenBundle bundle) async {
    await _credentialStore.write(
      secureKeyTokenBundle,
      jsonEncode(bundle.toJson()),
    );
    final prefs = await _prefsProvider();
    if (prefs != null) {
      await prefs.remove(prefKeyLegacyAuthToken);
      if (bundle.username != null && bundle.username!.isNotEmpty) {
        final existingUser = prefs.getString(prefKeyUsername)?.trim() ?? '';
        if (existingUser.isEmpty) {
          await prefs.setString(prefKeyUsername, bundle.username!);
        }
      }
      if (bundle.reauthRequired) {
        await _persistSessionMeta(
          CareLinkSessionStatus.reauthRequired,
          error: 'Necessária nova autenticação na CareLink.',
        );
      } else if (!bundle.isExpired) {
        await _persistSessionMeta(CareLinkSessionStatus.connected, clearError: true);
      }
    }
  }

  Future<CareLinkTokenBundle> saveRawLoginData(
    String rawInput, {
    String? usernameOverride,
  }) async {
    final bundle = parseLoginDataOrToken(rawInput, now: _nowProvider());
    if (bundle == null) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.invalidFormat,
        'Formato inválido para logindata.json ou token OAuth.',
      );
    }
    final updated = (usernameOverride != null &&
            usernameOverride.trim().isNotEmpty)
        ? bundle.copyWith(
            username: usernameOverride.trim(),
            reauthRequired: false,
            clearLastRefreshVerifiedAt: true,
            clearLastRefreshTestSucceeded: true,
            clearLastRefreshTestMessage: true,
          )
        : bundle.copyWith(
            reauthRequired: false,
            clearLastRefreshVerifiedAt: true,
            clearLastRefreshTestSucceeded: true,
            clearLastRefreshTestMessage: true,
          );
    await saveTokenBundle(updated);
    return updated;
  }

  Future<void> clearCredentials() async {
    await _credentialStore.delete(secureKeyTokenBundle);
    _cachedEndpointConfig = null;
    _endpointCachedAt = null;
    final prefs = await _prefsProvider();
    if (prefs != null) {
      await prefs.remove(prefKeyLegacyAuthToken);
      await prefs.remove(prefKeyCachedRole);
      await _persistSessionMeta(CareLinkSessionStatus.unconfigured, clearError: true);
    }
  }

  Future<void> _persistSessionMeta(
    CareLinkSessionStatus status, {
    String? error,
    bool clearError = false,
  }) async {
    onStatusChanged?.call(status);
    final prefs = await _prefsProvider();
    if (prefs == null) return;
    await prefs.setString(prefKeyLastSessionStatus, status.name);
    if (status == CareLinkSessionStatus.connected) {
      await prefs.setString(
        prefKeyLastRefreshIso,
        _nowProvider().toUtc().toIso8601String(),
      );
    }
    if (clearError) {
      await prefs.remove(prefKeyLastError);
    } else if (error != null) {
      await prefs.setString(prefKeyLastError, sanitizeErrorText(error));
    }
  }

  Future<CareLinkSessionStatus> getSessionStatus() async {
    final prefs = await _prefsProvider();
    if (prefs?.getBool(prefKeyUseXdrip) == true) {
      return CareLinkSessionStatus.xdrip;
    }

    final bundle = await loadStoredTokenBundle();
    if (bundle == null) {
      return CareLinkSessionStatus.unconfigured;
    }
    if (bundle.reauthRequired) {
      return CareLinkSessionStatus.reauthRequired;
    }
    if (bundle.isExpired && !bundle.hasRefreshToken) {
      return CareLinkSessionStatus.reauthRequired;
    }

    final lastStr = prefs?.getString(prefKeyLastSessionStatus);
    for (final s in CareLinkSessionStatus.values) {
      if (s.name == lastStr) return s;
    }
    return CareLinkSessionStatus.connected;
  }

  /// Evaluates currently stored CareLink credentials for UI diagnostics without
  /// issuing network refresh calls or exposing raw secrets.
  Future<CareLinkRefreshDiagnostics> inspectStoredRefresh() async {
    final bundle = await loadStoredTokenBundle();
    return inspectBundleRefresh(bundle, endpoints: _cachedEndpointConfig);
  }

  /// Safely verifies the CareLink OAuth2 refresh flow end-to-end:
  /// 1. Discovers endpoints and `token_url` from CareLink discovery/SSO config.
  /// 2. Checks whether required OAuth2 fields exist (and resolves Auth0 public
  ///    `client_id` via SSO discovery if omitted in an Auth0 `logindata.json`).
  /// 3. Executes a single-flight POST to `token_url`, immediately persisting rotated
  ///    tokens so a working session is never invalidated unnecessarily.
  Future<CareLinkRefreshDiagnostics> testRefresh() async {
    final bundle = await loadStoredTokenBundle();
    if (bundle == null) {
      return inspectBundleRefresh(null);
    }

    CareLinkEndpointConfig endpoints;
    try {
      endpoints = await discoverEndpoints(
        country: bundle.country,
        forceRefresh: true,
      );
    } catch (e) {
      final safeErr = sanitizeErrorText(e.toString());
      return CareLinkRefreshDiagnostics(
        readiness: CareLinkRefreshReadiness.failed,
        isAuth0Flow: !bundle.hasMagCredentials,
        presentFields: inspectBundleRefresh(bundle).presentFields,
        missingFields: inspectBundleRefresh(bundle).missingFields,
        lastVerifiedAt: bundle.lastRefreshVerifiedAt,
        summaryPt: 'Não foi possível contactar a CareLink SSO',
        detailPt: safeErr,
        preservedActiveSession: !bundle.isExpiredAt(_nowProvider()),
      );
    }

    final preflight = inspectBundleRefresh(bundle, endpoints: endpoints);
    if (preflight.missingFields.isNotEmpty) {
      final msg =
          'Campos em falta para renovação: ${preflight.missingFields.join(", ")}.';
      final updated = bundle.copyWith(
        lastRefreshTestSucceeded: false,
        lastRefreshTestMessage: msg,
        clearLastRefreshVerifiedAt: true,
      );
      await saveTokenBundle(updated);
      return inspectBundleRefresh(updated, endpoints: endpoints);
    }

    try {
      final refreshed = await _refreshTokenSynchronized(
        expectedOldAccessToken: bundle.accessToken,
        force: true,
        preserveActiveSessionOnRefreshError: true,
        forceDiscovery: true,
      );
      return inspectBundleRefresh(refreshed, endpoints: endpoints);
    } catch (e) {
      final latestAfter = await loadStoredTokenBundle() ?? bundle;
      final diag = inspectBundleRefresh(latestAfter, endpoints: endpoints);
      return CareLinkRefreshDiagnostics(
        readiness: CareLinkRefreshReadiness.failed,
        isAuth0Flow: diag.isAuth0Flow,
        presentFields: diag.presentFields,
        missingFields: diag.missingFields,
        clientIdSource: diag.clientIdSource,
        tokenUrl: endpoints.tokenUrl,
        lastVerifiedAt: latestAfter.lastRefreshVerifiedAt,
        summaryPt: diag.summaryPt,
        detailPt: sanitizeErrorText(e.toString()),
        preservedActiveSession: !latestAfter.isExpiredAt(_nowProvider()) &&
            !latestAfter.reauthRequired,
      );
    }
  }

  Future<String?> getLastSessionError() async {
    final prefs = await _prefsProvider();
    return prefs?.getString(prefKeyLastError);
  }

  /// Resolves CareLink discovery & SSO `token_url` following
  /// `carelink_client2.py`'s `_get_config` and `carelink_carepartner_api_login.py`.
  Future<CareLinkEndpointConfig> discoverEndpoints({
    String? country,
    bool forceRefresh = false,
  }) async {
    final now = _nowProvider();
    if (!forceRefresh &&
        _cachedEndpointConfig != null &&
        _endpointCachedAt != null &&
        now.difference(_endpointCachedAt!) < const Duration(hours: 6)) {
      return _cachedEndpointConfig!;
    }

    final discoverUri = Uri.parse(careLinkConfigUrl);
    _requireHttps(discoverUri);

    http.Response cfgResp;
    try {
      cfgResp = await _httpClient
          .get(discoverUri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.networkError,
        'Sem ligação ao servidor de configuração CareLink.',
      );
    }

    if (cfgResp.statusCode != 200) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.serverError,
        'Erro ao obter configuração CareLink (HTTP ${cfgResp.statusCode}).',
        statusCode: cfgResp.statusCode,
      );
    }

    final cfgJson = Map<String, dynamic>.from(jsonDecode(cfgResp.body) as Map);
    String region = 'EU';
    final upperCountry = country?.trim().toUpperCase();
    if (upperCountry != null && upperCountry.isNotEmpty) {
      for (final item in (cfgJson['supportedCountries'] as List? ?? [])) {
        if (item is Map && item.containsKey(upperCountry)) {
          final entry =
              Map<String, dynamic>.from(item[upperCountry] as Map);
          final foundRegion = entry['region']?.toString().trim();
          if (foundRegion != null && foundRegion.isNotEmpty) {
            region = foundRegion;
          }
          break;
        }
      }
    }

    Map<String, dynamic>? cpEntry;
    for (final item in (cfgJson['CP'] as List? ?? [])) {
      if (item is Map &&
          item['region']?.toString().toUpperCase() == region.toUpperCase()) {
        cpEntry = Map<String, dynamic>.from(item);
        break;
      }
    }
    if (cpEntry == null) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.serverError,
        'Região CareLink "$region" não encontrada na configuração.',
      );
    }

    final baseCareLink = cpEntry['baseUrlCareLink']?.toString() ??
        'https://carelink.minimed.eu/api/carepartner/v2';
    final baseCumulus = cpEntry['baseUrlCumulus']?.toString() ??
        'https://clcloud.minimed.eu/connect/carepartner/v13';
    final ssoKey = cpEntry['UseSSOConfiguration']?.toString() ??
        'Auth0SSOConfiguration';
    final ssoUrl = (cpEntry[ssoKey] ??
            cpEntry['Auth0SSOConfiguration'] ??
            cpEntry['SSOConfiguration'])
        ?.toString();

    if (ssoUrl == null || ssoUrl.isEmpty) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.serverError,
        'URL de configuração SSO em falta na resposta CareLink.',
      );
    }

    final ssoUri = Uri.parse(ssoUrl);
    _requireHttps(ssoUri);

    http.Response ssoResp;
    try {
      ssoResp = await _httpClient
          .get(ssoUri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.networkError,
        'Sem ligação ao servidor SSO da CareLink.',
      );
    }

    if (ssoResp.statusCode != 200) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.serverError,
        'Erro ao obter configuração SSO CareLink (HTTP ${ssoResp.statusCode}).',
        statusCode: ssoResp.statusCode,
      );
    }

    final ssoJson = Map<String, dynamic>.from(jsonDecode(ssoResp.body) as Map);
    final tokenUrl = buildTokenUrlFromSsoConfig(ssoJson);
    final clientMap = ssoJson['client'] is Map
        ? Map<String, dynamic>.from(ssoJson['client'] as Map)
        : (ssoJson['oauth'] is Map &&
                (ssoJson['oauth'] as Map)['client'] is Map)
            ? Map<String, dynamic>.from(
                (ssoJson['oauth'] as Map)['client'] as Map)
            : <String, dynamic>{};
    final ssoClientId = CareLinkTokenBundle._nonEmptyOrNull(
      clientMap['client_id'],
    );
    final ssoScope = CareLinkTokenBundle._nonEmptyOrNull(clientMap['scope']);
    final isAuth0 = ssoKey.toLowerCase().contains('auth0') ||
        (ssoJson['system_endpoints'] is Map && ssoJson['oauth'] == null);

    final resolved = CareLinkEndpointConfig(
      region: region,
      baseUrlCareLink: baseCareLink,
      baseUrlCumulus: baseCumulus,
      tokenUrl: tokenUrl,
      ssoConfigKey: ssoKey,
      isAuth0: isAuth0,
      ssoClientId: ssoClientId,
      ssoScope: ssoScope,
    );
    _cachedEndpointConfig = resolved;
    _endpointCachedAt = now;
    return resolved;
  }

  /// Constructs `token_url` from SSO config JSON matching `carelink_client2.py`:
  /// supports both Auth0 top-level `system_endpoints` and MAG `oauth.system_endpoints`.
  static String buildTokenUrlFromSsoConfig(Map<String, dynamic> ssoConfig) {
    final server = ssoConfig['server'] is Map
        ? Map<String, dynamic>.from(ssoConfig['server'] as Map)
        : <String, dynamic>{};
    final host = server['hostname']?.toString().trim() ?? '';
    final port = (server['port'] as num?)?.toInt() ?? 443;
    final rawPrefix = server['prefix']?.toString().trim() ?? '';
    final cleanPrefix = rawPrefix.replaceAll(RegExp(r'^/+|/+$'), '');

    final sysEndpoints = ssoConfig['system_endpoints'] is Map
        ? Map<String, dynamic>.from(ssoConfig['system_endpoints'] as Map)
        : (ssoConfig['oauth'] is Map &&
                (ssoConfig['oauth'] as Map)['system_endpoints'] is Map)
            ? Map<String, dynamic>.from(
                (ssoConfig['oauth'] as Map)['system_endpoints'] as Map)
            : <String, dynamic>{};

    final tokenPathRaw =
        sysEndpoints['token_endpoint_path']?.toString().trim() ??
            '/oauth/token';
    final tokenPath =
        tokenPathRaw.startsWith('/') ? tokenPathRaw : '/$tokenPathRaw';

    final portSegment = (port > 0 && port != 443) ? ':$port' : '';
    final base = cleanPrefix.isEmpty
        ? 'https://$host$portSegment'
        : 'https://$host$portSegment/$cleanPrefix';
    return '$base$tokenPath';
  }

  /// Ensures a valid non-expired token bundle is returned, refreshing
  /// automatically with a single-flight lock if within the 600s expiry buffer
  /// or when [forceRefresh] is true (e.g., after a `401`/`403` API response).
  Future<CareLinkTokenBundle> ensureValidTokenBundle({
    bool forceRefresh = false,
  }) async {
    final current = await loadStoredTokenBundle();
    if (current == null) {
      await _persistSessionMeta(CareLinkSessionStatus.unconfigured);
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.reauthRequired,
        'CareLink ainda não configurada. Importa o logindata.json.',
      );
    }

    if (current.reauthRequired) {
      await _persistSessionMeta(
        CareLinkSessionStatus.reauthRequired,
        error: 'Necessária nova autenticação na CareLink.',
      );
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.reauthRequired,
        'Necessária nova autenticação na CareLink.',
      );
    }

    final now = _nowProvider();
    final mustRefresh =
        forceRefresh || current.isExpiredAt(now) || current.needsProactiveRefreshAt(now);

    if (!mustRefresh) {
      await _persistSessionMeta(CareLinkSessionStatus.connected, clearError: true);
      return current;
    }

    if (!current.hasRefreshToken) {
      final marked = current.copyWith(
        reauthRequired: true,
        lastRefreshTestSucceeded: false,
        lastRefreshTestMessage: 'Campo ausente: refresh_token.',
      );
      await saveTokenBundle(marked);
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.reauthRequired,
        'Sessão expirada e falta refresh_token válido. Importa o logindata.json completo.',
      );
    }

    return _refreshTokenSynchronized(
      expectedOldAccessToken: current.accessToken,
      force: forceRefresh,
    );
  }

  Future<CareLinkTokenBundle> _refreshTokenSynchronized({
    required String expectedOldAccessToken,
    required bool force,
    bool preserveActiveSessionOnRefreshError = false,
    bool forceDiscovery = false,
  }) async {
    final lockKey = identityHashCode(_credentialStore);
    final existingFuture = _inFlightRefreshes[lockKey];
    if (existingFuture != null) {
      return await existingFuture;
    }

    final completer = Completer<CareLinkTokenBundle>();
    _inFlightRefreshes[lockKey] = completer.future;

    unawaited(() async {
      try {
        final result = await _performRefreshInternal(
          expectedOldAccessToken: expectedOldAccessToken,
          force: force,
          preserveActiveSessionOnRefreshError:
              preserveActiveSessionOnRefreshError,
          forceDiscovery: forceDiscovery,
        );
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _inFlightRefreshes.remove(lockKey);
      }
    }());

    return await completer.future;
  }

  Future<CareLinkTokenBundle> _performRefreshInternal({
    required String expectedOldAccessToken,
    required bool force,
    bool preserveActiveSessionOnRefreshError = false,
    bool forceDiscovery = false,
  }) async {
    // Re-read storage after acquiring single-flight lock: another isolate or
    // caller might have just finished refreshing the token.
    final latest = await loadStoredTokenBundle();
    if (latest == null) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.reauthRequired,
        'Sessão CareLink não encontrada.',
      );
    }
    if (latest.reauthRequired) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.reauthRequired,
        'Necessária nova autenticação na CareLink.',
      );
    }

    final now = _nowProvider();
    if (!force &&
        latest.accessToken != expectedOldAccessToken &&
        !latest.needsProactiveRefreshAt(now)) {
      await _persistSessionMeta(CareLinkSessionStatus.connected, clearError: true);
      return latest;
    }

    final keepActiveSession =
        preserveActiveSessionOnRefreshError && !latest.isExpiredAt(now);

    if (!keepActiveSession) {
      await _persistSessionMeta(CareLinkSessionStatus.refreshing);
    }

    CareLinkEndpointConfig endpoints;
    try {
      endpoints = await discoverEndpoints(
        country: latest.country,
        forceRefresh: forceDiscovery,
      );
    } catch (e) {
      if (!keepActiveSession) {
        await _persistSessionMeta(
          CareLinkSessionStatus.offline,
          error: e.toString(),
        );
      }
      rethrow;
    }

    final preflight = inspectBundleRefresh(latest, endpoints: endpoints);
    final effectiveClientId =
        latest.clientId ?? (endpoints.isAuth0 ? endpoints.ssoClientId : null);

    if (preflight.missingFields.isNotEmpty ||
        !latest.hasRefreshToken ||
        effectiveClientId == null ||
        effectiveClientId.isEmpty) {
      final missingList = preflight.missingFields.isNotEmpty
          ? preflight.missingFields
          : <String>[
              if (!latest.hasRefreshToken) 'refresh_token',
              if (effectiveClientId == null || effectiveClientId.isEmpty)
                'client_id',
            ];
      final errMsg =
          'Parâmetros OAuth ausentes para renovação: ${missingList.join(", ")}.';
      await saveTokenBundle(
        latest.copyWith(
          reauthRequired: !keepActiveSession,
          lastRefreshTestSucceeded: false,
          lastRefreshTestMessage: errMsg,
          clearLastRefreshVerifiedAt: true,
        ),
      );
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.reauthRequired,
        errMsg,
      );
    }

    final tokenUri = Uri.parse(endpoints.tokenUrl);
    _requireHttps(tokenUri);

    final body = <String, String>{
      'refresh_token': latest.refreshToken!,
      'client_id': effectiveClientId,
      'grant_type': 'refresh_token',
    };
    if (latest.clientSecret != null && latest.clientSecret!.isNotEmpty) {
      body['client_secret'] = latest.clientSecret!;
    }

    final headers = <String, String>{
      'Accept': 'application/json',
      'User-Agent':
          'Dalvik/2.1.0 (Linux; U; Android 15; Pixel 10a Build/AP3A.241005.015)',
      if (latest.magIdentifier != null && latest.magIdentifier!.isNotEmpty)
        'mag-identifier': latest.magIdentifier!,
    };

    http.Response resp;
    try {
      resp = await _httpClient
          .post(tokenUri, headers: headers, body: body)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      if (!keepActiveSession) {
        await _persistSessionMeta(
          CareLinkSessionStatus.offline,
          error: 'Sem ligação ao tentar renovar a sessão CareLink.',
        );
      }
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.networkError,
        'Sem ligação ao tentar renovar a sessão CareLink.',
      );
    }

    if (resp.statusCode == 200) {
      Map<String, dynamic> newJson;
      try {
        newJson = Map<String, dynamic>.from(jsonDecode(resp.body) as Map);
      } catch (_) {
        if (!keepActiveSession) {
          await _persistSessionMeta(
            CareLinkSessionStatus.offline,
            error: 'Resposta inválida ao renovar token CareLink.',
          );
        }
        throw CareLinkAuthException(
          CareLinkAuthErrorKind.serverError,
          'Resposta inválida ao renovar token CareLink.',
          statusCode: resp.statusCode,
        );
      }

      final newAccess = newJson['access_token']?.toString().trim() ?? '';
      if (newAccess.isEmpty) {
        await saveTokenBundle(
          latest.copyWith(
            reauthRequired: !keepActiveSession,
            lastRefreshTestSucceeded: false,
            lastRefreshTestMessage: 'Resposta OAuth sem novo access_token.',
            clearLastRefreshVerifiedAt: true,
          ),
        );
        throw CareLinkAuthException(
          CareLinkAuthErrorKind.reauthRequired,
          'Resposta sem novo token de acesso. Necessária nova autenticação.',
        );
      }

      // Immediately persist rotated refresh_token if returned by server,
      // otherwise retain current refresh_token cleanly.
      final returnedRefresh =
          CareLinkTokenBundle._nonEmptyOrNull(newJson['refresh_token']);
      final newRefresh = returnedRefresh ?? latest.refreshToken;
      final claims = decodeJwtClaims(newAccess);
      final expInSec = (newJson['expires_in'] as num?)?.toInt();
      final newExpiresAt = claims.expiresAt ??
          (expInSec != null && expInSec > 0
              ? _nowProvider().toUtc().add(Duration(seconds: expInSec))
              : latest.expiresAt);
      final verifiedNow = _nowProvider().toUtc();

      final updatedBundle = latest.copyWith(
        accessToken: newAccess,
        refreshToken: newRefresh,
        clientId: effectiveClientId,
        scope: CareLinkTokenBundle._nonEmptyOrNull(newJson['scope']) ??
            latest.scope,
        username: claims.username ?? latest.username,
        country: claims.country ?? latest.country,
        expiresAt: newExpiresAt,
        lastRefreshedAt: verifiedNow,
        lastRefreshVerifiedAt: verifiedNow,
        lastRefreshTestSucceeded: true,
        lastRefreshTestMessage: 'Renovação OAuth2 confirmada com sucesso.',
        reauthRequired: false,
      );

      await saveTokenBundle(updatedBundle);
      await _persistSessionMeta(
        CareLinkSessionStatus.connected,
        clearError: true,
      );
      return updatedBundle;
    }

    // Check permanent OAuth revocation / invalid grant vs transient outage
    String? oauthErrorCode;
    try {
      final errObj = jsonDecode(resp.body);
      if (errObj is Map) {
        final code = errObj['error']?.toString().trim();
        final desc = errObj['error_description']?.toString().trim();
        oauthErrorCode = sanitizeErrorText(
          [
            if (code != null && code.isNotEmpty) code,
            if (desc != null && desc.isNotEmpty) desc,
          ].join(': '),
        );
      }
    } catch (_) {}

    final lowerBody = resp.body.toLowerCase();
    final isPermanentAuthFailure = resp.statusCode == 400 ||
        resp.statusCode == 401 ||
        resp.statusCode == 403 ||
        lowerBody.contains('invalid_grant') ||
        lowerBody.contains('invalid_token') ||
        lowerBody.contains('unauthorized_client') ||
        lowerBody.contains('invalid_client');

    if (isPermanentAuthFailure) {
      final safeReason = (oauthErrorCode != null && oauthErrorCode.isNotEmpty)
          ? 'Servidor recusou renovação (HTTP ${resp.statusCode}: $oauthErrorCode).'
          : 'Servidor recusou renovação (HTTP ${resp.statusCode}).';
      await saveTokenBundle(
        latest.copyWith(
          clientId: effectiveClientId,
          reauthRequired: !keepActiveSession,
          lastRefreshTestSucceeded: false,
          lastRefreshTestMessage: keepActiveSession
              ? '$safeReason Sessão atual mantida até expirar.'
              : safeReason,
          clearLastRefreshVerifiedAt: true,
        ),
      );
      if (!keepActiveSession) {
        await _persistSessionMeta(
          CareLinkSessionStatus.reauthRequired,
          error: '$safeReason Necessária nova autenticação.',
        );
      }
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.reauthRequired,
        keepActiveSession
            ? '$safeReason A sessão atual continua ativa até expirar.'
            : '$safeReason Necessária nova autenticação.',
        statusCode: resp.statusCode,
      );
    }

    if (!keepActiveSession) {
      await _persistSessionMeta(
        CareLinkSessionStatus.offline,
        error: 'Erro temporário CareLink (HTTP ${resp.statusCode}).',
      );
    }
    throw CareLinkAuthException(
      CareLinkAuthErrorKind.serverError,
      'Servidor CareLink temporariamente indisponível (HTTP ${resp.statusCode}).',
      statusCode: resp.statusCode,
    );
  }

  /// Fetches the latest telemetry according to configured source:
  /// 1. Local xDrip+ (`http://127.0.0.1:17580/sgv.json`) if enabled.
  /// 2. CareLink EU Cloud with automatic OAuth2 token refresh & encrypted storage.
  /// 3. Cached real telemetry fallback without ever generating fake values.
  Future<PumpTelemetry> fetchLatestTelemetry({
    bool throwOnError = false,
  }) async {
    final prefs = await _prefsProvider();
    final useXdrip = prefs?.getBool(prefKeyUseXdrip) ?? false;
    final xdripUrl = prefs?.getString(prefKeyXdripUrl) ?? defaultXdripUrl;
    final configuredUsername = (prefs?.getString(prefKeyUsername) ?? '').trim();
    final configuredPatientId =
        (prefs?.getString(prefKeyPatientId) ?? '').trim();

    String? fetchError;
    if (useXdrip) {
      try {
        final telemetry = await fetchFromLocalXdrip(endpointUrl: xdripUrl);
        await cacheTelemetry(telemetry);
        await _persistSessionMeta(CareLinkSessionStatus.xdrip, clearError: true);
        return telemetry;
      } catch (e) {
        fetchError = sanitizeErrorText(e.toString());
        await _persistSessionMeta(CareLinkSessionStatus.offline, error: fetchError);
        if (throwOnError) rethrow;
      }
    } else {
      final storedBundle = await loadStoredTokenBundle();
      if (storedBundle != null) {
        try {
          final telemetry = await fetchFromCareLinkEu(
            usernameOverride:
                configuredUsername.isEmpty ? null : configuredUsername,
            patientIdOverride:
                configuredPatientId.isEmpty ? null : configuredPatientId,
          );
          await cacheTelemetry(telemetry);
          return telemetry;
        } catch (e) {
          fetchError = sanitizeErrorText(e.toString());
          if (e is CareLinkAuthException &&
              e.kind == CareLinkAuthErrorKind.reauthRequired) {
            await _persistSessionMeta(
              CareLinkSessionStatus.reauthRequired,
              error: fetchError,
            );
          } else if (e is CareLinkAuthException &&
              e.kind == CareLinkAuthErrorKind.networkError) {
            await _persistSessionMeta(
              CareLinkSessionStatus.offline,
              error: fetchError,
            );
          }
          if (throwOnError) rethrow;
        }
      } else {
        await _persistSessionMeta(CareLinkSessionStatus.unconfigured);
      }
    }

    final cached = await getCachedTelemetry();
    if (cached != null) {
      return cached.copyWith(
        errorMessage: fetchError,
        clearError: fetchError == null,
      );
    }

    if (fetchError != null) {
      return PumpTelemetry.empty(
        dataSource: useXdrip ? 'xDrip+ offline' : 'CareLink indisponível',
        errorMessage: fetchError,
      );
    }

    return PumpTelemetry.empty(
      dataSource: 'Sensores locais',
    );
  }

  /// Queries CareLink Cloud using encrypted credentials and automatically
  /// refreshes & retries once on `401`/`403` before giving up.
  Future<PumpTelemetry> fetchFromCareLinkEu({
    String? usernameOverride,
    String? patientIdOverride,
  }) async {
    var bundle = await ensureValidTokenBundle(forceRefresh: false);

    final username = (usernameOverride != null && usernameOverride.isNotEmpty)
        ? usernameOverride
        : (bundle.username ?? '');
    if (username.isEmpty) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.missingUsername,
        'Nome de utilizador CareLink em falta.',
      );
    }

    Future<PumpTelemetry> executeFetch(CareLinkTokenBundle activeBundle) async {
      CareLinkEndpointConfig endpoints;
      try {
        endpoints = await discoverEndpoints(country: activeBundle.country);
      } on CareLinkAuthException {
        rethrow;
      }

      final headers = <String, String>{
        'Authorization': 'Bearer ${activeBundle.accessToken}',
        if (activeBundle.magIdentifier != null &&
            activeBundle.magIdentifier!.isNotEmpty)
          'mag-identifier': activeBundle.magIdentifier!,
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
        'User-Agent':
            'Dalvik/2.1.0 (Linux; U; Android 15; Pixel 10a Build/AP3A.241005.015)',
      };

      final prefs = await _prefsProvider();
      var resolvedRole =
          (patientIdOverride != null && patientIdOverride.isNotEmpty)
              ? 'carepartner'
              : (prefs?.getString(prefKeyCachedRole) ?? 'patient');
      var resolvedPatientId = patientIdOverride;

      // Resolve user role & patient link if CarePartner (matches carelink_client2.py)
      final usersMeUri = Uri.parse('${endpoints.baseUrlCareLink}/users/me');
      _requireHttps(usersMeUri);
      final meResp = await _httpClient
          .get(usersMeUri, headers: headers)
          .timeout(const Duration(seconds: 10));

      if (meResp.statusCode == 401 || meResp.statusCode == 403) {
        throw CareLinkAuthException(
          CareLinkAuthErrorKind.reauthRequired,
          'Token rejeitado em /users/me (HTTP ${meResp.statusCode}).',
          statusCode: meResp.statusCode,
        );
      }

      if (meResp.statusCode == 200) {
        final meJson = Map<String, dynamic>.from(jsonDecode(meResp.body) as Map);
        final roleStr = meJson['role']?.toString() ?? '';
        if (roleStr == 'CARE_PARTNER' || roleStr == 'CARE_PARTNER_OUS') {
          resolvedRole = 'carepartner';
          await prefs?.setString(prefKeyCachedRole, 'carepartner');
          if (resolvedPatientId == null || resolvedPatientId.isEmpty) {
            final patientsUri =
                Uri.parse('${endpoints.baseUrlCareLink}/links/patients');
            _requireHttps(patientsUri);
            final pResp = await _httpClient
                .get(patientsUri, headers: headers)
                .timeout(const Duration(seconds: 10));
            if (pResp.statusCode == 401 || pResp.statusCode == 403) {
              throw CareLinkAuthException(
                CareLinkAuthErrorKind.reauthRequired,
                'Token rejeitado em /links/patients.',
                statusCode: pResp.statusCode,
              );
            }
            if (pResp.statusCode == 200) {
              final pList = jsonDecode(pResp.body) as List;
              if (pList.isNotEmpty && pList.first is Map) {
                resolvedPatientId = pList.first['username']?.toString();
                if (resolvedPatientId != null &&
                    resolvedPatientId.isNotEmpty) {
                  await prefs?.setString(prefKeyPatientId, resolvedPatientId);
                }
              }
            }
          }
        } else {
          resolvedRole = 'patient';
          await prefs?.setString(prefKeyCachedRole, 'patient');
        }
      }

      final bodyPayload = <String, dynamic>{
        'username': username,
        'role': resolvedRole,
        if (resolvedRole == 'carepartner' &&
            resolvedPatientId != null &&
            resolvedPatientId.isNotEmpty)
          'patientId': resolvedPatientId,
      };

      // Primary endpoint: baseUrlCumulus + /display/message (v13 in discover 3.6)
      final primaryUri = Uri.parse('${endpoints.baseUrlCumulus}/display/message');
      _requireHttps(primaryUri);
      var response = await _httpClient
          .post(
            primaryUri,
            headers: headers,
            body: jsonEncode(bodyPayload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 404) {
        final fallbackUri = Uri.parse(careLinkEuV11Url);
        response = await _httpClient
            .post(
              fallbackUri,
              headers: headers,
              body: jsonEncode(bodyPayload),
            )
            .timeout(const Duration(seconds: 15));
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw CareLinkAuthException(
          CareLinkAuthErrorKind.reauthRequired,
          'Acesso negado pela CareLink (HTTP ${response.statusCode}).',
          statusCode: response.statusCode,
        );
      }

      if (response.statusCode != 200) {
        throw CareLinkAuthException(
          CareLinkAuthErrorKind.serverError,
          'CareLink HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      final decoded =
          Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      return parseCareLinkMessageJson(decoded);
    }

    try {
      final result = await executeFetch(bundle);
      await _persistSessionMeta(
        CareLinkSessionStatus.connected,
        clearError: true,
      );
      return result;
    } on CareLinkAuthException catch (e) {
      if (e.kind == CareLinkAuthErrorKind.reauthRequired &&
          (e.statusCode == 401 || e.statusCode == 403) &&
          bundle.hasRefreshToken) {
        // Token was rejected server-side despite local exp check -> force refresh & retry once.
        bundle = await ensureValidTokenBundle(forceRefresh: true);
        final retried = await executeFetch(bundle);
        await _persistSessionMeta(
          CareLinkSessionStatus.connected,
          clearError: true,
        );
        return retried;
      }
      rethrow;
    } catch (e) {
      if (e is CareLinkAuthException) rethrow;
      await _persistSessionMeta(
        CareLinkSessionStatus.offline,
        error: 'Sem ligação ao servidor CareLink.',
      );
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.networkError,
        'Sem ligação ao servidor CareLink.',
      );
    }
  }

  /// Parses the CareLink v6/v11/v13 display/message JSON structure.
  PumpTelemetry parseCareLinkMessageJson(Map<String, dynamic> rootJson) {
    final now = _nowProvider();
    final Map<String, dynamic> data = rootJson['patientData'] is Map
        ? Map<String, dynamic>.from(rootJson['patientData'] as Map)
        : rootJson;

    final Map<String, dynamic> lastSgMap = data['lastSG'] is Map
        ? Map<String, dynamic>.from(data['lastSG'] as Map)
        : <String, dynamic>{};

    final int? rawSg = (lastSgMap['sg'] as num?)?.toInt();
    final int? sgValue =
        (rawSg != null && rawSg >= 20 && rawSg <= 600) ? rawSg : null;
    final DateTime? sgDateTime = lastSgMap['datetime'] != null
        ? DateTime.tryParse(lastSgMap['datetime'].toString())
        : null;

    String lastSgTrend = 'NONE';
    if (data['lastSGTrend'] is String) {
      lastSgTrend = (data['lastSGTrend'] as String).toUpperCase();
    } else if (data['lastSGTrend'] is Map) {
      final trendMap = Map<String, dynamic>.from(data['lastSGTrend'] as Map);
      lastSgTrend = (trendMap['trend'] ?? 'NONE').toString().toUpperCase();
    }

    final Map<String, dynamic> activeInsulinMap = data['activeInsulin'] is Map
        ? Map<String, dynamic>.from(data['activeInsulin'] as Map)
        : <String, dynamic>{};
    final double? activeInsulin =
        (activeInsulinMap['amount'] as num?)?.toDouble();

    final List<MealMarker> mealMarkers = [];
    final List<BolusMarker> bolusMarkers = [];
    final List<AutoBasalMarker> autoBasalMarkers = [];

    final rawMarkers = data['markers'];
    if (rawMarkers is List) {
      for (final item in rawMarkers) {
        if (item is! Map) continue;
        final marker = Map<String, dynamic>.from(item);
        final type = (marker['type'] ?? '').toString().toUpperCase();
        final rawTime =
            (marker['timestamp'] ?? marker['dateTime'] ?? marker['datetime'])
                ?.toString();
        final parsedTime = DateTime.tryParse(rawTime ?? '');
        if (parsedTime == null) continue;

        final markerId = (marker['index'] ?? marker['id'])?.toString();

        if (type == 'MEAL') {
          final carbs = (marker['amount'] ??
                  marker['carbohydrates'] ??
                  marker['value'] ??
                  0) as num;
          final meal = MealMarker(
            carbsGrams: carbs.toDouble(),
            timestamp: parsedTime,
            origin: TelemetryOrigin.carelink,
            sourceId: markerId,
          );
          if (meal.isValidAt(now)) {
            mealMarkers.add(meal);
          }
        } else if (type == 'INSULIN') {
          final double deliveredExtended =
              (marker['deliveredExtendedAmount'] as num?)?.toDouble() ?? 0.0;
          final double deliveredFast =
              (marker['deliveredFastAmount'] as num?)?.toDouble() ?? 0.0;
          final double summedDelivered = deliveredExtended + deliveredFast;
          final double insulinAmount = summedDelivered > 0
              ? summedDelivered
              : ((marker['programmedFastAmount'] ?? marker['amount'] ?? 0)
                      as num)
                  .toDouble();
          final activationType =
              (marker['activationType'] ?? marker['subType'] ?? 'BOLUS')
                  .toString();
          if (insulinAmount > 0 && insulinAmount <= 50.0) {
            bolusMarkers.add(
              BolusMarker(
                insulinUnits: insulinAmount,
                timestamp: parsedTime,
                bolusType: activationType,
              ),
            );
          }
        } else if (type == 'AUTO_BASAL_DELIVERY') {
          final double bolusAmount =
              (marker['bolusAmount'] as num?)?.toDouble() ?? 0.0;
          if (bolusAmount > 0) {
            autoBasalMarkers.add(
              AutoBasalMarker(
                bolusAmount: bolusAmount,
                timestamp: parsedTime,
              ),
            );
          }
        }
      }
    }

    final Map<String, dynamic> deviceInfo =
        data['medicalDeviceInformation'] is Map
            ? Map<String, dynamic>.from(data['medicalDeviceInformation'] as Map)
            : <String, dynamic>{};

    final double? reservoirUnits = (deviceInfo['reservoirRemainingUnits'] ??
            deviceInfo['reservoirAmount'] ??
            data['reservoirRemainingUnits'] ??
            data['reservoirAmount'] as num?)
        ?.toDouble();

    final int? pumpBattery = (deviceInfo['pumpBatteryLevel'] ??
            deviceInfo['deviceBatteryLevel'] ??
            deviceInfo['batteryLevelPercent'] ??
            deviceInfo['medicalDeviceBatteryLevelPercent'] ??
            data['medicalDeviceBatteryLevelPercent'] ??
            data['conduitBatteryLevel'] as num?)
        ?.toInt()
        .clamp(0, 100);

    final int? sensorMinutesLeft = (data['sensorDurationMinutes'] ??
            deviceInfo['sensorDurationMinutes'] as num?)
        ?.toInt();

    final List<SgReading> sgHistory = [];
    final rawSgs = data['sgs'];
    if (rawSgs is List) {
      for (final item in rawSgs) {
        if (item is! Map) continue;
        final sgEntry = Map<String, dynamic>.from(item);
        final val = (sgEntry['sg'] as num?)?.toInt() ?? 0;
        final dtStr = (sgEntry['datetime'] ?? sgEntry['dateTime'])?.toString();
        final dt = dtStr != null ? DateTime.tryParse(dtStr) : null;
        if (dt != null) {
          final reading = SgReading(
            sg: val,
            timestamp: dt,
            origin: TelemetryOrigin.carelink,
            sourceId: sgEntry['version']?.toString(),
          );
          if (reading.isValidAt(now)) {
            sgHistory.add(reading);
          }
        }
      }
    }

    final resolvedSg =
        sgValue ?? (sgHistory.isNotEmpty ? sgHistory.last.sg : null);
    final resolvedDateTime = sgDateTime ??
        (sgHistory.isNotEmpty ? sgHistory.last.timestamp : null);

    if (resolvedSg != null && resolvedDateTime != null) {
      final candidate = SgReading(
        sg: resolvedSg,
        timestamp: resolvedDateTime,
        origin: TelemetryOrigin.carelink,
      );
      if (candidate.isValidAt(now) &&
          !sgHistory.any(
            (r) => r.timestamp.difference(resolvedDateTime).inSeconds.abs() < 30,
          )) {
        sgHistory.add(candidate);
      }
    }
    sgHistory.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return PumpTelemetry(
      sgValue: resolvedSg,
      sgDateTime: resolvedDateTime,
      sgTrend: lastSgTrend,
      sgOrigin: TelemetryOrigin.carelink,
      activeInsulin: activeInsulin,
      reservoirRemaining: reservoirUnits,
      pumpBatteryPercent: pumpBattery,
      pumpBatteryLabel: pumpBattery != null ? '$pumpBattery%' : null,
      sensorMinutesLeft: sensorMinutesLeft,
      sgHistory: sgHistory,
      mealMarkers: mealMarkers,
      bolusMarkers: bolusMarkers,
      autoBasalMarkers: autoBasalMarkers,
      dataSource: 'CareLink EU',
    );
  }

  /// Queries the local xDrip+ endpoint (`http://127.0.0.1:17580/sgv.json`).
  Future<PumpTelemetry> fetchFromLocalXdrip({
    String endpointUrl = defaultXdripUrl,
  }) async {
    final uri = Uri.parse(
      endpointUrl.contains('?') ? endpointUrl : '$endpointUrl?count=288',
    );
    _requireHttps(uri, allowLoopbackHttp: true);

    final response = await _httpClient
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.serverError,
        'xDrip+ local HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      return parseCareLinkMessageJson(Map<String, dynamic>.from(decoded));
    }
    if (decoded is! List || decoded.isEmpty) {
      throw CareLinkAuthException(
        CareLinkAuthErrorKind.serverError,
        'xDrip+ local sem leituras disponíveis',
      );
    }

    final now = _nowProvider();
    final List<SgReading> history = [];
    final List<MealMarker> meals = [];
    final List<BolusMarker> boluses = [];

    double? latestIob;
    double? reservoir;
    int? pumpBattery;
    String latestTrend = 'NONE';
    int? latestSg;
    DateTime? latestTime;

    for (int i = 0; i < decoded.length; i++) {
      final raw = decoded[i];
      if (raw is! Map) continue;
      final entry = Map<String, dynamic>.from(raw);
      final sgv = (entry['sgv'] as num?)?.toInt() ?? 0;
      final epochMs = (entry['date'] as num?)?.toInt();
      if (epochMs == null) continue;
      final dt = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);

      final reading = SgReading(
        sg: sgv,
        timestamp: dt,
        origin: TelemetryOrigin.xdrip,
      );
      if (reading.isValidAt(now)) {
        history.add(reading);
      }

      if (i == 0) {
        if (reading.isValidAt(now)) latestSg = sgv;
        latestTime = dt;
        latestTrend = _mapXdripDirectionToCareLinkTrend(
          entry['direction']?.toString(),
        );
        latestIob = (entry['iob'] as num?)?.toDouble();
        reservoir = (entry['reservoir'] as num?)?.toDouble();
        final rawBatt =
            (entry['uploaderBattery'] ?? entry['pumpBattery']) as num?;
        pumpBattery = rawBatt?.toInt().clamp(0, 100);

        final cob = (entry['cob'] as num?)?.toDouble() ?? 0.0;
        if (cob > 0) {
          meals.add(
            MealMarker(
              carbsGrams: cob,
              timestamp: dt,
              origin: TelemetryOrigin.xdrip,
            ),
          );
        }
      }
    }

    history.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return PumpTelemetry(
      sgValue: latestSg,
      sgDateTime: latestTime,
      sgTrend: latestTrend,
      sgOrigin: TelemetryOrigin.xdrip,
      activeInsulin: latestIob,
      reservoirRemaining: reservoir,
      pumpBatteryPercent: pumpBattery,
      pumpBatteryLabel: pumpBattery != null ? '$pumpBattery%' : null,
      sgHistory: history,
      mealMarkers: meals,
      bolusMarkers: boluses,
      dataSource: 'xDrip+ Local',
    );
  }

  String _mapXdripDirectionToCareLinkTrend(String? direction) {
    switch (direction) {
      case 'DoubleUp':
      case 'TripleUp':
        return 'UP_DOUBLE';
      case 'SingleUp':
      case 'FortyFiveUp':
        return 'UP';
      case 'SingleDown':
      case 'FortyFiveDown':
        return 'DOWN';
      case 'DoubleDown':
      case 'TripleDown':
        return 'DOWN_DOUBLE';
      case 'Flat':
      default:
        return 'NONE';
    }
  }

  Future<void> cacheTelemetry(PumpTelemetry telemetry) async {
    try {
      final prefs = await _prefsProvider();
      await prefs?.setString(prefKeyCachedTelemetry, telemetry.encode());
    } catch (e) {
      debugPrint('CareLinkService.cacheTelemetry warning: ${e.runtimeType}');
    }
  }

  Future<PumpTelemetry?> getCachedTelemetry() async {
    try {
      final prefs = await _prefsProvider();
      final raw = prefs?.getString(prefKeyCachedTelemetry);
      return PumpTelemetry.decode(raw);
    } catch (e) {
      debugPrint('CareLinkService.getCachedTelemetry warning: ${e.runtimeType}');
      return null;
    }
  }
}
