/// Encatch Flutter SDK — Core Singleton
///
/// Mirrors encatch.ts from the React Native SDK. All public methods are static.
/// An internal StreamController connects Encatch to EncatchWebView for form display.
/// A 30-second ping interval mirrors the web SDK behaviour.
/// A retry queue wraps identifyUser / trackEvent / trackScreen calls.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'device_info.dart';
import 'logger.dart';
import 'retry_queue.dart' as queue;
import 'storage.dart';
import 'types.dart';

// ============================================================================
// SDK version
// ============================================================================

const _sdkVersion = '1.0.0';

// ============================================================================
// API Endpoint paths
// ============================================================================

const _endpoints = {
  'identifyUser': 'engage-product/encatch/api/v2/encatch/identify-user',
  'trackEvent': 'engage-product/encatch/api/v2/encatch/track-event',
  'trackScreen': 'engage-product/encatch/api/v2/encatch/track-screen',
  'showForm': 'engage-product/encatch/api/v2/encatch/show-form',
  'dismissForm': 'engage-product/encatch/api/v2/encatch/dismiss-form',
  'ping': 'engage-product/encatch/api/v2/encatch/ping',
  'refineText': 'engage-product/encatch/api/v2/encatch/refine-text',
  'submitForm': 'engage-product/encatch/api/v2/encatch/submit-form',
  'upload': 'engage-product/encatch/api/v2/encatch/upload',
  'qnaWithAiStream': 'engage-product/encatch/api/v2/encatch/qna-with-ai/stream',
};

class _ProgressMultipartRequest extends http.MultipartRequest {
  _ProgressMultipartRequest(
    super.method,
    super.url, {
    required this.onProgress,
  });

  final void Function(int bytesSent, int totalBytes) onProgress;

  @override
  http.ByteStream finalize() {
    final totalBytes = contentLength;
    var bytesSent = 0;
    final byteStream = super.finalize();

    return http.ByteStream(
      byteStream.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (data, sink) {
            bytesSent += data.length;
            onProgress(bytesSent, totalBytes);
            sink.add(data);
          },
        ),
      ),
    );
  }
}

// ============================================================================
// Internal event streams (Encatch <-> EncatchWebView)
// ============================================================================

final _showFormController = StreamController<ShowFormPayload>.broadcast();
final _dismissFormController = StreamController<DismissPayload>.broadcast();

// ============================================================================
// Encatch static class
// ============================================================================

/// The Encatch SDK singleton.
///
/// All methods are static. Initialize once at app startup via [EncatchProvider]
/// or by calling [Encatch.init] directly.
///
/// ```dart
/// // Option 1: via EncatchProvider (recommended)
/// EncatchProvider(apiKey: 'your-key', child: MyApp())
///
/// // Option 2: manual init
/// await Encatch.init('your-key');
/// ```
class Encatch {
  // Initialization state
  static bool _initialized = false;
  static bool _debugMode = false;

  // Config
  static String? _apiKey;
  static String _apiBaseUrl = 'https://app.encatch.com';
  static String _webHost = 'https://app.encatch.com';
  static bool _isFullScreen = false;

  // Identity
  static String? _userName;
  static String? _userId;
  static String? _userSignature;

  // Preferences
  static String? _locale;
  static String? _country;
  static EncatchTheme _theme = EncatchTheme.system;

  // Current screen
  static String? _currentScreen;

  // Async-loaded IDs
  static String? _deviceId;
  static String? _sessionId;

  // Feedback transactions
  static String? _feedbackTransactions;

  // Ping interval
  static Timer? _pingTimer;
  static int _pingIntervalMs = 30000;
  static bool _isPingActive = false;

  // Whether a form is currently visible (suppresses ping)
  static bool _isFormVisible = false;

  // Session control state
  static bool _isSessionPaused = false;
  static bool _isSessionStopped = false;

  // App info
  static String _appVersion = '1.0.0';
  static String? _appPackageName;

  // Event callbacks
  static final List<EventCallback> _eventCallbacks = [];

  // Interceptor
  static Future<bool> Function(ShowFormInterceptorPayload)? _onBeforeShowForm;

  // Pending pre-fill responses
  static final Map<String, dynamic> _pendingResponses = {};

  // Logger
  static EncatchLogger _logger = const EncatchLogger(debugMode: false);

  // HTTP client (replaceable for testing)
  static http.Client _httpClient = http.Client();

