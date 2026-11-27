/// In-process fake of the Encatch gateway and core API, for unit tests.
///
/// A Dart port of the rules in the mock API's CONTRACT.md (React Native repo,
/// `examples/mock-api`), which lists the server source for each rule. Keep the
/// two in step: `test/fake_api_contract_test.dart` checks the rules here.
///
/// It never talks to a network. Time comes from `package:clock`, so it follows
/// fake time inside `fakeAsync`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uuid/uuid.dart';

const defaultApiKey = 'mock-api-key';
const secureApiKey = 'mock-secure-api-key';
const secureSessionApiKey = 'mock-secure-session-api-key';
const defaultSecret = 'mock-secret';
const defaultFormId = '0190f1d2-0000-7000-8000-00000000f001';
const secondFormId = '0190f1d2-0000-7000-8000-00000000f002';

/// The core API's system events (services/track_event.rs).
const systemEvents = [
  'form:show',
  'form:started',
  'form:dismissed',
  'form:complete',
  'form:answered',
];

/// Hex HMAC-SHA256, as a customer's backend and the gateway compute it.
String hmacHex(String data, String secret) =>
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(data)).toString();

class FakeApiKey {
  const FakeApiKey({
    this.allowedReferers = const ['*'],
    this.secret,
    this.sessionTimeMinutes = 0,
  });
  final List<String> allowedReferers;
  final String? secret;
  final int sessionTimeMinutes;
}

class SurveyTrigger {
  const SurveyTrigger(this.formId, {this.onPageDelay = 0});
  final String formId;
  final int onPageDelay;
}

/// Forces the outcome of the next [count] requests to [endpoint].
class Fault {
  Fault(
    this.endpoint, {
    this.count = 1,
    this.status,
    this.body,
    this.retryAfterSeconds,
    this.retryAfter,
    this.drop = false,
    this.delay,
    this.hang = false,
  });
  final String endpoint;
  int count;
  final int? status;
  final Map<String, dynamic>? body;
  final int? retryAfterSeconds;

  /// Exact Retry-After value, for example an HTTP date.
  final String? retryAfter;

  /// Simulates a network failure: the request throws.
  final bool drop;

  /// Extra delay before the request continues (or before [status] is sent).
  final Duration? delay;

  /// The request never answers.
  final bool hang;
}

enum RateLimitMode { off, scopes, perEndpoint }

enum RateLimitKey { user, userName, ip, device }

class EndpointLimit {
  const EndpointLimit(this.limit, this.key);
  final int limit;
  final RateLimitKey key;
}

class RateLimit {
  const RateLimit({
    this.mode = RateLimitMode.off,
    this.window = const Duration(minutes: 1),
    this.user,
    this.ip,
    this.project,
    this.perEndpoint = const {},
  });
  final RateLimitMode mode;
  final Duration window;
  final int? user;
  final int? ip;
  final int? project;
  final Map<String, EndpointLimit> perEndpoint;

  static const off = RateLimit();

  /// Five per minute for each endpoint, by device.
  static const perEndpoint5 = RateLimit(
    mode: RateLimitMode.perEndpoint,
    perEndpoint: {
      'identify-user': EndpointLimit(5, RateLimitKey.device),
      'track-event': EndpointLimit(5, RateLimitKey.device),
      'track-screen': EndpointLimit(5, RateLimitKey.device),
      'ping': EndpointLimit(5, RateLimitKey.device),
      'show-form': EndpointLimit(5, RateLimitKey.device),
      'submit-form': EndpointLimit(5, RateLimitKey.device),
      'dismiss-form': EndpointLimit(5, RateLimitKey.device),
    },
  );

  /// The limits planned for production.
  static const plannedProd = RateLimit(
    mode: RateLimitMode.perEndpoint,
    perEndpoint: {
      'identify-user': EndpointLimit(5, RateLimitKey.userName),
      'track-screen': EndpointLimit(20, RateLimitKey.device),
      'track-event': EndpointLimit(5, RateLimitKey.device),
      'show-form': EndpointLimit(100, RateLimitKey.device),
      'submit-form': EndpointLimit(100, RateLimitKey.device),
    },
  );

