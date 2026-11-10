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
import 'form_presentation_registry.dart';
import 'http_error.dart';
import 'internals.dart' as internals;
import 'logger.dart';
import 'pending_completion_cta.dart';
import 'rate_limit.dart' as rate;
import 'retry_queue.dart' as queue;
import 'storage.dart';
import 'types.dart';

// ============================================================================
// SDK version
// ============================================================================

const _sdkVersion = '1.1.2';

/// submit-form attempts in all when the API answers 429.
const _submitAttemptsOn429 = 3;

/// Identical trackEvent / trackScreen calls closer together than this are sent
/// once.
const _collapseWindowMs = 1000;

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
  static const String _defaultApiBaseUrl = 'https://api.encatch.com';
  static const String _defaultWebHost = 'https://form.encatch.com';
  static String _apiBaseUrl = _defaultApiBaseUrl;
  static String _webHost = _defaultWebHost;
  static bool _isFullScreen = false;

  // Identity
  static String? _userName;
  static String? _userId;
  static String? _userSignature;

  // Secure mode. The time the stored signature was signed for (keys with a
  // session time); whether that signature has expired; and what is waiting for
  // the next successful identify.
  static String? _userSignatureTime;
  static bool _signatureExpired = false;
  static Completer<void>? _identifiedAgain;

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

  // Deduplication. The last identify sent or in flight; when each event name
  // was last tracked; the last screen tracked and when.
  static String? _lastIdentifyKey;
  static final Map<String, int> _lastEventAt = {};
  static String? _lastTrackedScreen;
  static int _lastTrackedScreenAt = 0;

  // Survey guard. The form whose show-form request is in flight; the form
  // that is on screen (as asked for, and as the server named it); and the one
  // delayed automatic show that may be waiting.
  static String? _loadingFormId;
  static String? _openFormRequestedId;
  static String? _openFormConfigId;
  static Timer? _pendingAutoShow;

  // A screen tracked before init finished; sent as soon as it has.
  static String? _screenBeforeInit;

  // The latest identifyUser call made during a 429 pause, sent when it ends.
  static Future<void> Function()? _heldIdentify;
  static void Function()? _removePauseListener;

  // Pending pre-fill responses
  static final Map<String, dynamic> _pendingResponses = {};

  // Logger
  static EncatchLogger _logger = const EncatchLogger(debugMode: false);

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
    internals.resetSdkForTest = _resetForTest;
    internals.autoTrackScreen = _trackScreenAutomatically;
    _debugMode = config?.debugMode ?? false;
    _logger = EncatchLogger(debugMode: _debugMode);
    internals.sdkLogger = _logger;

    if (_initialized) {
      _logger.debug('SDK already initialized');
      return;
    }

    _apiKey = apiKey;

    _apiBaseUrl = (config?.apiBaseUrl ?? _defaultApiBaseUrl).replaceAll(
      RegExp(r'/+$'),
      '',
    );
    _webHost = (config?.webHost ?? _defaultWebHost).replaceAll(
      RegExp(r'/+$'),
      '',
    );
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
      final signed = await getUserSignature(storedName);
      _userSignature = signed?.signature;
      _userSignatureTime = signed?.time;
      _feedbackTransactions = await getFeedbackTransactions(storedName);
    } else {
      _feedbackTransactions = await getFeedbackTransactions('anonymous');
    }

    // A session stopped in an earlier run of the app stays stopped.
    _isSessionStopped = await getSessionStopped();
    internals.sessionStopped = _isSessionStopped;

    _initialized = true;

    // Start retry queue lifecycle listener
    queue.startAppLifecycleListener();
    _removePauseListener ??= rate.onPauseEnd(_onPauseEnd);

    // The first screen is usually pushed before init has finished.
    final screenBeforeInit = _screenBeforeInit;
    _screenBeforeInit = null;
    if (screenBeforeInit != null) {
      if (_isSessionStopped) {
        _currentScreen = screenBeforeInit;
      } else {
        trackScreen(screenBeforeInit).catchError((_) {});
      }
    }

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

    // During a 429 pause the call is held, not dropped, so a sign-in is not
    // lost. Only the latest call is kept; it is sent when the pause ends.
    if (rate.isPaused(rate.Bucket.tracking)) {
      _heldIdentify = () =>
          identifyUser(userName, traits: traits, options: options);
      return;
    }

    // An identify with the same user, traits, locale, country and signature
    // as the last one sent or in flight is skipped.
    final identifyKey = _identifyKey(userName, traits, options);
    if (identifyKey != null && identifyKey == _lastIdentifyKey) return;
    _lastIdentifyKey = identifyKey;

    return _serialized(
      () => _identifyNow(userName, traits, options, identifyKey),
    );
  }

  /// Runs identity changes one after the other, so a `resetUser()` followed
  /// straight away by `identifyUser()`, neither awaited, ends as that user.
  static Future<void> _identityLock = Future<void>.value();

  static Future<void> _serialized(Future<void> Function() change) {
    final previous = _identityLock;
    final done = Completer<void>();
    _identityLock = done.future;
    return previous.then((_) => change()).whenComplete(done.complete);
  }

  static Future<void> _identifyNow(
    String userName,
    UserTraits? traits,
    IdentifyOptions? options,
    String? identifyKey,
  ) async {
    final secure = options?.secure;
    final previousUser = _userName;
    if (previousUser != null && previousUser != userName) {
      // A user switch: the previous user's signature goes with them.
      _userSignature = null;
      _userSignatureTime = null;
      await clearUserSignature(previousUser);
    }
    if (secure == null) {
      // Identifying without a signature clears a stored one. With one, the
      // stored signature is replaced only when this identify succeeds.
      _userSignature = null;
      _userSignatureTime = null;
      await clearUserSignature(userName);
    }

    _userName = userName;
    // The id saved for this user, if there is one. Never another user's: the
    // server rejects a name sent with an id that isn't its own.
    _userId = await getUserId(userName);
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
      userSignature: secure?.signature,
      deviceInfo: deviceInfo,
      userAttributes: processedTraits,
      feedbackTransactions: _feedbackTransactions,
    );

    queue.enqueue(
      'identifyUser',
      () async {
        // IdentifyUserResponse is a public type and stays as it is; the
        // survey fields are read from the reply itself.
        var raw = const <String, dynamic>{};
        final res = await _post<IdentifyUserResponse>(
          _endpoints['identifyUser']!,
          req.toJson(),
          (json) {
            raw = json;
            return IdentifyUserResponse.fromJson(json);
          },
          signatureTime: secure?.generatedDateTimeinUTC,
          identifyAs: userName,
          identifySignature: secure?.signature,
        );
        // A late reply: the app has reset or identified someone else since.
        if (_userName != userName) return;
        if (secure != null) {
          // From now on the signature goes on every request for this user.
          _userSignature = secure.signature;
          _userSignatureTime = secure.generatedDateTimeinUTC;
          await setUserSignature(
            userName,
            secure.signature,
            secure.generatedDateTimeinUTC,
          );
        }
        _signatureExpired = false;
        final waiting = _identifiedAgain;
        _identifiedAgain = null;
        waiting?.complete();
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
        await _handleSurveyInReply(
          nextFeedbackId: raw['nextFeedbackId'] as String?,
          onPageDelay: (raw['onPageDelay'] as num?)?.toInt(),
          formConfigurationId: res.formConfigurationId,
        );
        await startSession(
          options: const StartSessionOptions(
            skipImmediatePing: true,
            skipImmediateTrackScreen: true,
          ),
        );
      },
      onDropped: () {
        // The server never accepted it, so the same call must be sent again.
        if (_lastIdentifyKey == identifyKey) _lastIdentifyKey = null;
      },
    );

    queue.flush().catchError((_) {});
  }

  /// A stable text form of an identify call, for spotting repeats. Null when
  /// the traits can't be encoded, in which case the call is never skipped.
  static String? _identifyKey(
    String userName,
    UserTraits? traits,
    IdentifyOptions? options,
  ) {
    Map<String, dynamic>? plain(Map<String, dynamic>? map) => map?.map(
      (k, v) => MapEntry(k, v is DateTime ? v.toIso8601String() : v),
    );
    try {
      return jsonEncode([
        userName,
        plain(traits?.set),
        plain(traits?.setOnce),
        traits?.increment,
        traits?.decrement,
        traits?.unset,
        options?.locale,
        options?.country,
        options?.secure?.signature,
        options?.secure?.generatedDateTimeinUTC,
      ]);
    } catch (_) {
      return null;
    }
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
    if (_backgroundPaused) return;

    // Identical events within the window are sent once.
    final now = internals.nowMs();
    final lastAt = _lastEventAt[eventName];
    if (lastAt != null && now - lastAt < _collapseWindowMs) return;
    if (_lastEventAt.length > 100) {
      _lastEventAt.removeWhere((_, at) => now - at >= _collapseWindowMs);
    }
    _lastEventAt[eventName] = now;

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
      await _handleSurveyInReply(
        nextFeedbackId: res.nextFeedbackId,
        onPageDelay: res.onPageDelay,
        formConfigurationId: res.formConfigurationId,
      );
    });

    queue.flush().catchError((_) {});
  }

  /// Tracks a screen navigation to [screenName] and checks for matching form triggers.
  static Future<void> trackScreen(String screenName) async {
    if (!_initialized) {
      // Remembered, and sent once init has finished.
      _screenBeforeInit = screenName;
      return;
    }
    if (_isFullScreen) return;

    _currentScreen = screenName;
    if (_backgroundPaused) return;

    // The same screen tracked again within the window is sent once. A visit
    // away and back (A, B, A) is tracked in full.
    final now = internals.nowMs();
    if (screenName == _lastTrackedScreen &&
        now - _lastTrackedScreenAt < _collapseWindowMs) {
      return;
    }
    _lastTrackedScreen = screenName;
    _lastTrackedScreenAt = now;

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
      await _handleSurveyInReply(
        nextFeedbackId: res.nextFeedbackId,
        onPageDelay: res.onPageDelay,
        formConfigurationId: res.formConfigurationId,
      );
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

  /// True while a survey's show-form request is in flight or a survey is on
  /// screen, modal or inline.
  static bool get _surveyBusy => _loadingFormId != null || _isFormVisible;

  static bool _isLoadingOrOpen(String formId) =>
      _loadingFormId == formId ||
      (_isFormVisible &&
          (formId == _openFormRequestedId || formId == _openFormConfigId));

  /// A survey the server chose in a reply: `nextFeedbackId` with `onPageDelay`
  /// seconds to wait, or `formConfigurationId` from an older server. Ignored
  /// while a survey is loading, open or already waiting to show.
  static Future<void> _handleSurveyInReply({
    String? nextFeedbackId,
    int? onPageDelay,
    String? formConfigurationId,
  }) async {
    final formId = formConfigurationId ?? nextFeedbackId;
    if (formId == null) return;
    if (_surveyBusy || _pendingAutoShow != null) return;

    final delay = formConfigurationId != null ? 0 : (onPageDelay ?? 0);
    if (delay <= 0) {
      await _showFormInternal(formId, triggerType: TriggerType.automatic);
      return;
    }
    _pendingAutoShow = Timer(Duration(seconds: delay), () {
      _pendingAutoShow = null;
      _showFormInternal(
        formId,
        triggerType: TriggerType.automatic,
      ).catchError((_) {});
    });
  }

  static void _cancelPendingAutoShow() {
    _pendingAutoShow?.cancel();
    _pendingAutoShow = null;
  }

  static Future<void> _showFormInternal(
    String formId, {
    ShowFormOptions? options,
    TriggerType triggerType = TriggerType.manual,
  }) async {
    if (!_initialized) return;
    if (rate.isPaused(rate.Bucket.showForm)) return;

    // An automatic survey never interrupts one that is loading or open. A
    // manual show of the form that is already loading or open is ignored, so
    // answers in progress are kept; a different form still replaces it.
    if (triggerType == TriggerType.automatic) {
      if (_surveyBusy || _signatureExpired) return;
    } else if (_isLoadingOrOpen(formId)) {
      return;
    }

    _loadingFormId = formId;
    try {
      await _loadAndPresentForm(
        formId,
        options: options,
        triggerType: triggerType,
      );
    } finally {
      // The presenters hear about a new form in microtasks queued when it is
      // announced. This one runs after them, so "loading" lasts until a
      // presenter has had the chance to mark the form visible.
      scheduleMicrotask(() {
        if (_loadingFormId == formId) _loadingFormId = null;
      });
    }
  }

  static Future<void> _loadAndPresentForm(
    String formId, {
    ShowFormOptions? options,
    required TriggerType triggerType,
  }) async {
    PendingCompletionCtaScheduler.cancel(formId);

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
      // 404 means "not eligible now" and 429 has already logged its pause;
      // neither is a problem for the host app to see.
      final status = httpStatusOf(e);
      if (status == 404 || status == 429) {
        _logger.debug('showForm skipped for $formId: $e');
      } else {
        _logger.warn('showForm failed for $formId: $e');
      }
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

    final target = resolvePresentationTarget(
      formId: res.feedbackConfigurationId,
      formConfig: res,
    );

    PendingCompletionCtaScheduler.cancel(res.feedbackConfigurationId);

    _openFormRequestedId = formId;
    _openFormConfigId = res.feedbackConfigurationId;
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
        presentation: target is InlineTarget
            ? FormPresentation.inline
            : FormPresentation.modal,
        inlineSlotId: target is InlineTarget ? target.slotId : null,
      ),
    );
    // Note: setFormVisible(true) is called by each presenter independently
    // after it confirms it will display the form, not here.
  }

  static Future<void> dismissForm({String? formConfigurationId}) async {
    if (formConfigurationId != null) {
      PendingCompletionCtaScheduler.cancel(formConfigurationId);
    } else {
      PendingCompletionCtaScheduler.cancelAll();
    }

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

    // A submit carries the user's answers, so it is never dropped for a 429:
    // it waits for the pause to end and is tried up to three times.
    // After a secure signature has expired it is held until the app has
    // identified again, then sent.
    late final SubmitFormResponse res;
    var heldForSignature = false;
    for (var attempt = 1; ; attempt++) {
      await _untilSignatureIsFresh();
      await rate.waitUntilResumed(rate.Bucket.submitForm);
      try {
        res = await _post<SubmitFormResponse>(
          _endpoints['submitForm']!,
          body,
          SubmitFormResponse.fromJson,
        );
        break;
      } on EncatchHttpException catch (e) {
        if (e.status == 401 && _signatureExpired && !heldForSignature) {
          heldForSignature = true;
          continue;
        }
        if (e.status != 429 || attempt >= _submitAttemptsOn429) rethrow;
      }
    }

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
    internals.sessionStopped = false;
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

  /// Stops the SDK's own activity: the background ping and
  /// [EncatchNavigatorObserver]'s automatic screen tracking. It also closes the
  /// open survey and cancels one that is waiting to show.
  ///
  /// The stop is saved, so it survives app restarts. It ends with
  /// [startSession] or a successful [identifyUser].
  ///
  /// While stopped, calls the app makes itself still go out ([trackScreen],
  /// [trackEvent], [identifyUser], [showForm] and submits), and a survey the
  /// server chooses in their replies is still shown. The current screen keeps
  /// updating, so it is tracked when the session starts again.
  static Future<void> stopSession() async {
    if (_isSessionStopped) return;
    _isSessionStopped = true;
    internals.sessionStopped = true;
    _isSessionPaused = false;
    _stopPingInterval();
    _cancelPendingAutoShow();
    _dismissFormController.add(const DismissPayload());
    setFormVisible(false);
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
    if (_backgroundPaused) return;

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
        if (_isPingActive) _startPingInterval();
      }

      await _handleSurveyInReply(
        nextFeedbackId: res.nextFeedbackId,
        onPageDelay: res.onPageDelay,
        formConfigurationId: res.formConfigurationId,
      );
    } catch (_) {
      // Ignored: the next ping comes on the interval.
    }
  }

  // ============================================================================
  // Reset user
  // ============================================================================

  /// Resets the current user's identity and clears persisted data.
  static Future<void> resetUser() => _serialized(_resetUserNow);

  static Future<void> _resetUserNow() async {
    final prevUserName = _userName;
    final prevUserId = _userId;
    _heldIdentify = null;
    _lastIdentifyKey = null;

    if (prevUserName != null) {
      await clearUserId(prevUserName);
      await clearUserSignature(prevUserName);
      await clearFeedbackTransactions(prevUserName);
    }
    await clearFeedbackTransactions('anonymous');
    await clearUserName();
    await clearPreferences();
    await clearSession();

    _userName = null;
    _userId = null;
    _userSignature = null;
    _userSignatureTime = null;
    _signatureExpired = false;
    _feedbackTransactions = null;
    _locale = null;
    _country = null;
    _sessionId = await getOrCreateSessionId();

    // Reset session control flags, including a saved stop
    _isSessionPaused = false;
    _isSessionStopped = false;
    internals.sessionStopped = false;
    await clearSessionStopped();

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

    final streamedResponse = await internals.sdkHttpClient.send(request);
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

    final streamedResponse = await internals.sdkHttpClient.send(request);

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
  static Future<void> clearAll() => _serialized(_clearAllNow);

  static Future<void> _clearAllNow() async {
    _stopPingInterval();
    _dismissFormController.add(const DismissPayload());
    _isFormVisible = false;
    _heldIdentify = null;
    _lastIdentifyKey = null;
    _cancelPendingAutoShow();
    rate.clearPauses();

    await Future.wait([
      if (_userName != null) ...[
        clearUserId(_userName!),
        clearUserSignature(_userName!),
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
    _userSignatureTime = null;
    _signatureExpired = false;
    _feedbackTransactions = null;
    _locale = null;
    _country = null;
    _isSessionPaused = false;
    _isSessionStopped = false;
    internals.sessionStopped = false;
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
    if (!visible) {
      // Closed, completed, dismissed or its slot went away: the next survey
      // may show.
      _openFormRequestedId = null;
      _openFormConfigId = null;
    }
  }

  // ============================================================================
  // Track form lifecycle events (fire-and-forget)
  // ============================================================================

  static Future<void> trackFormEvent(
    String eventName,
    String? formConfigurationId,
  ) async {
    if (_backgroundPaused) return;
    // Survey events are sent for identified users only: the server answers a
    // visitor's with 403. That covers the time before a new user's first
    // identify reply, when requests still go out as a visitor.
    if (_userName == null || _userId == null) return;
    try {
      final deviceInfo = await _buildDeviceInfo();
      final req = TrackEventRequest(
        eventName: eventName,
        feedbackConfigurationId: formConfigurationId,
        deviceInfo: deviceInfo,
        feedbackTransactions: _feedbackTransactions,
      );
      final res = await _post<TrackEventResponse>(
        _endpoints['trackEvent']!,
        req.toJson(),
        TrackEventResponse.fromJson,
      );
      // Ignored while this survey is open; the guard sees to that.
      await _handleSurveyInReply(
        nextFeedbackId: res.nextFeedbackId,
        onPageDelay: res.onPageDelay,
        formConfigurationId: res.formConfigurationId,
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
    PendingCompletionCtaScheduler.cancelAll();
    _stopPingInterval();
    queue.stopAppLifecycleListener();
  }

  // ============================================================================
  // Internal: automatic screen tracking (EncatchNavigatorObserver)
  // ============================================================================

  /// A screen reported by the navigator observer. While the session is stopped
  /// it is remembered, so `startSession()` can send it, but not sent.
  static void _trackScreenAutomatically(String screenName) {
    if (_isSessionStopped) {
      _currentScreen = screenName;
      return;
    }
    trackScreen(screenName).catchError((_) {});
  }

  // ============================================================================
  // Internal: 429 pause
  // ============================================================================

  /// True while background traffic (events, screens, survey events, ping)
  /// must not be sent: during a 429 pause, and after a secure signature has
  /// expired until the app identifies again.
  static bool get _backgroundPaused =>
      rate.isPaused(rate.Bucket.tracking) || _signatureExpired;

  /// When a tracking pause ends: send the identify held during it, then the
  /// calls that were already in the queue.
  static void _onPauseEnd(rate.Bucket bucket) {
    if (bucket != rate.Bucket.tracking) return;
    final held = _heldIdentify;
    _heldIdentify = null;
    if (held != null) held().catchError((_) {});
    queue.flush().catchError((_) {});
  }

  // ============================================================================
  // Internal: reset for the SDK's own tests (reached through internals.dart)
  // ============================================================================

  static Future<void> _resetForTest() async {
    PendingCompletionCtaScheduler.cancelAll();
    _stopPingInterval();
    queue.stopAppLifecycleListener();
    queue.clearForTest();
    rate.clearPauses();
    rate.clearListenersForTest();
    _removePauseListener = null;
    _heldIdentify = null;
    _lastIdentifyKey = null;
    _lastEventAt.clear();
    _lastTrackedScreen = null;
    _lastTrackedScreenAt = 0;
    _screenBeforeInit = null;
    _cancelPendingAutoShow();
    _loadingFormId = null;
    _openFormRequestedId = null;
    _openFormConfigId = null;
    // A fresh lock: one left over from an earlier test belongs to that test's
    // fake clock and would never complete.
    _identityLock = Future<void>.value();
    _userSignatureTime = null;
    _signatureExpired = false;
    _identifiedAgain = null;
    await clearSession();

    _initialized = false;
    _debugMode = false;
    _apiKey = null;
    _apiBaseUrl = _defaultApiBaseUrl;
    _webHost = _defaultWebHost;
    _isFullScreen = false;
    _userName = null;
    _userId = null;
    _userSignature = null;
    _locale = null;
    _country = null;
    _theme = EncatchTheme.system;
    _currentScreen = null;
    _deviceId = null;
    _sessionId = null;
    _feedbackTransactions = null;
    _pingIntervalMs = 30000;
    _isFormVisible = false;
    _isSessionPaused = false;
    _isSessionStopped = false;
    internals.sessionStopped = false;
    _appVersion = '1.0.0';
    _appPackageName = null;
    _eventCallbacks.clear();
    _onBeforeShowForm = null;
    _pendingResponses.clear();
    _logger = const EncatchLogger(debugMode: false);
    internals.sdkLogger = _logger;
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
      // Only while pinging is active: a reply must not restart a ping the app
      // stopped or paused.
      if (_isPingActive) _startPingInterval();
    }
  }

  // ============================================================================
  // Internal: build common request headers
  // ============================================================================

  ///
  /// The identity headers go out both or neither: the server answers 401 to a
  /// name without an id, or an id without a name. Until an identify reply has
  /// given this user's id, requests are sent as a visitor.
  ///
  /// identify-user is the exception ([identifyAs]): it carries the name of the
  /// user that call identifies, taken from the call itself, and never an id.
  static Map<String, String> _buildHeaders({
    String? signatureTime,
    String? identifyAs,
    String? identifySignature,
  }) {
    final identified =
        identifyAs == null && _userName != null && _userId != null;
    // Secure mode. identify-user carries the signature that call was given.
    // Every other request carries the one stored by the last successful
    // secure identify, and only together with both identity headers: never on
    // a visitor's request. The time goes out under both header names: the
    // gateway reads X-User-Session-Time and is being changed to also accept
    // X-User-Signature-Time.
    final signature = identifyAs != null
        ? identifySignature
        : (identified ? _userSignature : null);
    final time = identifyAs != null ? signatureTime : _userSignatureTime;
    return <String, String>{
      'Content-Type': 'application/json',
      'X-Api-Key': _apiKey ?? '',
      if (_sessionId != null) 'X-Session-Id': _sessionId!,
      if (identifyAs != null) 'X-User-Name': identifyAs,
      if (identified) 'X-User-Name': _userName!,
      if (identified) 'X-User-Id': _userId!,
      if (signature != null) 'X-User-Signature': signature,
      if (_deviceId != null) 'X-Device-Id': _deviceId!,
      if (signature != null && time != null) 'X-User-Session-Time': time,
      if (signature != null && time != null) 'X-User-Signature-Time': time,
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
    String? identifyAs,
    String? identifySignature,
  }) async {
    final url = Uri.parse('$_apiBaseUrl/$endpoint');

    final headers = _buildHeaders(
      signatureTime: signatureTime,
      identifyAs: identifyAs,
      identifySignature: identifySignature,
    );

    final stopwatch = Stopwatch()..start();
    Object? requestError;
    http.Response? response;

    try {
      // A request that never answers must not block the retry queue. A
      // timeout is handled like any other network failure.
      response = await internals.sdkHttpClient
          .post(url, headers: headers, body: jsonEncode(body))
          .timeout(internals.requestTimeout);
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
      final retryAfterMs = parseRetryAfter(
        response.headers['retry-after'],
        internals.nowMs(),
      );
      if (response.statusCode == 429) {
        rate.pauseFor(rate.bucketOf(endpoint), retryAfterMs);
      }
      // A 401 on a request that carried a timed signature: it has expired.
      if (response.statusCode == 401 &&
          identifyAs == null &&
          headers.containsKey('X-User-Session-Time')) {
        _onSignatureExpired(
          headers['X-User-Name'],
          headers['X-User-Signature'],
        );
      }
      throw EncatchHttpException(
        response.statusCode,
        response.body,
        retryAfterMs: retryAfterMs,
      );
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    // The server sends camelCase; the snake_case spelling is accepted too.
    if (decoded['userPendingRetryExhausted'] == true ||
        decoded['user_pending_retry_exhausted'] == true) {
      _onRetriesExhausted(headers['X-User-Name']);
    }
    return fromJson(decoded);
  }

  /// The stored secure signature has passed its session time. It is dropped,
  /// and background traffic stops until the app identifies again with a fresh
  /// one, so the SDK doesn't send a stream of requests that all get 401.
  static void _onSignatureExpired(String? sentAs, String? signature) {
    if (sentAs == null || sentAs != _userName) return;
    if (signature == null || signature != _userSignature) return;
    _userSignature = null;
    _userSignatureTime = null;
    _signatureExpired = true;
    clearUserSignature(sentAs).catchError((_) {});
    _logger.warn(
      'The secure signature for "$sentAs" has expired. Tracking is paused '
      'until identifyUser is called again with a fresh signature.',
    );
  }

  /// Completes at once unless a signature has expired, in which case it waits
  /// for the next successful identify.
  static Future<void> _untilSignatureIsFresh() async {
    if (!_signatureExpired) return;
    await (_identifiedAgain ??= Completer<void>()).future;
  }

  /// The server gave up waiting for this user to be created. The SDK resets
  /// the user, who is then a visitor until the app identifies again.
  static void _onRetriesExhausted(String? sentAs) {
    if (sentAs == null || sentAs != _userName) return;
    _logger.debug('User "$sentAs" could not be confirmed; resetting the user');
    _stopPingInterval();
    resetUser().catchError((_) {});
  }
}