  // Internal streams (used by EncatchWebView)
  static Stream<ShowFormPayload> get onShowForm => _showFormController.stream;
  static Stream<DismissPayload> get onDismissForm =>
      _dismissFormController.stream;

  // ============================================================================
  // Getters
  // ============================================================================

  static bool get isInitialized => _initialized;
  static String? get apiKey => _apiKey;
  static String get baseUrl => _apiBaseUrl;
  static String get webHost => _webHost;
  static bool get isFullScreen => _isFullScreen;
  static EncatchTheme get theme => _theme;
  static String? get locale => _locale;
  static String? get deviceId => _deviceId;
  static String? get sessionId => _sessionId;
  static String? get userName => _userName;
  static String? get userId => _userId;
  static bool get debugMode => _debugMode;

  // ============================================================================
  // Initialization
  // ============================================================================

  /// Initializes the SDK with [apiKey] and optional [config].
  ///
  /// Must be called before any other SDK methods. Safe to call multiple times —
  /// subsequent calls are no-ops if the SDK is already initialized.
  static Future<void> init(String apiKey, {EncatchConfig? config}) async {
    _debugMode = config?.debugMode ?? false;
    _logger = EncatchLogger(debugMode: _debugMode);

    if (_initialized) {
      _logger.debug('SDK already initialized');
      return;
    }

    _apiKey = apiKey;

    const defaultHost = 'https://app.encatch.com';
    _apiBaseUrl = (config?.apiBaseUrl ?? defaultHost).replaceAll(
      RegExp(r'/+$'),
      '',
    );
    _webHost = (config?.webHost ?? _apiBaseUrl).replaceAll(RegExp(r'/+$'), '');
    _isFullScreen = config?.isFullScreen ?? false;
    if (config?.theme != null) _theme = config!.theme!;
    _onBeforeShowForm = config?.onBeforeShowForm;

    _logger.debug('Initializing SDK...');

    // Load persisted identity, app package, and app version in parallel
    final results = await Future.wait([
      getUserName(),
      getOrCreateDeviceId(),
      getOrCreateSessionId(),
      getPreferences(),
      getAppPackageId(),
      getAppVersion(),
    ]);

    final storedName = results[0] as String?;
    _deviceId = results[1] as String;
    _sessionId = results[2] as String;
    final prefs = results[3] as Preferences;
    _appPackageName = results[4] as String?;
    final detectedAppVersion = results[5] as String?;
    _appVersion = config?.appVersion ?? detectedAppVersion ?? '1.0.0';

    if (prefs.locale != null) _locale = prefs.locale;
    if (prefs.country != null) _country = prefs.country;

    if (storedName != null) {
      _userName = storedName;
      _userId = await getUserId(storedName);
      _feedbackTransactions = await getFeedbackTransactions(storedName);
    } else {
      _feedbackTransactions = await getFeedbackTransactions('anonymous');
    }

    _initialized = true;

    // Start retry queue lifecycle listener
    queue.startAppLifecycleListener();

    // Flush any queued requests from a previous session
    queue.flush().catchError((_) {});

    _logger.debug('SDK initialized. deviceId: $_deviceId');
  }

  // ============================================================================
  // Identity
  // ============================================================================