  /// The gateway's code defaults for a test key: one shared set of buckets.
  static const codeDefaultsTest = RateLimit(
    mode: RateLimitMode.scopes,
    user: 10,
    ip: 50,
    project: 50,
  );

  /// A very small shared limit.
  static const tiny = RateLimit(mode: RateLimitMode.scopes, ip: 5);
}

/// Everything a test can change about the fake. Defaults model the real server.
class Scenario {
  String orgId = '1006';
  String projectId = '1009';
  String userIdNamespace = '6ba7b810-9dad-11d1-80b4-00c04fd430c8';
  Map<String, FakeApiKey> apiKeys = {
    defaultApiKey: const FakeApiKey(),
    secureApiKey: const FakeApiKey(secret: defaultSecret),
    secureSessionApiKey: const FakeApiKey(
      secret: defaultSecret,
      sessionTimeMinutes: 15,
    ),
  };
  RateLimit rateLimit = RateLimit.off;
  Duration latency = Duration.zero;

  SurveyTrigger? identifyTrigger;
  SurveyTrigger? pingTrigger;
  Map<String, SurveyTrigger> eventTriggers = {};
  Map<String, SurveyTrigger> screenTriggers = {};

  Map<String, String> forms = {
    defaultFormId: 'Mock survey',
    secondFormId: 'Second mock survey',
  };
  bool visitorsEnabled = true;
  bool allowTrackEventForVisitors = false;
  List<String> disabledEvents = [];

  /// After an automatic show, more automatic shows of the same form to the same
  /// person get 404 for this long (production's "1 x 200 then 16 x 404").
  Duration autoShowCooldown = const Duration(hours: 24);

  /// The core API's "user pending creation" path for identified users.
  bool userPending = false;
  int userPendingExhaustAfter = 5;
  Duration userPendingWindow = const Duration(minutes: 5);

  /// SV8: check the signature on every request, not only identify-user.
  bool enforceSignatureOnAllRequests = false;

  /// The gateway since 2026-11-27: a 401 for an expired signature carries
  /// `"reason": "user_signature_expired"`. False models an older gateway.
  bool expiredSignatureReason = true;

  List<Fault> faults = [];
}

/// One request the fake received.
class FakeRequest {
  FakeRequest(this.endpoint, this.headers, this.body, this.atMs);
  final String endpoint;

  /// Lower-case header names.
  final Map<String, String> headers;
  final Map<String, dynamic> body;
  final int atMs;
  int status = 0;
  Map<String, dynamic>? reply;
  bool rateLimited = false;

  String? get userName => headers['x-user-name'];
  String? get userId => headers['x-user-id'];
  String? get eventName => body['eventName'] as String?;
  String? get screen =>
      (body[r'$deviceInfo'] as Map?)?[r'$urlOrScreenName'] as String?;

  @override
  String toString() => '$endpoint $status name=$userName id=$userId';
}

class _Window {
  _Window(this.resetAt);
  int count = 0;
  final int resetAt;
}

class _Reply {
  _Reply(this.status, this.body, {this.headers = const {}, this.sse});
  final int status;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
  final String? sse;
}

class FakeApi {
  final Scenario scenario = Scenario();
  final List<FakeRequest> requests = [];

  final _windows = <String, _Window>{};
  final _shown = <String, int>{};
  final _open = <String, String>{};
  final _dropped = <String>{};
  final _identified = <String>{};
  final _pendingFailures = <String, List<int>>{};

  late final http.Client client = MockClient(_handle);

  int get _now => clock.now().millisecondsSinceEpoch;

  // -- Reading what was received ---------------------------------------------

  List<FakeRequest> of(String endpoint) =>
      requests.where((r) => r.endpoint == endpoint).toList();
  int count(String endpoint, {int? status}) => requests
      .where(
        (r) => r.endpoint == endpoint && (status == null || r.status == status),
      )
      .length;
  void clearRequests() => requests.clear();

  /// The id the server gives [userName]: UUIDv5(namespace, "org:project:name").
  String expectedUserId(String userName) => const Uuid().v5(
    scenario.userIdNamespace,
    '${scenario.orgId}:${scenario.projectId}:$userName',
  );

  /// What a customer's backend would return for secure identify.
  /// [age] signs a time that far in the past (an already-expired signature).
  ({String signature, String? time}) sign(
    String userName,
    String apiKey, {
    Duration age = Duration.zero,
  }) {
    final key = scenario.apiKeys[apiKey]!;
    if (key.sessionTimeMinutes > 0) {
      final time = '${_now - age.inMilliseconds}';
      return (signature: hmacHex('$userName$time', key.secret!), time: time);
    }
    return (signature: hmacHex(userName, key.secret!), time: null);
  }

  // -- Request handling ------------------------------------------------------

  Future<http.Response> _handle(http.Request req) async {
    final match = RegExp(r'/v2/encatch/(.+)$').firstMatch(req.url.path);
    if (match == null) return _json(404, {'error': 'route not found'});
    final endpoint = match.group(1)!;

    final headers = <String, String>{};
    req.headers.forEach((k, v) => headers[k.toLowerCase()] = v);
    var body = <String, dynamic>{};
    if (endpoint == 'upload') {
      body = {'multipart': true};
    } else {
      try {
        final decoded = jsonDecode(req.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {
        // leave empty
      }
    }

    final record = FakeRequest(endpoint, headers, body, _now);
    requests.add(record);

    if (scenario.latency > Duration.zero) {
      await Future<void>.delayed(scenario.latency);
    }

    final fault = _takeFault(endpoint);
    if (fault != null) {
      if (fault.hang) return Completer<http.Response>().future;
      if (fault.delay != null) await Future<void>.delayed(fault.delay!);
      if (fault.drop) {
        record.status = -1;
        throw http.ClientException('Connection dropped by the fake', req.url);
      }
      if (fault.status != null) {
        final retryAfter =
            fault.retryAfter ??
            (fault.retryAfterSeconds != null
                ? '${fault.retryAfterSeconds}'
                : null);
        return _send(
          record,
          _Reply(
            fault.status!,
            fault.body ??
                (fault.status == 429
                    ? {'error': 'rate limit exceeded'}
                    : {
                        'status': fault.status,
                        'error': 'Error',
                        'message': 'Forced by the fake',
                      }),
            headers: {'retry-after': ?retryAfter},
          ),
        );
      }
    }

    final gate = _gateway(record);
    if (gate.status != 200) return _send(record, gate);
    final reply = _core(record);
    return _send(
      record,
      _Reply(reply.status, reply.body, headers: gate.headers, sse: reply.sse),
    );
  }

  Fault? _takeFault(String endpoint) {
    for (final f in scenario.faults) {
      if (f.endpoint == endpoint && f.count > 0) {
        f.count -= 1;
        return f;
      }
    }
    return null;
  }

  http.Response _send(FakeRequest record, _Reply reply) {
    record.status = reply.status;
    record.reply = reply.body;
    record.rateLimited = reply.status == 429;
    if (reply.sse != null) {
      return http.Response(
        reply.sse!,
        reply.status,
        headers: {'content-type': 'text/event-stream', ...reply.headers},
      );
    }
    return _json(reply.status, reply.body, headers: reply.headers);
  }

  http.Response _json(
    int status,
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
  }) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json', ...headers},
  );

  // -- Gateway (user-gateway-service) ----------------------------------------
  // Order: API key, Referer, key validity, signature, rate limit.