  /// Identifies the current user by [userName] (typically an email or unique ID).
  ///
  /// Optionally attach [traits] to update the user's profile and [options] for
  /// locale, country, or HMAC secure verification.
  static Future<void> identifyUser(
    String userName, {
    UserTraits? traits,
    IdentifyOptions? options,
  }) async {
    if (!_initialized) return;

    _userName = userName;
    await setUserName(userName);

    if (options?.locale != null) {
      _locale = options!.locale;
      setPreferences(Preferences(locale: options.locale)).catchError((_) {});
    }
    if (options?.country != null) {
      _country = options!.country;
      setPreferences(Preferences(country: options.country)).catchError((_) {});
    }

    // Convert DateTime values in set / setOnce to ISO strings
    Map<String, dynamic>? _convertDates(Map<String, dynamic>? map) {
      if (map == null) return null;
      return map.map(
        (k, v) => MapEntry(k, v is DateTime ? v.toIso8601String() : v),
      );
    }

    final processedTraits = traits == null
        ? null
        : UserTraits(
            set: _convertDates(traits.set),
            setOnce: _convertDates(traits.setOnce),
            increment: traits.increment,
            decrement: traits.decrement,
            unset: traits.unset,
          );

    final deviceInfo = await _buildDeviceInfo();
    final req = IdentifyUserRequest(
      userName: userName,
      userId: _userId,
      userSignature: options?.secure?.signature ?? _userSignature,
      deviceInfo: deviceInfo,
      userAttributes: processedTraits,
      feedbackTransactions: _feedbackTransactions,
    );

    queue.enqueue('identifyUser', () async {
      final res = await _post<IdentifyUserResponse>(
        _endpoints['identifyUser']!,
        req.toJson(),
        IdentifyUserResponse.fromJson,
        signatureTime: options?.secure?.generatedDateTimeinUTC,
      );
      if (res.userId != null) {
        _userId = res.userId;
        await setUserId(userName, res.userId!);
      }
      if (res.feedbackTransactions != null) {
        _feedbackTransactions = res.feedbackTransactions;
        await setFeedbackTransactions(userName, res.feedbackTransactions!);
      }
      _handleResponseMeta(
        formConfigurationId: res.formConfigurationId,
        pingAgainIn: res.pingAgainIn,
        feedbackTransactions: res.feedbackTransactions,
      );
      if (res.formConfigurationId != null) {
        await _showFormInternal(
          res.formConfigurationId!,
          triggerType: TriggerType.automatic,
        );
      }
      await startSession(
        options: const StartSessionOptions(
          skipImmediatePing: true,
          skipImmediateTrackScreen: true,
        ),
      );
    });

    queue.flush().catchError((_) {});
  }

  /// Updates the user's locale preference and persists it.
  static void setLocale(String locale) {
    _locale = locale;
    setPreferences(Preferences(locale: locale)).catchError((_) {});
  }

  static void setCountry(String country) {
    _country = country;
    setPreferences(Preferences(country: country)).catchError((_) {});
  }

  static void setTheme(EncatchTheme theme) {
    _theme = theme;
  }

  // ============================================================================
  // Tracking
  // ============================================================================

  /// Tracks a custom [eventName] and checks for matching form triggers.
  static Future<void> trackEvent(String eventName) async {
    if (!_initialized || _isFullScreen) return;

    final deviceInfo = await _buildDeviceInfo();
    final req = TrackEventRequest(
      eventName: eventName,
      deviceInfo: deviceInfo,
      feedbackTransactions: _feedbackTransactions,
    );

    queue.enqueue('trackEvent', () async {
      final res = await _post<TrackEventResponse>(
        _endpoints['trackEvent']!,
        req.toJson(),
        TrackEventResponse.fromJson,
      );
      if (res.feedbackTransactions != null) {
        _feedbackTransactions = res.feedbackTransactions;
        final key = _userName ?? 'anonymous';
        await setFeedbackTransactions(key, res.feedbackTransactions!);
      }
      _handleResponseMeta(
        formConfigurationId: res.formConfigurationId,
        pingAgainIn: res.pingAgainIn,
        feedbackTransactions: res.feedbackTransactions,
      );
      if (res.formConfigurationId != null) {
        await _showFormInternal(
          res.formConfigurationId!,
          triggerType: TriggerType.automatic,
        );
      }
    });

    queue.flush().catchError((_) {});
  }

  /// Tracks a screen navigation to [screenName] and checks for matching form triggers.
  static Future<void> trackScreen(String screenName) async {
    if (!_initialized || _isFullScreen) return;

    _currentScreen = screenName;

    final deviceInfo = await _buildDeviceInfo(screenName: screenName);
    final req = TrackScreenRequest(
      deviceInfo: deviceInfo,
      feedbackTransactions: _feedbackTransactions,
    );

    queue.enqueue('trackScreen', () async {
      final res = await _post<TrackScreenResponse>(
        _endpoints['trackScreen']!,
        req.toJson(),
        TrackScreenResponse.fromJson,
      );
      if (res.feedbackTransactions != null) {
        _feedbackTransactions = res.feedbackTransactions;
        final key = _userName ?? 'anonymous';
        await setFeedbackTransactions(key, res.feedbackTransactions!);
      }
      _handleResponseMeta(
        formConfigurationId: res.formConfigurationId,
        pingAgainIn: res.pingAgainIn,
        feedbackTransactions: res.feedbackTransactions,
      );
      if (res.formConfigurationId != null) {
        await _showFormInternal(
          res.formConfigurationId!,
          triggerType: TriggerType.automatic,
        );
      } else if (res.nextFeedbackId != null) {
        final delay = res.onPageDelay ?? 0;
        if (delay > 0) {
          Timer(Duration(seconds: delay), () {
            _showFormInternal(
              res.nextFeedbackId!,
              triggerType: TriggerType.automatic,
            ).catchError((_) {});
          });
        } else {
          await _showFormInternal(
            res.nextFeedbackId!,
            triggerType: TriggerType.automatic,
          );
        }
      }
    });

    queue.flush().catchError((_) {});
  }