  _Reply _reject(
    int status,
    String error, [
    Map<String, String> headers = const {},
  ]) => _Reply(status, {'error': error}, headers: headers);

  _Reply _gateway(FakeRequest r) {
    final apiKey = r.headers['x-api-key'] ?? '';
    if (apiKey.isEmpty) return _reject(401, 'api key is required');
    final referer = r.headers['referer'] ?? '';
    if (referer.isEmpty) return _reject(401, 'referer is required');
    final key = scenario.apiKeys[apiKey];
    if (key == null) return _reject(401, 'invalid api key');
    final allowed =
        key.allowedReferers.contains('*') ||
        key.allowedReferers.any(
          (a) => a.toLowerCase() == referer.toLowerCase(),
        );
    if (!allowed) return _reject(401, 'invalid api key');

    if (r.endpoint == 'identify-user' ||
        (scenario.enforceSignatureOnAllRequests && key.secret != null)) {
      final result = signatureResult(r.headers, key);
      if (result == 'expired' && scenario.expiredSignatureReason) {
        return _Reply(401, {
          'error': 'invalid api key',
          'reason': 'user_signature_expired',
        });
      }
      if (result != 'ok') return _reject(401, 'invalid api key');
    }
    return _rateLimit(r);
  }

  /// The gateway's secure-identify check (ugw-auth/src/session.rs). Reads
  /// X-User-Name, X-User-Signature and X-User-Session-Time only.
  String signatureResult(Map<String, String> headers, FakeApiKey key) {
    String? nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;
    final identity = nonEmpty(headers['x-user-name']);
    final signature = nonEmpty(headers['x-user-signature']);
    final timestamp = nonEmpty(headers['x-user-session-time']);
    final expiry = key.sessionTimeMinutes;

    if (identity == null) return 'ok';
    if (key.secret != null) {
      if (signature == null) return 'missing-signature';
      var data = identity;
      if (expiry > 0) {
        if (timestamp == null) return 'missing-timestamp';
        data = '$identity$timestamp';
      }
      if (signature != hmacHex(data, key.secret!)) return 'invalid-signature';
    }
    // The session time is part of the signature: a key without a secret has
    // none to expire.
    if (expiry <= 0 || key.secret == null) return 'ok';
    if (timestamp == null) return 'missing-timestamp';
    // Exactly 13 digits (epoch ms), at most 5 minutes ahead.
    if (!RegExp(r'^\d{13}$').hasMatch(timestamp)) return 'invalid-timestamp';
    final ts = int.parse(timestamp);
    if (ts > _now + 5 * 60000) return 'invalid-timestamp';
    final ageMinutes = (_now - ts) ~/ 60000;
    return ageMinutes > expiry ? 'expired' : 'ok';
  }

  String _clientIp(Map<String, String> h) {
    final real = h['x-real-ip']?.trim() ?? '';
    if (real.isNotEmpty) return real;
    final fwd = h['x-forwarded-for']?.split(',').first.trim() ?? '';
    return fwd.isNotEmpty ? fwd : '127.0.0.1';
  }

  String _bucketId(RateLimitKey key, FakeRequest r) {
    final h = r.headers;
    String orIp(String? value, String prefix) {
      final v = value?.trim() ?? '';
      return v.isNotEmpty ? '$prefix:$v' : 'ip:${_clientIp(h)}';
    }

    switch (key) {
      case RateLimitKey.userName:
        final name = h['x-user-name']?.trim() ?? '';
        final bodyName = r.body['userName'];
        return orIp(
          name.isNotEmpty ? name : (bodyName is String ? bodyName : ''),
          'name',
        );
      case RateLimitKey.user:
        return orIp(h['x-user-id'], 'user');
      case RateLimitKey.device:
        return orIp(h['x-device-id'], 'device');
      case RateLimitKey.ip:
        return 'ip:${_clientIp(h)}';
    }
  }