  // ============================================================================
  // Form display
  // ============================================================================

  /// Manually shows the form identified by [formId] (slug or ID).
  static Future<void> showForm(
    String formId, {
    ShowFormOptions? options,
  }) async {
    await _showFormInternal(
      formId,
      options: options,
      triggerType: TriggerType.manual,
    );
  }

  static Future<void> _showFormInternal(
    String formId, {
    ShowFormOptions? options,
    TriggerType triggerType = TriggerType.manual,
  }) async {
    if (!_initialized) return;

    final resetMode = options?.reset ?? ResetMode.always;

    // Serialize context: convert DateTime values to ISO 8601 strings.
    final Map<String, Object>? serializedContext = options?.context != null
        ? Map.fromEntries(
            options!.context!.entries.map(
              (e) => MapEntry(
                e.key,
                e.value is DateTime
                    ? (e.value as DateTime).toUtc().toIso8601String()
                    : e.value,
              ),
            ),
          )
        : null;
    final deviceInfo = await _buildDeviceInfo();
    final req = ShowFormRequest(
      formSlugOrId: formId,
      triggerType: triggerType,
      language: _locale,
      deviceInfo: deviceInfo,
      feedbackTransactions: _feedbackTransactions,
    );

    ShowFormResponse res;
    try {
      res = await _post<ShowFormResponse>(
        _endpoints['showForm']!,
        req.toJson(),
        ShowFormResponse.fromJson,
      );
    } catch (e) {
      _logger.warn('showForm failed for $formId: $e');
      return;
    }

    if (res.feedbackTransactions != null) {
      _feedbackTransactions = res.feedbackTransactions;
      final key = _userName ?? 'anonymous';
      await setFeedbackTransactions(key, res.feedbackTransactions!);
    }

    final payload = ShowFormInterceptorPayload(
      formId: res.feedbackConfigurationId,
      formConfig: res,
      resetMode: resetMode,
      triggerType: triggerType,
      prefillResponses: Map<String, dynamic>.from(_pendingResponses),
      locale: _locale,
      theme: _theme,
      context: serializedContext,
    );

    if (_onBeforeShowForm != null) {
      bool proceed;
      try {
        proceed = await _onBeforeShowForm!(payload);
      } catch (_) {
        proceed = true;
      }
      if (!proceed) {
        _pendingResponses.clear();
        return;
      }
    }

    _showFormController.add(
      ShowFormPayload(
        formId: res.feedbackConfigurationId,
        formConfig: res,
        resetMode: resetMode,
        triggerType: triggerType,
        prefillResponses: Map<String, dynamic>.from(_pendingResponses),
        locale: _locale,
        theme: _theme,
        context: serializedContext,
      ),
    );
  }