  _Reply _rateLimit(FakeRequest r) {
    final rl = scenario.rateLimit;
    final ok = _Reply(200, const {});
    if (rl.mode == RateLimitMode.off) return ok;

    final buckets = <(String, int)>[];
    if (rl.mode == RateLimitMode.scopes) {
      final userId = r.headers['x-user-id']?.trim() ?? '';
      if (rl.user != null && userId.isNotEmpty) {
        buckets.add(('user:$userId', rl.user!));
      }
      if (rl.ip != null) buckets.add(('ip:${_clientIp(r.headers)}', rl.ip!));
      if (rl.project != null) buckets.add(('project', rl.project!));
    } else {
      final cfg = rl.perEndpoint[r.endpoint];
      if (cfg != null) {
        buckets.add(('${r.endpoint}:${_bucketId(cfg.key, r)}', cfg.limit));
      }
    }
    if (buckets.isEmpty) return ok;

    // Fixed windows. Every bucket is checked before any is incremented, so a
    // rejected request uses no quota.
    final now = _now;
    final views = <(_Window, int)>[];
    for (final (name, limit) in buckets) {
      var w = _windows[name];
      if (w == null || now >= w.resetAt) {
        w = _Window(now + rl.window.inMilliseconds);
        _windows[name] = w;
      }
      views.add((w, limit));
    }
    Map<String, String> limitHeaders(int limit, int remaining, int resetAt) => {
      'x-ratelimit-limit': '$limit',
      'x-ratelimit-remaining': '${remaining < 0 ? 0 : remaining}',
      'x-ratelimit-reset': '${(resetAt / 1000).ceil()}',
    };
    for (final (w, limit) in views) {
      if (w.count >= limit) {
        final msLeft = w.resetAt - now;
        return _reject(429, 'rate limit exceeded', {
          ...limitHeaders(limit, 0, w.resetAt),
          'retry-after': '${((msLeft < 0 ? 0 : msLeft) / 1000).ceil()}',
        });
      }
    }
    for (final (w, _) in views) {
      w.count += 1;
    }
    final primary = views.reduce(
      (a, b) => (b.$2 - b.$1.count) < (a.$2 - a.$1.count) ? b : a,
    );
    return _Reply(
      200,
      const {},
      headers: limitHeaders(
        primary.$2,
        primary.$2 - primary.$1.count,
        primary.$1.resetAt,
      ),
    );
  }

  // -- Core API (rust/core-api) ----------------------------------------------

  static const _reasons = {
    400: 'Bad Request',
    401: 'Unauthorized',
    403: 'Forbidden',
    404: 'Not Found',
  };
  _Reply _err(int status, String message) => _Reply(status, {
    'status': status,
    'error': _reasons[status] ?? 'Error',
    'message': message,
  });
  _Reply _ok(Map<String, dynamic> body) => _Reply(200, body);