  static Future<void> dismissForm({String? formConfigurationId}) async {
    _dismissFormController.add(
      DismissPayload(formConfigurationId: formConfigurationId),
    );

    try {
      final deviceInfo = await _buildDeviceInfo();
      final req = DismissFormRequest(
        formConfigurationId: formConfigurationId,
        deviceInfo: deviceInfo,
        feedbackTransactions: _feedbackTransactions,
      );
      await _post<DismissFormResponse>(
        _endpoints['dismissForm']!,
        req.toJson(),
        DismissFormResponse.fromJson,
      );
    } catch (_) {
      // fire-and-forget — dismiss always proceeds
    }

    emitEvent(
      EventType.formDismissed,
      EventPayload(
        formId: formConfigurationId,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  // ============================================================================
  // Submit / refine
  // ============================================================================

  /// Submits a form response built with [buildSubmitRequest].
  ///
  /// Use this when building a custom native form UI instead of the WebView overlay.
  static Future<void> submitForm(SubmitFormRequest params) async {
    if (!_initialized) return;

    final deviceInfo = await _buildDeviceInfo();
    final body = params.toJson();
    body[r'$deviceInfo'] = deviceInfo.toJson();
    body[r'$feedbackTransactions'] = _feedbackTransactions;

    final res = await _post<SubmitFormResponse>(
      _endpoints['submitForm']!,
      body,
      SubmitFormResponse.fromJson,
    );

    if (res.feedbackTransactions != null) {
      _feedbackTransactions = res.feedbackTransactions;
      final key = _userName ?? 'anonymous';
      await setFeedbackTransactions(key, res.feedbackTransactions!);
    }
    _handleResponseMeta(
      pingAgainIn: res.pingAgainIn,
      feedbackTransactions: res.feedbackTransactions,
    );
  }

  static Future<RefineTextResponse> refineText(RefineTextRequest params) async {
    final deviceInfo = await _buildDeviceInfo();
    final body = params.toJson();
    body[r'$deviceInfo'] = deviceInfo.toJson();
    body[r'$feedbackTransactions'] = _feedbackTransactions;

    return _post<RefineTextResponse>(
      _endpoints['refineText']!,
      body,
      RefineTextResponse.fromJson,
    );
  }

  // ============================================================================
  // Session management
  // ============================================================================

  static Future<void> startSession({StartSessionOptions? options}) async {
    if (!_initialized || _isFullScreen) return;

    // Clear stopped/paused state — startSession is the explicit re-enable after stopSession()
    _isSessionStopped = false;
    _isSessionPaused = false;
    clearSessionStopped().catchError((_) {});

    // Generate a new session ID
    await clearSession();
    _sessionId = await getOrCreateSessionId();

    _logger.debug('Session started: $_sessionId');

    // Start ping interval
    _startPingInterval();

    if (options?.skipImmediatePing != true) {
      await _doPing();
    }

    if (options?.skipImmediateTrackScreen != true && _currentScreen != null) {
      await trackScreen(_currentScreen!);
    }
  }

  /// Temporarily stops the automatic background ping without affecting open forms,
  /// screen tracking, or user identity. Reversed by [resumeSession].
  /// Not persisted — clears automatically when the app process restarts.
  static void pauseSession() {
    if (_isSessionPaused) return;
    _isSessionPaused = true;
    _stopPingInterval();
  }

  /// Restarts the background ping interval after a [pauseSession] call.
  /// No-op if the session was not paused.
  static void resumeSession() {
    if (!_isSessionPaused) return;
    _isSessionPaused = false;
    _startPingInterval();
  }

  /// Fully suspends all SDK activity — stops the background ping and closes any
  /// open forms. User identity is preserved; no re-identification needed.
  /// Persists across app restarts via SharedPreferences. Re-enable with [startSession].
  static Future<void> stopSession() async {
    if (_isSessionStopped) return;
    _isSessionStopped = true;
    _isSessionPaused = false;
    _stopPingInterval();
    _dismissFormController.add(const DismissPayload());
    _isFormVisible = false;
    await setSessionStopped();
  }

  static void _startPingInterval() {
    _stopPingInterval();
    _isPingActive = true;
    _pingTimer = Timer.periodic(Duration(milliseconds: _pingIntervalMs), (_) {
      if (!_isFormVisible && _isPingActive) {
        _doPing().catchError((_) {});
      }
    });
  }

  static void _stopPingInterval() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _isPingActive = false;
  }

  static Future<void> _doPing() async {
    if (!_initialized || _isFullScreen || _isFormVisible) return;

    try {
      final deviceInfo = await _buildDeviceInfo();
      final req = PingRequest(
        deviceInfo: deviceInfo,
        feedbackTransactions: _feedbackTransactions,
      );
      final res = await _post<PingResponse>(
        _endpoints['ping']!,
        req.toJson(),
        PingResponse.fromJson,
      );

      if (res.feedbackTransactions != null) {
        _feedbackTransactions = res.feedbackTransactions;
        final key = _userName ?? 'anonymous';
        await setFeedbackTransactions(key, res.feedbackTransactions!);
      }

      if (res.pingAgainIn != null && res.pingAgainIn! > 0) {
        _pingIntervalMs = res.pingAgainIn! * 1000;
        _startPingInterval();
      }

      if (res.formConfigurationId != null) {
        await _showFormInternal(
          res.formConfigurationId!,
          triggerType: TriggerType.automatic,
        );
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('user_pending_retry_exhausted')) {
        _stopPingInterval();
        await resetUser();
      }
    }
  }

  // ============================================================================
  // Reset user
  // ============================================================================

  /// Resets the current user's identity and clears persisted data.
  static Future<void> resetUser() async {
    final prevUserName = _userName;
    final prevUserId = _userId;

    if (prevUserName != null) {
      await clearUserId(prevUserName);
      await clearFeedbackTransactions(prevUserName);
    }
    await clearFeedbackTransactions('anonymous');
    await clearUserName();
    await clearPreferences();
    await clearSession();

    _userName = null;
    _userId = null;
    _userSignature = null;
    _feedbackTransactions = null;
    _locale = null;
    _country = null;
    _sessionId = await getOrCreateSessionId();

    // Reset session control flags
    _isSessionPaused = false;
    _isSessionStopped = false;

    _stopPingInterval();

    _logger.debug('User reset. Previous: $prevUserName / $prevUserId');
  }

  // ============================================================================
  // File upload
  // ============================================================================

  static String _extractBase64Payload(String fileData) {
    var payload = fileData.trim();
    final commaIndex = payload.lastIndexOf(',');

    if (commaIndex >= 0) {
      final header = payload.substring(0, commaIndex).toLowerCase();
      if (header.startsWith('data:') && header.contains(';base64')) {
        payload = payload.substring(commaIndex + 1);
      }
    }

    return payload.replaceAll(RegExp(r'\s+'), '');
  }

  static MediaType _uploadMediaType(String mimeType) {
    final baseMimeType = mimeType.split(';').first.trim();
    final parts = baseMimeType.split('/');
    if (parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return MediaType(parts[0], parts[1]);
    }
    return MediaType('application', 'octet-stream');
  }

  /// Uploads a file to the Encatch server for a specific form question.
  ///
  /// Accepts either a local file path ([UploadFileRequest.filePath]) or base64
  /// content ([UploadFileRequest.fileData]) forwarded from the WebView form
  /// engine. [UploadFileRequest.fileData] may be raw base64 or a data URL.
  ///
  /// Returns the permanent [UploadFileResponse.fileUrl] on success.
  static Future<UploadFileResponse> uploadFile(UploadFileRequest params) async {
    if (!_initialized) throw StateError('Encatch SDK is not initialized');

    final url = Uri.parse('$_apiBaseUrl/${_endpoints['upload']!}');
    final headers = _buildHeaders();

    late final String name;
    late final http.MultipartFile multipartFile;

    if (params.filePath != null) {
      final file = File(params.filePath!);
      name = params.fileName ?? file.uri.pathSegments.last;
      multipartFile = await http.MultipartFile.fromPath(
        'file',
        params.filePath!,
        filename: name,
      );
    } else {
      // base64 path — decode and build from bytes
      name = params.fileName ?? 'upload';
      final Uint8List bytes = base64Decode(
        _extractBase64Payload(params.fileData!),
      );
      multipartFile = http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: name,
        contentType: _uploadMediaType(params.mimeType),
      );
    }

    var lastProgressPercent = -1;
    void emitProgress(int percent) {
      final clampedPercent = percent.clamp(0, 100).toInt();
      if (clampedPercent == lastProgressPercent) return;
      lastProgressPercent = clampedPercent;
      params.onProgress?.call(clampedPercent);
    }

    final request =
        _ProgressMultipartRequest(
            'POST',
            url,
            onProgress: (bytesSent, totalBytes) {
              if (totalBytes <= 0) return;
              final percent = ((bytesSent / totalBytes) * 100).floor();
              final bucketedPercent = (percent ~/ 5) * 5;
              emitProgress(bucketedPercent);
            },
          )
          ..headers.addAll(headers)
          ..fields['formId'] = params.feedbackConfigurationId
          ..fields['questionId'] = params.questionId
          ..files.add(multipartFile);

    _logger.debug('Uploading file: $name');

    final streamedResponse = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Encatch upload error: status ${response.statusCode} — ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final result = UploadFileResponse.fromJson(decoded);
    _logger.debug('Upload complete: ${result.fileUrl}');

    emitProgress(100);
    return result;
  }

  // ============================================================================
  // Q&A with AI (streaming)
  // ============================================================================

  /// Streams a Q&A with AI response for a form question.
  ///
  /// Returns the accumulated [QnaWithAiResponse] once the stream completes.
  /// Use the [onChunk] parameter to receive incremental text deltas as they
  /// arrive (useful for typing-indicator UIs).
  static Future<QnaWithAiResponse> streamQnaWithAi(
    QnaWithAiRequest params, {
    void Function(String chunk)? onChunk,
  }) async {
    if (!_initialized) throw StateError('Encatch SDK is not initialized');

    final url = Uri.parse('$_apiBaseUrl/${_endpoints['qnaWithAiStream']!}');
    final headers = {..._buildHeaders(), 'Accept': 'text/event-stream'};

    final request = http.Request('POST', url)
      ..headers.addAll(headers)
      ..body = jsonEncode(params.toJson());

    final streamedResponse = await _httpClient.send(request);

    if (streamedResponse.statusCode < 200 ||
        streamedResponse.statusCode >= 300) {
      final body = await streamedResponse.stream.bytesToString();
      throw Exception(
        'Encatch Q&A stream error: status ${streamedResponse.statusCode} — $body',
      );
    }

    final buffer = StringBuffer();
    await for (final chunk in streamedResponse.stream.transform(
      const SystemEncoding().decoder,
    )) {
      for (final line in chunk.split('\n')) {
        if (line.startsWith('data: ')) {
          final data = line.substring(6).trim();
          if (data == '[DONE]') break;
          try {
            final parsed = jsonDecode(data) as Map<String, dynamic>;
            final delta =
                parsed['chunk'] as String? ?? parsed['answer'] as String? ?? '';
            if (delta.isNotEmpty) {
              buffer.write(delta);
              onChunk?.call(delta);
            }
          } catch (_) {
            // malformed chunk — skip
          }
        }
      }
    }

    return QnaWithAiResponse(answer: buffer.toString());
  }

  // ============================================================================
  // Clear all — full storage wipe
  // ============================================================================

  /// Wipes **all** persisted SDK data and resets all in-memory state.
  ///
  /// Stronger than [resetUser] — also clears session-stopped state and device
  /// preferences. Equivalent to a factory reset of the SDK. The SDK remains
  /// initialized; call [identifyUser] to re-identify the user afterward.
  static Future<void> clearAll() async {
    _stopPingInterval();
    _dismissFormController.add(const DismissPayload());
    _isFormVisible = false;

    await Future.wait([
      if (_userName != null) ...[
        clearUserId(_userName!),
        clearFeedbackTransactions(_userName!),
      ],
      clearFeedbackTransactions('anonymous'),
      clearUserName(),
      clearPreferences(),
      clearSession(),
      clearSessionStopped(),
    ]);

    _userName = null;
    _userId = null;
    _userSignature = null;
    _feedbackTransactions = null;
    _locale = null;
    _country = null;
    _isSessionPaused = false;
    _isSessionStopped = false;
    _sessionId = await getOrCreateSessionId();

    _logger.debug('clearAll: SDK storage wiped and state reset');
  }

  // ============================================================================
  // Pre-fill responses
  // ============================================================================

  /// Pre-fills a response for [questionId] with [value] before showing a form.
  ///
  /// [questionId] may be a question UUID or a question slug. When a slug is
  /// provided the embedded form engine resolves it to the matching question ID
  /// automatically before applying the pre-filled value.
  static void addToResponse(String questionId, dynamic value) {
    _pendingResponses[questionId] = value;
  }

  static Map<String, dynamic> getPendingResponses() {
    return Map<String, dynamic>.from(_pendingResponses);
  }

  static void clearPendingResponses() {
    _pendingResponses.clear();
  }

  // ============================================================================
  // Form visibility
  // ============================================================================

  static void setFormVisible(bool visible) {
    _isFormVisible = visible;
  }

  // ============================================================================
  // Track form lifecycle events (fire-and-forget)
  // ============================================================================

  static Future<void> trackFormEvent(
    String eventName,
    String? formConfigurationId,
  ) async {
    try {
      final deviceInfo = await _buildDeviceInfo();
      final req = TrackEventRequest(
        eventName: eventName,
        feedbackConfigurationId: formConfigurationId,
        deviceInfo: deviceInfo,
        feedbackTransactions: _feedbackTransactions,
      );
      await _post<TrackEventResponse>(
        _endpoints['trackEvent']!,
        req.toJson(),
        TrackEventResponse.fromJson,
      );
    } catch (_) {
      // fire-and-forget
    }
  }

  // ============================================================================
  // External event callbacks
  // ============================================================================

  /// Subscribe to SDK events. Returns an unsubscribe function.
  /// Subscribes to SDK lifecycle events.
  ///
  /// Returns an unsubscribe function — call it to stop listening.
  ///
  /// ```dart
  /// final unsubscribe = Encatch.on((eventType, payload) {
  ///   print('Event: $eventType');
  /// });
  /// // Later:
  /// unsubscribe();
  /// ```
  static void Function() on(EventCallback callback) {
    _eventCallbacks.add(callback);
    return () => off(callback);
  }

  static void off(EventCallback callback) {
    _eventCallbacks.remove(callback);
  }

  static void emitEvent(EventType eventType, EventPayload payload) {
    final withTimestamp = EventPayload(
      formId: payload.formId,
      timestamp: payload.timestamp != 0
          ? payload.timestamp
          : DateTime.now().millisecondsSinceEpoch,
      data: payload.data,
    );
    for (final cb in List<EventCallback>.from(_eventCallbacks)) {
      try {
        cb(eventType, withTimestamp);
      } catch (_) {
        // ignore callback errors
      }
    }
  }

  // ============================================================================
  // Stop
  // ============================================================================

  static void stop() {
    _stopPingInterval();
    queue.stopAppLifecycleListener();
  }

  // ============================================================================
  // Internal: build device info
  // ============================================================================

  static Future<ApiDeviceInfo> _buildDeviceInfo({String? screenName}) async {
    final platform = getPlatform();
    final osVersion = await getOsVersion();
    final deviceLocale = getDeviceLocale();
    final timezone = getTimezone();

    String themeString;
    switch (_theme) {
      case EncatchTheme.light:
        themeString = 'light';
      case EncatchTheme.dark:
        themeString = 'dark';
      case EncatchTheme.system:
        themeString = 'system';
    }

    return ApiDeviceInfo(
      deviceOs: platform,
      deviceVersion: osVersion,
      deviceOsVersion: osVersion,
      deviceType: getDeviceTypeEnv(),
      sdkVersion: _sdkVersion,
      appVersion: _appVersion,
      app: _appPackageName,
      deviceLanguage: deviceLocale,
      userLanguage: _locale ?? deviceLocale,
      countryCode: _country,
      preferredTheme: themeString,
      timezone: timezone,
      urlOrScreenName: screenName ?? _currentScreen,
    );
  }

  // ============================================================================
  // Internal: handle response meta fields
  // ============================================================================

  static void _handleResponseMeta({
    String? formConfigurationId,
    int? pingAgainIn,
    String? feedbackTransactions,
  }) {
    if (pingAgainIn != null && pingAgainIn > 0) {
      _pingIntervalMs = pingAgainIn * 1000;
      _startPingInterval();
    }
  }

  // ============================================================================
  // Internal: build common request headers
  // ============================================================================

  static Map<String, String> _buildHeaders({String? signatureTime}) {
    return <String, String>{
      'Content-Type': 'application/json',
      'X-Api-Key': _apiKey ?? '',
      if (_sessionId != null) 'X-Session-Id': _sessionId!,
      if (_userName != null) 'X-User-Name': _userName!,
      if (_userId != null) 'X-User-Id': _userId!,
      if (_userSignature != null) 'X-User-Signature': _userSignature!,
      if (_deviceId != null) 'X-Device-Id': _deviceId!,
      if (signatureTime != null) 'X-User-Signature-Time': signatureTime,
      if (_appPackageName != null) 'Referer': _appPackageName!,
    };
  }

  // ============================================================================
  // Internal: HTTP POST
  // ============================================================================

  static Future<T> _post<T>(
    String endpoint,
    Map<String, dynamic> body,
    T Function(Map<String, dynamic>) fromJson, {
    String? signatureTime,
  }) async {
    final url = Uri.parse('$_apiBaseUrl/$endpoint');

    final headers = _buildHeaders(signatureTime: signatureTime);

    final stopwatch = Stopwatch()..start();
    Object? requestError;
    http.Response? response;

    try {
      response = await _httpClient.post(
        url,
        headers: headers,
        body: jsonEncode(body),
      );
    } catch (e) {
      requestError = e;
    }

    stopwatch.stop();

    _logger.requestResponse(
      method: 'POST',
      url: url.toString(),
      requestHeaders: headers,
      requestBody: body,
      durationMs: stopwatch.elapsedMilliseconds,
      statusCode: response?.statusCode,
      responseHeaders: response?.headers,
      responseBody: response?.body,
      error: requestError,
    );

    if (requestError != null) throw requestError;
    if (response!.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Encatch API error: status ${response.statusCode} — ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return fromJson(decoded);
  }
}