  bool _isUuid(String v) => RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  ).hasMatch(v.trim());

  /// apply_display_result!: a chosen survey travels as nextFeedbackId +
  /// onPageDelay, with pingAgainIn = 30 + delay. No reply carries
  /// formConfigurationId.
  Map<String, dynamic> _display(SurveyTrigger? trigger, String person) {
    if (trigger != null &&
        scenario.forms.containsKey(trigger.formId) &&
        !_dropped.contains('$person|${trigger.formId}')) {
      return {
        'nextFeedbackId': trigger.formId,
        'onPageDelay': trigger.onPageDelay,
        'pingAgainIn': 30 + trigger.onPageDelay,
        'pingOnNextPageVisit': true,
      };
    }
    return {'pingAgainIn': 30, 'pingOnNextPageVisit': true};
  }

  Map<String, dynamic>? _userPendingReply(bool known, String person) {
    if (!scenario.userPending || !known) return null;
    final now = _now;
    final recent = (_pendingFailures[person] ?? <int>[])
        .where((t) => now - t < scenario.userPendingWindow.inMilliseconds)
        .toList();
    recent.add(now);
    _pendingFailures[person] = recent;
    final exhausted = recent.length >= scenario.userPendingExhaustAfter;
    return {
      'message': 'User does not exist / is pending creation',
      'pingAgainIn': exhausted ? 900 : 10,
      'pingOnNextPageVisit': true,
      if (exhausted) 'userPendingRetryExhausted': true,
    };
  }

  String? _findForm(String ref) {
    if (scenario.forms.containsKey(ref)) return ref;
    String slug(String t) =>
        t.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    for (final e in scenario.forms.entries) {
      if (slug(e.value) == ref) return e.key;
    }
    return null;
  }

  _Reply _core(FakeRequest r) {
    final h = r.headers;
    final body = r.body;
    for (final name in ['X-Session-Id', 'X-Device-Id']) {
      if ((h[name.toLowerCase()]?.trim() ?? '').isEmpty) {
        return _err(400, 'Missing required header: $name');
      }
    }

    // Identity (validate_user_identity.rs), skipped for identify-user.
    final name = h['x-user-name']?.trim() ?? '';
    final id = h['x-user-id']?.trim() ?? '';
    if (r.endpoint != 'identify-user') {
      if (name.isNotEmpty != id.isNotEmpty) {
        return _err(
          401,
          'X-User-Name and X-User-Id must both be present or both absent',
        );
      }
      if (name.isNotEmpty) {
        if (!_isUuid(id)) return _err(401, 'X-User-Id is not a valid UUID');
        if (id.toLowerCase() != expectedUserId(name)) {
          return _err(
            401,
            'User ID does not match expected value for the given X-User-Name, '
            'X-Org-Id, and X-Project-Id',
          );
        }
      }
    }
    final known = name.isNotEmpty && id.isNotEmpty;
    final person = known ? 'user:$name' : 'device:${h['x-device-id']}';

    switch (r.endpoint) {
      case 'identify-user':
        final raw = body['userName'];
        final userName = raw is String ? raw.trim() : '';
        if (userName.isEmpty) return _err(401, 'userName not found');
        // A user the server hasn't cached yet is told to ping again in 10 s.
        final isNew = _identified.add(userName);
        return _ok({
          'message': 'ok',
          'userId': expectedUserId(userName),
          ..._display(scenario.identifyTrigger, 'user:$userName'),
          if (isNew) 'pingAgainIn': 10,
        });

      case 'track-event':
        final raw = body['eventName'];
        final eventName = raw is String ? raw : '';
        if (eventName.isEmpty || eventName.length > 100) {
          return _err(
            400,
            'Validation error: eventName must be between 1 and 100 characters',
          );
        }
        if (!known) {
          final forbidden = _Reply(403, {
            'message': 'Event tracking not allowed for visitors',
          });
          if (systemEvents.contains(eventName)) return forbidden;
          if (!scenario.allowTrackEventForVisitors ||
              scenario.disabledEvents.contains(eventName)) {
            return forbidden;
          }
        } else if (scenario.disabledEvents.contains(eventName)) {
          return _err(400, "Event '$eventName' is not allowed to be captured");
        }
        final pending = _userPendingReply(known, person);
        if (pending != null) return _ok(pending);
        return _ok({
          'message': 'ok',
          ..._display(scenario.eventTriggers[eventName], person),
        });

      case 'track-screen':
        final pending = _userPendingReply(known, person);
        if (pending != null) return _ok(pending);
        return _ok({
          'message': 'ok',
          ..._display(scenario.screenTriggers[r.screen], person),
        });

      case 'ping':
        final pending = _userPendingReply(known, person);
        if (pending != null) return _ok(pending);
        return _ok({
          'message': 'ok',
          ..._display(scenario.pingTrigger, person),
        });

      case 'show-form':
        final ref = body['formSlugOrId'];
        if (ref is! String || ref.isEmpty) {
          return _err(400, 'Missing required field: form_slug_or_id');
        }
        final formId = _findForm(ref);
        if (formId == null) return _err(404, 'Form not found: $ref');
        if (!known && !scenario.visitorsEnabled) {
          return _err(
            404,
            'Form not available: Form is not available for visitors',
          );
        }
        const notEligible =
            'Form not available: User is not eligible for this form';
        final key = '$person|$formId';
        if (_dropped.contains(key)) return _err(404, notEligible);
        if (body['triggerType'] == 'automatic') {
          final shownAt = _shown[key];
          if (shownAt != null &&
              _now - shownAt < scenario.autoShowCooldown.inMilliseconds) {
            return _err(404, notEligible);
          }
          _shown[key] = _now;
        }
        _open[person] = formId;
        return _ok(showFormReply(formId, scenario.forms[formId]!));

      case 'submit-form':
        final details = body['formDetails'];
        if (details is! Map) {
          return _err(400, 'Missing required field: form_details');
        }
        final formId = details['formConfigurationId'];
        if (formId is! String || formId.isEmpty) {
          return _err(400, 'Missing required field: form_configuration_id');
        }
        if (_dropped.contains('$person|$formId')) {
          return _err(
            404,
            'Form not available: User is not eligible for this form',
          );
        }
        if (_open[person] == formId && details['isPartialSubmit'] != true) {
          _open.remove(person);
        }
        return _ok({'message': 'ok'});

      case 'dismiss-form':
        if (!known) return _ok({'message': 'ok'});
        final formId = body['formConfigurationId'];
        if (formId is! String || !_isUuid(formId)) {
          return _err(400, 'formConfigurationId must be a valid UUID');
        }
        final pending = _userPendingReply(known, person);
        if (pending != null) return _ok(pending);
        if (_open[person] == formId) _open.remove(person);
        return _ok({'message': 'ok', 'pingOnNextPageVisit': true});

      case 'refine-text':
        if (body['questionId'] == null ||
            body['feedbackConfigurationId'] == null ||
            body['userText'] is! String) {
          return _err(
            400,
            'Missing required field: questionId, feedbackConfigurationId or userText',
          );
        }
        return _ok({
          'message': 'ok',
          'refinedText':
              '${(body['userText'] as String).trim()} (refined by the fake)',
        });

      case 'upload':
        return _ok({'fileUrl': 'https://fake-api.local/uploads/file'});

      case 'qna-with-ai/stream':
        final conversation = body['conversation'];
        if (conversation is! List || conversation.isEmpty) {
          return _err(400, 'conversation must not be empty');
        }
        const answer = 'This answer was streamed by the fake.';
        final words = answer.split(' ');
        final sse = StringBuffer();
        for (var i = 0; i < words.length; i++) {
          final delta = '${i > 0 ? ' ' : ''}${words[i]}';
          sse.write('event: chunk\ndata: ${jsonEncode({'delta': delta})}\n\n');
        }
        sse.write('event: done\ndata: ${jsonEncode({'answer': answer})}\n\n');
        return _Reply(200, const {}, sse: sse.toString());
    }
    return _Reply(404, {'error': 'route not found'});
  }
}

/// A small but valid show-form reply (the fields `ShowFormResponse` reads).
Map<String, dynamic> showFormReply(String formId, String title) => {
  'feedbackConfigurationId': formId,
  'feedbackIdentifier': '0190f1d2-0000-7000-8000-0000000fb001',
  'triggerType': 'manual',
  'partialResponseEnabled': false,
  'formConfiguration': {'formTitle': title},
  'questionnaireFields': {
    'sections': [
      {
        'id': 's1',
        'questionIds': ['q1'],
      },
    ],
    'questions': {
      'q1': {'id': 'q1', 'type': 'rating', 'title': 'How are we doing?'},
    },
  },
  'otherConfigurationProperties': <String, dynamic>{},
  'appearanceProperties': <String, dynamic>{},
};
