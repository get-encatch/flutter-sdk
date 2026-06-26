/// All shared Dart types and classes for the Encatch Flutter SDK.
/// Direct translation of types.ts from the React Native SDK.
library;

// ============================================================================
// Enums
// ============================================================================

/// The color theme to use when rendering forms.
enum EncatchTheme { light, dark, system }

/// Controls when the form response data is reset between form displays.
enum ResetMode {
  /// Reset on every form display.
  always,

  /// Reset only after the form is completed.
  onComplete,

  /// Never reset response data.
  never,
}

/// All supported question types in a form.
enum QuestionType {
  rating,
  singleChoice,
  nps,
  nestedSelection,
  multipleChoiceMultiple,
  shortAnswer,
  longText,
  annotation,
  welcome,
  thankYou,
  messagePanel,
  yesNo,
  ratingMatrix,
  matrixSingleChoice,
  matrixMultipleChoice,
  exitForm,
  consent,
  date,
  csat,
  opinionScale,
  ranking,
  pictureChoice,
  signature,
  fileUpload,
  email,
  number,
  website,
  phoneNumber,
  address,
  videoAudio,
  scheduler,
  qnaWithAi,
  paymentsUpi,
}

/// Extension on [QuestionType] for wire-format string serialization.
extension QuestionTypeExt on QuestionType {
  String get value {
    switch (this) {
      case QuestionType.rating:
        return 'rating';
      case QuestionType.singleChoice:
        return 'single_choice';
      case QuestionType.nps:
        return 'nps';
      case QuestionType.nestedSelection:
        return 'nested_selection';
      case QuestionType.multipleChoiceMultiple:
        return 'multiple_choice_multiple';
      case QuestionType.shortAnswer:
        return 'short_answer';
      case QuestionType.longText:
        return 'long_text';
      case QuestionType.annotation:
        return 'annotation';
      case QuestionType.welcome:
        return 'welcome';
      case QuestionType.thankYou:
        return 'thank_you';
      case QuestionType.messagePanel:
        return 'message_panel';
      case QuestionType.yesNo:
        return 'yes_no';
      case QuestionType.ratingMatrix:
        return 'rating_matrix';
      case QuestionType.matrixSingleChoice:
        return 'matrix_single_choice';
      case QuestionType.matrixMultipleChoice:
        return 'matrix_multiple_choice';
      case QuestionType.exitForm:
        return 'exit_form';
      case QuestionType.consent:
        return 'consent';
      case QuestionType.date:
        return 'date';
      case QuestionType.csat:
        return 'csat';
      case QuestionType.opinionScale:
        return 'opinion_scale';
      case QuestionType.ranking:
        return 'ranking';
      case QuestionType.pictureChoice:
        return 'picture_choice';
      case QuestionType.signature:
        return 'signature';
      case QuestionType.fileUpload:
        return 'file_upload';
      case QuestionType.email:
        return 'email';
      case QuestionType.number:
        return 'number';
      case QuestionType.website:
        return 'website';
      case QuestionType.phoneNumber:
        return 'phone_number';
      case QuestionType.address:
        return 'address';
      case QuestionType.videoAudio:
        return 'video_audio';
      case QuestionType.scheduler:
        return 'scheduler';
      case QuestionType.qnaWithAi:
        return 'qna_with_ai';
      case QuestionType.paymentsUpi:
        return 'payments_upi';
    }
  }

  static QuestionType? fromString(String value) {
    for (final type in QuestionType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// Events emitted by the SDK during the form lifecycle.
enum EventType {
  /// Fired when a form is shown.
  formShow,

  /// Fired when the user starts interacting with a form.
  formStarted,

  /// Fired when a form is submitted.
  formSubmit,

  /// Fired when a form is fully completed.
  formComplete,

  /// Fired when a form is closed.
  formClose,

  /// Fired when a form is dismissed without completion.
  formDismissed,

  /// Fired when an error occurs in the form.
  formError,

  /// Fired when the visible form section changes.
  formSectionChange,

  /// Fired when a question is answered.
  formAnswered,

  /// Fired when the user taps "Remind me later" in a form.
  formRemindMeLater,

  /// Fired when a completionCta action triggers on a thank_you or exit_form screen.
  ///
  /// [EventPayload.data] contains:
  /// - `action`: `'app_navigate'` | `'redirect_internal'` | `'redirect_external'`
  /// - `route` (app_navigate only): the host route to navigate to
  /// - `url` (redirect_* only): the URL that was opened
  /// - `surface`: always `'inApp'`
  /// - `trigger`: `'manual'` | `'auto'`
  ///
  /// For `app_navigate` the host should navigate to `data['route']` in an
  /// [Encatch.on] listener; the SDK closes the form overlay automatically after
  /// emitting this event (same UX as redirect/dismiss CTAs).
  /// For redirect actions the SDK opens the URL and the form closes automatically.
  formCtaTriggered,
}

/// How a form display was triggered.
enum TriggerType {
  /// Triggered automatically by the SDK (event/screen match).
  automatic,

  /// Triggered manually via [Encatch.showForm].
  manual,
}

// ============================================================================
// Config
// ============================================================================

/// Configuration options for the Encatch SDK.
///
/// Pass this to [EncatchProvider] or [Encatch.init] to customize SDK behavior.
///
/// ```dart
/// EncatchProvider(
///   apiKey: 'your-api-key',
///   config: EncatchConfig(
///     theme: EncatchTheme.dark,
///     debugMode: true,
///   ),
///   child: MyApp(),
/// )
/// ```
class EncatchConfig {
  /// Base URL for all API calls. Defaults to 'https://api.encatch.com'.
  final String? apiBaseUrl;

  /// Base URL for loading the flutter-sdk-form WebView page.
  /// Defaults to 'https://form.encatch.com'.
  final String? webHost;

  /// Default theme for forms. Defaults to EncatchTheme.system.
  final EncatchTheme? theme;

  /// When true, the form overlay is displayed full-screen.
  final bool? isFullScreen;

  /// Enable verbose SDK logging to the console.
  final bool? debugMode;

  /// Override app version (default: auto-detected from native app).
  final String? appVersion;

  /// Optional interceptor called before any form is shown.
  /// If it returns false, the SDK form will not open.
  final Future<bool> Function(ShowFormInterceptorPayload payload)?
  onBeforeShowForm;

  const EncatchConfig({
    this.apiBaseUrl,
    this.webHost,
    this.theme,
    this.isFullScreen,
    this.debugMode,
    this.appVersion,
    this.onBeforeShowForm,
  });
}

// ============================================================================
// Show form interceptor payload
// ============================================================================

/// Payload passed to [EncatchConfig.onBeforeShowForm].
///
/// Inspect this to decide whether to allow the form to be shown.
class ShowFormInterceptorPayload {
  final String formId;
  final ShowFormResponse formConfig;
  final ResetMode resetMode;
  final TriggerType triggerType;
  final Map<String, dynamic> prefillResponses;
  final String? locale;
  final EncatchTheme? theme;

  /// Serialized caller context ([DateTime] values already converted to ISO strings).
  final Map<String, Object>? context;

  const ShowFormInterceptorPayload({
    required this.formId,
    required this.formConfig,
    required this.resetMode,
    required this.triggerType,
    required this.prefillResponses,
    this.locale,
    this.theme,
    this.context,
  });
}

// ============================================================================
// Session options
// ============================================================================

/// Options for controlling SDK session start behavior.
class StartSessionOptions {
  final bool? skipImmediatePing;
  final bool? skipImmediateTrackScreen;

  const StartSessionOptions({
    this.skipImmediatePing,
    this.skipImmediateTrackScreen,
  });
}

// ============================================================================
// Show form options
// ============================================================================

/// Options for controlling form display behavior.
class ShowFormOptions {
  final ResetMode? reset;

  /// Arbitrary key-value pairs attached to the form submission.
  /// Useful for passing caller-side metadata (e.g. plan tier, feature flags).
  /// [DateTime] values are automatically serialized to ISO 8601 strings.
  final Map<String, Object>? context;

  const ShowFormOptions({this.reset, this.context});
}

// ============================================================================
// User identity
// ============================================================================

/// Describes changes to apply to a user's trait profile.
///
/// Only the fields you provide will be sent.
///
/// ```dart
/// await Encatch.identifyUser(
///   'user@example.com',
///   traits: UserTraits(
///     set: {'name': 'Alice', 'plan': 'pro'},
///     increment: {'loginCount': 1},
///   ),
/// );
/// ```
class UserTraits {
  /// Set user attributes (overwrites existing values).
  final Map<String, dynamic>? set;

  /// Set user attributes only if they don't already exist.
  final Map<String, dynamic>? setOnce;

  /// Increment numeric user attributes.
  final Map<String, num>? increment;

  /// Decrement numeric user attributes.
  final Map<String, num>? decrement;

  /// Remove user attributes (list of keys to unset).
  final List<String>? unset;

  const UserTraits({
    this.set,
    this.setOnce,
    this.increment,
    this.decrement,
    this.unset,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (set != null) map[r'$set'] = set;
    if (setOnce != null) map[r'$setOnce'] = setOnce;
    if (increment != null) map[r'$increment'] = increment;
    if (decrement != null) map[r'$decrement'] = decrement;
    if (unset != null) map[r'$unset'] = unset;
    return map;
  }
}

/// HMAC options for secure user identification.
class SecureOptions {
  final String signature;
  final String? generatedDateTimeinUTC;

  const SecureOptions({required this.signature, this.generatedDateTimeinUTC});
}

/// Additional options passed to [Encatch.identifyUser].
class IdentifyOptions {
  final String? locale;
  final String? country;
  final SecureOptions? secure;

  const IdentifyOptions({this.locale, this.country, this.secure});
}

// ============================================================================
// Events
// ============================================================================

/// Payload delivered to [EventCallback] listeners on every SDK event.
class EventPayload {
  final String? formId;
  final int timestamp;
  final Map<String, dynamic>? data;

  const EventPayload({this.formId, required this.timestamp, this.data});
}

/// Callback signature for SDK lifecycle events.
///
/// Register via [Encatch.on].
typedef EventCallback =
    void Function(EventType eventType, EventPayload payload);

// ============================================================================
// PostMessage protocol — form -> native (outbound from WebView)
// ============================================================================

/// Message types sent from the WebView form to the native SDK.
enum FormMessageType {
  formReady,
  formSubmit,
  formComplete,
  formClose,
  formError,
  formResize,
  formLayout,
  formCloseButton,
  formThemeData,
  formRefineTextRequest,
  formStarted,
  formAnswered,
  formSectionChange,
  formShow,
  formReadyToDismiss,
  formUploadFileRequest,
  formQnaWithAiRequest,
  formRemindMeLater,
  formCtaTriggered,
}

/// Extension on [FormMessageType] for string serialization/deserialization.
extension FormMessageTypeExt on FormMessageType {
  /// Returns the wire-format string for this message type.
  String get value {
    switch (this) {
      case FormMessageType.formReady:
        return 'form:ready';
      case FormMessageType.formSubmit:
        return 'form:submit';
      case FormMessageType.formComplete:
        return 'form:complete';
      case FormMessageType.formClose:
        return 'form:close';
      case FormMessageType.formError:
        return 'form:error';
      case FormMessageType.formResize:
        return 'form:resize';
      case FormMessageType.formLayout:
        return 'form:layout';
      case FormMessageType.formCloseButton:
        return 'form:closeButton';
      case FormMessageType.formThemeData:
        return 'form:themeData';
      case FormMessageType.formRefineTextRequest:
        return 'form:refineTextRequest';
      case FormMessageType.formStarted:
        return 'form:started';
      case FormMessageType.formAnswered:
        return 'form:answered';
      case FormMessageType.formSectionChange:
        return 'form:section:change';
      case FormMessageType.formShow:
        return 'form:show';
      case FormMessageType.formReadyToDismiss:
        return 'form:readyToDismiss';
      case FormMessageType.formUploadFileRequest:
        return 'form:uploadFileRequest';
      case FormMessageType.formQnaWithAiRequest:
        return 'form:qnaWithAiRequest';
      case FormMessageType.formRemindMeLater:
        return 'form:remindmelater';
      case FormMessageType.formCtaTriggered:
        return 'form:ctaTriggered';
    }
  }

  /// Parses a wire-format string into a [FormMessageType], or returns null.
  static FormMessageType? fromString(String value) {
    for (final type in FormMessageType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

// ============================================================================
// PostMessage protocol — native -> form (inbound to WebView)
// ============================================================================

/// Message types sent from the native SDK to the WebView form.
enum SdkMessageType {
  formConfig,
  theme,
  locale,
  resetData,
  prefillResponses,
  refineTextResponse,
  submitPartialBeforeDismiss,
  uploadFileResponse,
  uploadFileProgress,
  qnaWithAiResponse,
  qnaWithAiChunk,
  qnaWithAiDone,
}

/// Extension on [SdkMessageType] for wire-format string serialization.
extension SdkMessageTypeExt on SdkMessageType {
  /// Returns the wire-format string for this message type.
  String get value {
    switch (this) {
      case SdkMessageType.formConfig:
        return 'sdk:formConfig';
      case SdkMessageType.theme:
        return 'sdk:theme';
      case SdkMessageType.locale:
        return 'sdk:locale';
      case SdkMessageType.resetData:
        return 'sdk:resetData';
      case SdkMessageType.prefillResponses:
        return 'sdk:prefillResponses';
      case SdkMessageType.refineTextResponse:
        return 'sdk:refineTextResponse';
      case SdkMessageType.submitPartialBeforeDismiss:
        return 'sdk:submitPartialBeforeDismiss';
      case SdkMessageType.uploadFileResponse:
        return 'sdk:uploadFileResponse';
      case SdkMessageType.uploadFileProgress:
        return 'sdk:uploadFileProgress';
      case SdkMessageType.qnaWithAiResponse:
        return 'sdk:qnaWithAiResponse';
      case SdkMessageType.qnaWithAiChunk:
        return 'sdk:qnaWithAiChunk';
      case SdkMessageType.qnaWithAiDone:
        return 'sdk:qnaWithAiDone';
    }
  }
}

// ============================================================================
// API Device Info
// ============================================================================

/// Device and environment metadata attached to every API request.
class ApiDeviceInfo {
  final String? deviceOs;
  final String? deviceVersion;
  final String? deviceOsVersion;
  final String? deviceType;
  final String? deviceSize;
  final String? sdkVersion;
  final String? appVersion;
  final String? app;
  final String? deviceLanguage;
  final String? userLanguage;
  final String? countryCode;
  final String? preferredTheme;
  final String? timezone;
  final String? urlOrScreenName;

  const ApiDeviceInfo({
    this.deviceOs,
    this.deviceVersion,
    this.deviceOsVersion,
    this.deviceType,
    this.deviceSize,
    this.sdkVersion,
    this.appVersion,
    this.app,
    this.deviceLanguage,
    this.userLanguage,
    this.countryCode,
    this.preferredTheme,
    this.timezone,
    this.urlOrScreenName,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (deviceOs != null) map[r'$deviceOs'] = deviceOs;
    if (deviceVersion != null) map[r'$deviceVersion'] = deviceVersion;
    if (deviceOsVersion != null) map[r'$deviceOsVersion'] = deviceOsVersion;
    if (deviceType != null) map[r'$deviceType'] = deviceType;
    if (deviceSize != null) map[r'$deviceSize'] = deviceSize;
    if (sdkVersion != null) map[r'$sdkVersion'] = sdkVersion;
    if (appVersion != null) map[r'$appVersion'] = appVersion;
    if (app != null) map[r'$app'] = app;
    if (deviceLanguage != null) map[r'$deviceLanguage'] = deviceLanguage;
    if (userLanguage != null) map[r'$userLanguage'] = userLanguage;
    if (countryCode != null) map[r'$countryCode'] = countryCode;
    if (preferredTheme != null) map[r'$preferredTheme'] = preferredTheme;
    if (timezone != null) map[r'$timezone'] = timezone;
    if (urlOrScreenName != null) map[r'$urlOrScreenName'] = urlOrScreenName;
    return map;
  }
}

// ============================================================================
// API Request / Response types
// ============================================================================

class IdentifyUserRequest {
  final String? userName;
  final String? userId;
  final String? userSignature;
  final ApiDeviceInfo? deviceInfo;
  final UserTraits? userAttributes;
  final String? feedbackTransactions;

  const IdentifyUserRequest({
    this.userName,
    this.userId,
    this.userSignature,
    this.deviceInfo,
    this.userAttributes,
    this.feedbackTransactions,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (userName != null) map['userName'] = userName;
    if (userId != null) map['userId'] = userId;
    if (userSignature != null) map['userSignature'] = userSignature;
    if (deviceInfo != null) map[r'$deviceInfo'] = deviceInfo!.toJson();
    if (userAttributes != null) {
      map['userAttributes'] = userAttributes!.toJson();
    }
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

/// Response from the identify-user API endpoint.
class IdentifyUserResponse {
  final String message;
  final String? userId;
  final String? formConfigurationId;
  final int? pingAgainIn;
  final bool? pingOnNextPageVisit;
  final String? feedbackTransactions;

  const IdentifyUserResponse({
    required this.message,
    this.userId,
    this.formConfigurationId,
    this.pingAgainIn,
    this.pingOnNextPageVisit,
    this.feedbackTransactions,
  });

  factory IdentifyUserResponse.fromJson(Map<String, dynamic> json) {
    return IdentifyUserResponse(
      message: json['message'] as String? ?? '',
      userId: json['userId'] as String?,
      formConfigurationId: json['formConfigurationId'] as String?,
      pingAgainIn: json['pingAgainIn'] as int?,
      pingOnNextPageVisit: json['pingOnNextPageVisit'] as bool?,
      feedbackTransactions: json[r'$feedbackTransactions'] as String?,
    );
  }
}

class TrackEventRequest {
  final String eventName;
  final String? feedbackConfigurationId;
  final ApiDeviceInfo? deviceInfo;
  final String? feedbackTransactions;

  const TrackEventRequest({
    required this.eventName,
    this.feedbackConfigurationId,
    this.deviceInfo,
    this.feedbackTransactions,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'eventName': eventName};
    if (feedbackConfigurationId != null) {
      map['feedbackConfigurationId'] = feedbackConfigurationId;
    }
    if (deviceInfo != null) map[r'$deviceInfo'] = deviceInfo!.toJson();
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

class TrackEventResponse {
  final String message;
  final String? formConfigurationId;
  final int? pingAgainIn;
  final bool? pingOnNextPageVisit;
  final String? feedbackTransactions;

  const TrackEventResponse({
    required this.message,
    this.formConfigurationId,
    this.pingAgainIn,
    this.pingOnNextPageVisit,
    this.feedbackTransactions,
  });

  factory TrackEventResponse.fromJson(Map<String, dynamic> json) {
    return TrackEventResponse(
      message: json['message'] as String? ?? '',
      formConfigurationId: json['formConfigurationId'] as String?,
      pingAgainIn: json['pingAgainIn'] as int?,
      pingOnNextPageVisit: json['pingOnNextPageVisit'] as bool?,
      feedbackTransactions: json[r'$feedbackTransactions'] as String?,
    );
  }
}

class TrackScreenRequest {
  final ApiDeviceInfo? deviceInfo;
  final String? feedbackTransactions;

  const TrackScreenRequest({this.deviceInfo, this.feedbackTransactions});

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (deviceInfo != null) map[r'$deviceInfo'] = deviceInfo!.toJson();
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

class TrackScreenResponse {
  final String message;
  final String? formConfigurationId;
  final String? nextFeedbackId;
  final int? onPageDelay;
  final int? pingAgainIn;
  final bool? pingOnNextPageVisit;
  final String? feedbackTransactions;

  const TrackScreenResponse({
    required this.message,
    this.formConfigurationId,
    this.nextFeedbackId,
    this.onPageDelay,
    this.pingAgainIn,
    this.pingOnNextPageVisit,
    this.feedbackTransactions,
  });

  factory TrackScreenResponse.fromJson(Map<String, dynamic> json) {
    return TrackScreenResponse(
      message: json['message'] as String? ?? '',
      formConfigurationId: json['formConfigurationId'] as String?,
      nextFeedbackId: json['nextFeedbackId'] as String?,
      onPageDelay: json['onPageDelay'] as int?,
      pingAgainIn: json['pingAgainIn'] as int?,
      pingOnNextPageVisit: json['pingOnNextPageVisit'] as bool?,
      feedbackTransactions: json[r'$feedbackTransactions'] as String?,
    );
  }
}

/// Request payload for the show-form API endpoint.
class ShowFormRequest {
  final String formSlugOrId;
  final TriggerType? triggerType;
  final String? language;

  /// Source tracking key-value pairs filtered by the form's sourceTrackingFields allowlist.
  final Map<String, String>? sourceTrackingFieldValues;
  final ApiDeviceInfo? deviceInfo;
  final String? feedbackTransactions;

  const ShowFormRequest({
    required this.formSlugOrId,
    this.triggerType,
    this.language,
    this.sourceTrackingFieldValues,
    this.deviceInfo,
    this.feedbackTransactions,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'formSlugOrId': formSlugOrId};
    if (triggerType != null) map['triggerType'] = triggerType!.name;
    if (language != null) map['language'] = language;
    if (sourceTrackingFieldValues != null &&
        sourceTrackingFieldValues!.isNotEmpty) {
      map['sourceTrackingFieldValues'] = sourceTrackingFieldValues;
    }
    if (deviceInfo != null) map[r'$deviceInfo'] = deviceInfo!.toJson();
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

/// Response from the show-form API endpoint, containing form configuration.
class ShowFormResponse {
  final String feedbackConfigurationId;
  final String? feedbackIdentifier;
  final String? triggerType;
  final Map<String, dynamic>? formConfiguration;
  final Map<String, dynamic>? questionnaireFields;
  final Map<String, dynamic>? otherConfigurationProperties;
  final Map<String, dynamic>? appearanceProperties;
  final bool? partialResponseEnabled;

  /// Contact properties returned by the server for Liquid variable substitution
  /// via the `{{ contact.key }}` syntax in form copy.
  final Map<String, dynamic>? contact;
  final int? pingAgainIn;
  final bool? pingOnNextPageVisit;
  final String? feedbackTransactions;

  const ShowFormResponse({
    required this.feedbackConfigurationId,
    this.feedbackIdentifier,
    this.triggerType,
    this.formConfiguration,
    this.questionnaireFields,
    this.otherConfigurationProperties,
    this.appearanceProperties,
    this.partialResponseEnabled,
    this.contact,
    this.pingAgainIn,
    this.pingOnNextPageVisit,
    this.feedbackTransactions,
  });

  factory ShowFormResponse.fromJson(Map<String, dynamic> json) {
    return ShowFormResponse(
      feedbackConfigurationId: json['feedbackConfigurationId'] as String? ?? '',
      feedbackIdentifier: json['feedbackIdentifier'] as String?,
      triggerType: json['triggerType'] as String?,
      formConfiguration: json['formConfiguration'] as Map<String, dynamic>?,
      questionnaireFields: json['questionnaireFields'] as Map<String, dynamic>?,
      otherConfigurationProperties:
          json['otherConfigurationProperties'] as Map<String, dynamic>?,
      appearanceProperties:
          json['appearanceProperties'] as Map<String, dynamic>?,
      partialResponseEnabled: json['partialResponseEnabled'] as bool?,
      contact: json['contact'] as Map<String, dynamic>?,
      pingAgainIn: json['pingAgainIn'] as int?,
      pingOnNextPageVisit: json['pingOnNextPageVisit'] as bool?,
      feedbackTransactions: json[r'$feedbackTransactions'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'feedbackConfigurationId': feedbackConfigurationId,
    };
    if (feedbackIdentifier != null) {
      map['feedbackIdentifier'] = feedbackIdentifier;
    }
    if (triggerType != null) map['triggerType'] = triggerType;
    if (formConfiguration != null) map['formConfiguration'] = formConfiguration;
    if (questionnaireFields != null) {
      map['questionnaireFields'] = questionnaireFields;
    }
    if (otherConfigurationProperties != null) {
      map['otherConfigurationProperties'] = otherConfigurationProperties;
    }
    if (appearanceProperties != null) {
      map['appearanceProperties'] = appearanceProperties;
    }
    if (partialResponseEnabled != null) {
      map['partialResponseEnabled'] = partialResponseEnabled;
    }
    if (contact != null) map['contact'] = contact;
    if (pingAgainIn != null) map['pingAgainIn'] = pingAgainIn;
    if (pingOnNextPageVisit != null) {
      map['pingOnNextPageVisit'] = pingOnNextPageVisit;
    }
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

class DismissFormRequest {
  final String? formConfigurationId;
  final ApiDeviceInfo? deviceInfo;
  final String? feedbackTransactions;

  const DismissFormRequest({
    this.formConfigurationId,
    this.deviceInfo,
    this.feedbackTransactions,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (formConfigurationId != null) {
      map['formConfigurationId'] = formConfigurationId;
    }
    if (deviceInfo != null) map[r'$deviceInfo'] = deviceInfo!.toJson();
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

class DismissFormResponse {
  final String? message;
  final int? pingAgainIn;
  final bool? pingOnNextPageVisit;
  final String? feedbackTransactions;

  const DismissFormResponse({
    this.message,
    this.pingAgainIn,
    this.pingOnNextPageVisit,
    this.feedbackTransactions,
  });

  factory DismissFormResponse.fromJson(Map<String, dynamic> json) {
    return DismissFormResponse(
      message: json['message'] as String?,
      pingAgainIn: json['pingAgainIn'] as int?,
      pingOnNextPageVisit: json['pingOnNextPageVisit'] as bool?,
      feedbackTransactions: json[r'$feedbackTransactions'] as String?,
    );
  }
}

class PingRequest {
  final ApiDeviceInfo? deviceInfo;
  final String? feedbackTransactions;

  const PingRequest({this.deviceInfo, this.feedbackTransactions});

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (deviceInfo != null) map[r'$deviceInfo'] = deviceInfo!.toJson();
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

class PingResponse {
  final String message;
  final String? action;
  final String? formConfigurationId;
  final int? pingAgainIn;
  final bool? pingOnNextPageVisit;
  final String? feedbackTransactions;

  const PingResponse({
    required this.message,
    this.action,
    this.formConfigurationId,
    this.pingAgainIn,
    this.pingOnNextPageVisit,
    this.feedbackTransactions,
  });

  factory PingResponse.fromJson(Map<String, dynamic> json) {
    return PingResponse(
      message: json['message'] as String? ?? '',
      action: json['action'] as String?,
      formConfigurationId: json['formConfigurationId'] as String?,
      pingAgainIn: json['pingAgainIn'] as int?,
      pingOnNextPageVisit: json['pingOnNextPageVisit'] as bool?,
      feedbackTransactions: json[r'$feedbackTransactions'] as String?,
    );
  }
}

/// Request payload for the AI text refinement endpoint.
class RefineTextRequest {
  final String questionId;
  final String feedbackConfigurationId;
  final String userText;
  final ApiDeviceInfo? deviceInfo;
  final String? feedbackTransactions;

  const RefineTextRequest({
    required this.questionId,
    required this.feedbackConfigurationId,
    required this.userText,
    this.deviceInfo,
    this.feedbackTransactions,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'questionId': questionId,
      'feedbackConfigurationId': feedbackConfigurationId,
      'userText': userText,
    };
    if (deviceInfo != null) map[r'$deviceInfo'] = deviceInfo!.toJson();
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

/// Response from the AI text refinement endpoint.
class RefineTextResponse {
  final String? message;
  final String? refinedText;
  final int? status;
  final String? error;
  final int? pingAgainIn;
  final bool? pingOnNextPageVisit;
  final String? feedbackTransactions;

  const RefineTextResponse({
    this.message,
    this.refinedText,
    this.status,
    this.error,
    this.pingAgainIn,
    this.pingOnNextPageVisit,
    this.feedbackTransactions,
  });

  factory RefineTextResponse.fromJson(Map<String, dynamic> json) {
    return RefineTextResponse(
      message: json['message'] as String?,
      refinedText: json['refinedText'] as String?,
      status: json['status'] as int?,
      error: json['error'] as String?,
      pingAgainIn: json['pingAgainIn'] as int?,
      pingOnNextPageVisit: json['pingOnNextPageVisit'] as bool?,
      feedbackTransactions: json[r'$feedbackTransactions'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (message != null) map['message'] = message;
    if (refinedText != null) map['refinedText'] = refinedText;
    if (status != null) map['status'] = status;
    if (error != null) map['error'] = error;
    if (pingAgainIn != null) map['pingAgainIn'] = pingAgainIn;
    if (pingOnNextPageVisit != null) {
      map['pingOnNextPageVisit'] = pingOnNextPageVisit;
    }
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

/// The answer values for a single form question.
class QuestionAnswer {
  final int? nps;
  final int? rating;
  final String? singleChoice;
  final String? singleChoiceOther;
  final List<String>? multipleChoiceMultiple;

  /// Free-text "Other" answer for multiple-choice-multiple questions.
  final String? multipleChoiceOther;
  final List<String>? nestedSelection;
  final String? shortAnswer;
  final String? longText;
  final AnnotationAnswer? annotation;
  final bool? yesNo;
  final bool? consent;
  final Map<String, dynamic>? ratingMatrix;
  final Map<String, String>? matrixSingleChoice;
  final Map<String, List<String>>? matrixMultipleChoice;

  /// Date answer in ISO 8601 format (YYYY-MM-DD or YYYY-MM-DDTHH:MM).
  final String? date;

  /// CSAT score: 1 (lowest) to N (highest) where N is the scale size (2–5).
  final int? csat;
  final int? opinionScale;

  /// Ranking answer: ordered array of option values where index 0 = rank 1.
  final List<String>? ranking;
  final List<String>? pictureChoice;
  final String? pictureChoiceOther;
  final SignatureAnswer? signature;
  final List<FileUploadAnswerItem>? fileUpload;
  final String? email;
  final String? number;
  final String? website;
  final PhoneNumberAnswer? phoneNumber;
  final AddressAnswer? address;
  final VideoAudioAnswer? videoAudio;
  final SchedulerAnswer? scheduler;

  /// Ordered transcript of Q&A pairs from a qna_with_ai session.
  final List<QnaWithAiPair>? qnaWithAi;
  final PaymentsUpiAnswer? paymentsUpi;

  const QuestionAnswer({
    this.nps,
    this.rating,
    this.singleChoice,
    this.singleChoiceOther,
    this.multipleChoiceMultiple,
    this.multipleChoiceOther,
    this.nestedSelection,
    this.shortAnswer,
    this.longText,
    this.annotation,
    this.yesNo,
    this.consent,
    this.ratingMatrix,
    this.matrixSingleChoice,
    this.matrixMultipleChoice,
    this.date,
    this.csat,
    this.opinionScale,
    this.ranking,
    this.pictureChoice,
    this.pictureChoiceOther,
    this.signature,
    this.fileUpload,
    this.email,
    this.number,
    this.website,
    this.phoneNumber,
    this.address,
    this.videoAudio,
    this.scheduler,
    this.qnaWithAi,
    this.paymentsUpi,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (nps != null) map['nps'] = nps;
    if (rating != null) map['rating'] = rating;
    if (singleChoice != null) map['singleChoice'] = singleChoice;
    if (singleChoiceOther != null) map['singleChoiceOther'] = singleChoiceOther;
    if (multipleChoiceMultiple != null) {
      map['multipleChoiceMultiple'] = multipleChoiceMultiple;
    }
    if (multipleChoiceOther != null) {
      map['multipleChoiceOther'] = multipleChoiceOther;
    }
    if (nestedSelection != null) map['nestedSelection'] = nestedSelection;
    if (shortAnswer != null) map['shortAnswer'] = shortAnswer;
    if (longText != null) map['longText'] = longText;
    if (annotation != null) map['annotation'] = annotation!.toJson();
    if (yesNo != null) map['yesNo'] = yesNo;
    if (consent != null) map['consent'] = consent;
    if (ratingMatrix != null) map['ratingMatrix'] = ratingMatrix;
    if (matrixSingleChoice != null) {
      map['matrixSingleChoice'] = matrixSingleChoice;
    }
    if (matrixMultipleChoice != null) {
      map['matrixMultipleChoice'] = matrixMultipleChoice;
    }
    if (date != null) map['date'] = date;
    if (csat != null) map['csat'] = csat;
    if (opinionScale != null) map['opinionScale'] = opinionScale;
    if (ranking != null) map['ranking'] = ranking;
    if (pictureChoice != null) map['pictureChoice'] = pictureChoice;
    if (pictureChoiceOther != null) {
      map['pictureChoiceOther'] = pictureChoiceOther;
    }
    if (signature != null) map['signature'] = signature!.toJson();
    if (fileUpload != null) {
      map['fileUpload'] = fileUpload!.map((f) => f.toJson()).toList();
    }
    if (email != null) map['email'] = email;
    if (number != null) map['number'] = number;
    if (website != null) map['website'] = website;
    if (phoneNumber != null) map['phoneNumber'] = phoneNumber!.toJson();
    if (address != null) map['address'] = address!.toJson();
    if (videoAudio != null) map['videoAudio'] = videoAudio!.toJson();
    if (scheduler != null) map['scheduler'] = scheduler!.toJson();
    if (qnaWithAi != null) {
      map['qnaWithAi'] = qnaWithAi!.map((p) => p.toJson()).toList();
    }
    if (paymentsUpi != null) map['paymentsUpi'] = paymentsUpi!.toJson();
    return map;
  }
}

/// A single timestamped annotation marker on a video/audio annotation question.
class AnnotationMarker {
  final String markerNo;
  final String timeline;
  final String comment;

  const AnnotationMarker({
    required this.markerNo,
    required this.timeline,
    required this.comment,
  });

  Map<String, dynamic> toJson() => {
    'markerNo': markerNo,
    'timeline': timeline,
    'comment': comment,
  };
}

/// Answer data for an annotation/drawing question type.
class AnnotationAnswer {
  final String fileType;
  final String fileName;
  final List<AnnotationMarker> markers;

  const AnnotationAnswer({
    required this.fileType,
    required this.fileName,
    required this.markers,
  });

  Map<String, dynamic> toJson() => {
    'fileType': fileType,
    'fileName': fileName,
    'markers': markers.map((m) => m.toJson()).toList(),
  };
}

/// Answer for a signature question (typed name, drawn, or uploaded).
class SignatureAnswer {
  /// The signing method: 'type', 'draw', or 'upload'.
  final String mode;
  final String? fileUrl;
  final String? typedName;

  const SignatureAnswer({required this.mode, this.fileUrl, this.typedName});

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'mode': mode};
    if (fileUrl != null) map['fileUrl'] = fileUrl;
    if (typedName != null) map['typedName'] = typedName;
    return map;
  }
}

/// A single uploaded file in a file-upload answer.
class FileUploadAnswerItem {
  final String fileUrl;
  final String fileName;
  final double fileSizeMb;
  final String? mimeType;

  const FileUploadAnswerItem({
    required this.fileUrl,
    required this.fileName,
    required this.fileSizeMb,
    this.mimeType,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'fileUrl': fileUrl,
      'fileName': fileName,
      'fileSizeMb': fileSizeMb,
    };
    if (mimeType != null) map['mimeType'] = mimeType;
    return map;
  }
}

/// Answer for a phone-number question, including country code and E.164 form.
class PhoneNumberAnswer {
  /// Dialing country code including the + prefix (e.g. '+1', '+91').
  final String countryCode;
  final String number;

  /// Full phone number in E.164 format (e.g. '+14155552671').
  final String? e164;

  const PhoneNumberAnswer({
    required this.countryCode,
    required this.number,
    this.e164,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'countryCode': countryCode, 'number': number};
    if (e164 != null) map['e164'] = e164;
    return map;
  }
}

/// Answer for an address question.
class AddressAnswer {
  final String? addressLine1;
  final String? addressLine2;
  final String? city;
  final String? stateProvince;
  final String? postalCode;
  final String? country;

  const AddressAnswer({
    this.addressLine1,
    this.addressLine2,
    this.city,
    this.stateProvince,
    this.postalCode,
    this.country,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (addressLine1 != null) map['addressLine1'] = addressLine1;
    if (addressLine2 != null) map['addressLine2'] = addressLine2;
    if (city != null) map['city'] = city;
    if (stateProvince != null) map['stateProvince'] = stateProvince;
    if (postalCode != null) map['postalCode'] = postalCode;
    if (country != null) map['country'] = country;
    return map;
  }
}

/// Answer for a video/audio/photo/text capture question.
class VideoAudioAnswer {
  /// The answer mode: 'video', 'audio', 'photo', or 'text'.
  final String mode;
  final String? fileUrl;
  final String? text;
  final int? durationSeconds;
  final String? transcriptText;

  const VideoAudioAnswer({
    required this.mode,
    this.fileUrl,
    this.text,
    this.durationSeconds,
    this.transcriptText,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'mode': mode};
    if (fileUrl != null) map['fileUrl'] = fileUrl;
    if (text != null) map['text'] = text;
    if (durationSeconds != null) map['durationSeconds'] = durationSeconds;
    if (transcriptText != null) map['transcriptText'] = transcriptText;
    return map;
  }
}

/// Answer for a scheduler question (Google Calendar or Calendly booking).
///
/// Use the named constructors [SchedulerAnswer.googleCalendar] and
/// [SchedulerAnswer.calendly] to build instances.
class SchedulerAnswer {
  final String provider;
  final String bookedAt;
  final String? slotStart;
  final String? slotEnd;
  final String? eventId;

  const SchedulerAnswer._({
    required this.provider,
    required this.bookedAt,
    this.slotStart,
    this.slotEnd,
    this.eventId,
  });

  const SchedulerAnswer.googleCalendar({required String bookedAt})
    : this._(provider: 'google_calendar', bookedAt: bookedAt);

  const SchedulerAnswer.calendly({
    required String slotStart,
    required String slotEnd,
    required String bookedAt,
    String? eventId,
  }) : this._(
         provider: 'calendly',
         bookedAt: bookedAt,
         slotStart: slotStart,
         slotEnd: slotEnd,
         eventId: eventId,
       );

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'provider': provider, 'bookedAt': bookedAt};
    if (slotStart != null) map['slotStart'] = slotStart;
    if (slotEnd != null) map['slotEnd'] = slotEnd;
    if (eventId != null) map['eventId'] = eventId;
    return map;
  }
}

/// A single Q&A exchange in a [QuestionType.qnaWithAi] answer.
class QnaWithAiPair {
  final String question;
  final String answer;

  const QnaWithAiPair({required this.question, required this.answer});

  Map<String, dynamic> toJson() => {'question': question, 'answer': answer};
}

/// Answer for a UPI payments question.
class PaymentsUpiAnswer {
  final String transactionId;
  final String encatchPaymentReference;
  final double amount;
  final String currency;
  final String payeeVpa;
  final String? payeeName;
  final String? sourceEmail;
  final String? upiIntentUri;

  const PaymentsUpiAnswer({
    required this.transactionId,
    required this.encatchPaymentReference,
    required this.amount,
    this.currency = 'INR',
    required this.payeeVpa,
    this.payeeName,
    this.sourceEmail,
    this.upiIntentUri,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'transactionId': transactionId,
      'encatchPaymentReference': encatchPaymentReference,
      'amount': amount,
      'currency': currency,
      'payeeVpa': payeeVpa,
      'selfReported': true,
    };
    if (payeeName != null) map['payeeName'] = payeeName;
    if (sourceEmail != null) map['sourceEmail'] = sourceEmail;
    if (upiIntentUri != null) map['upiIntentUri'] = upiIntentUri;
    return map;
  }
}

/// A single question's ID, type, and answer in a form submission.
class QuestionResponse {
  final String questionId;
  final QuestionType? type;
  final QuestionAnswer? answer;

  /// Whether this question was on the respondent's navigation path.
  /// Used for drop-off analysis.
  final bool? isOnPath;

  const QuestionResponse({
    required this.questionId,
    this.type,
    this.answer,
    this.isOnPath,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'questionId': questionId};
    if (type != null) map['type'] = type!.value;
    if (answer != null) map['answer'] = answer!.toJson();
    if (isOnPath != null) map['isOnPath'] = isOnPath;
    return map;
  }
}

/// Details of a form submission, including responses and metadata.
class FormDetails {
  final String formConfigurationId;
  final bool? isPartialSubmit;
  final String? feedbackIdentifier;
  final String? responseLanguageCode;
  final Map<String, dynamic>? response;
  final int? completionTimeInSeconds;

  /// Caller-provided metadata attached to this submission
  /// ([DateTime] values already serialized to ISO strings).
  final Map<String, Object>? context;

  /// IDs of questions the user actually navigated to, in order.
  /// Used for drop-off analysis.
  final List<String>? visitedQuestionIds;

  /// Contact properties forwarded from [ShowFormResponse] for server-side association.
  final Map<String, dynamic>? contact;

  /// Source tracking field values captured at survey load time.
  final Map<String, String>? sourceTrackingFieldValues;

  const FormDetails({
    required this.formConfigurationId,
    this.isPartialSubmit,
    this.feedbackIdentifier,
    this.responseLanguageCode,
    this.response,
    this.completionTimeInSeconds,
    this.context,
    this.visitedQuestionIds,
    this.contact,
    this.sourceTrackingFieldValues,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'formConfigurationId': formConfigurationId};
    if (isPartialSubmit != null) map['isPartialSubmit'] = isPartialSubmit;
    if (feedbackIdentifier != null) {
      map['feedbackIdentifier'] = feedbackIdentifier;
    }
    if (responseLanguageCode != null) {
      map['responseLanguageCode'] = responseLanguageCode;
    }
    if (response != null) map['response'] = response;
    if (completionTimeInSeconds != null) {
      map['completionTimeInSeconds'] = completionTimeInSeconds;
    }
    if (context != null) map['context'] = context;
    if (visitedQuestionIds != null) {
      map['visitedQuestionIds'] = visitedQuestionIds;
    }
    if (contact != null) map['contact'] = contact;
    if (sourceTrackingFieldValues != null) {
      map['sourceTrackingFieldValues'] = sourceTrackingFieldValues;
    }
    return map;
  }
}

/// Request payload for submitting a completed form.
class SubmitFormRequest {
  final TriggerType? triggerType;
  final FormDetails formDetails;
  final ApiDeviceInfo? deviceInfo;
  final String? feedbackTransactions;

  const SubmitFormRequest({
    this.triggerType,
    required this.formDetails,
    this.deviceInfo,
    this.feedbackTransactions,
  });

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'formDetails': formDetails.toJson()};
    if (triggerType != null) map['triggerType'] = triggerType!.name;
    if (deviceInfo != null) map[r'$deviceInfo'] = deviceInfo!.toJson();
    if (feedbackTransactions != null) {
      map[r'$feedbackTransactions'] = feedbackTransactions;
    }
    return map;
  }
}

class SubmitFormResponse {
  final String message;
  final int? pingAgainIn;
  final bool? pingOnNextPageVisit;
  final String? feedbackTransactions;

  const SubmitFormResponse({
    required this.message,
    this.pingAgainIn,
    this.pingOnNextPageVisit,
    this.feedbackTransactions,
  });

  factory SubmitFormResponse.fromJson(Map<String, dynamic> json) {
    return SubmitFormResponse(
      message: json['message'] as String? ?? '',
      pingAgainIn: json['pingAgainIn'] as int?,
      pingOnNextPageVisit: json['pingOnNextPageVisit'] as bool?,
      feedbackTransactions: json[r'$feedbackTransactions'] as String?,
    );
  }
}

// ============================================================================
// Internal show form payload (for WebView bridge)
// ============================================================================

/// Resolved presentation target for a showForm call.
enum FormPresentation {
  /// Render in a registered EncatchInlineForm slot.
  inline,

  /// Render as the default full-screen modal overlay.
  modal,
}

class ShowFormPayload {
  final String formId;
  final ShowFormResponse formConfig;
  final ResetMode resetMode;
  final TriggerType triggerType;
  final Map<String, dynamic>? prefillResponses;
  final String? locale;
  final EncatchTheme? theme;

  /// Serialized caller context ([DateTime] values already converted to ISO strings).
  final Map<String, Object>? context;

  /// Resolved presentation target. Defaults to [FormPresentation.modal].
  final FormPresentation presentation;

  /// Set when [presentation] is [FormPresentation.inline]; identifies the
  /// specific registered slot that should display this form.
  final String? inlineSlotId;

  const ShowFormPayload({
    required this.formId,
    required this.formConfig,
    required this.resetMode,
    required this.triggerType,
    this.prefillResponses,
    this.locale,
    this.theme,
    this.context,
    this.presentation = FormPresentation.modal,
    this.inlineSlotId,
  });
}

class DismissPayload {
  final String? formConfigurationId;
  const DismissPayload({this.formConfigurationId});
}

// ============================================================================
// Q&A with AI types
// ============================================================================

/// A single turn in the conversation history sent to the qna-with-ai endpoint.
class QnaWithAiConversationTurn {
  final String question;
  final String answer;

  const QnaWithAiConversationTurn({
    required this.question,
    required this.answer,
  });

  Map<String, dynamic> toJson() => {'question': question, 'answer': answer};
}

/// Request payload for the Q&A-with-AI API ([Encatch.streamQnaWithAi]).
///
/// Provides the form question context and an ordered [conversation] history
/// so the AI can generate a contextual follow-up answer.
class QnaWithAiRequest {
  final String feedbackConfigurationId;
  final String questionId;

  /// Ordered history of previous Q&A turns for context.
  final List<QnaWithAiConversationTurn> conversation;

  const QnaWithAiRequest({
    required this.feedbackConfigurationId,
    required this.questionId,
    required this.conversation,
  });

  Map<String, dynamic> toJson() => {
    'feedbackConfigurationId': feedbackConfigurationId,
    'questionId': questionId,
    'conversation': conversation.map((t) => t.toJson()).toList(),
  };
}

/// Response returned by the Q&A-with-AI API ([Encatch.streamQnaWithAi]).
///
/// Contains the AI-generated [answer] text for the submitted conversation turn.
class QnaWithAiResponse {
  final String answer;
  const QnaWithAiResponse({required this.answer});

  factory QnaWithAiResponse.fromJson(Map<String, dynamic> json) =>
      QnaWithAiResponse(answer: json['answer'] as String? ?? '');
}

// ============================================================================
// Upload file types
// ============================================================================

/// Parameters for [Encatch.uploadFile].
///
/// Supply either [filePath] (from a native file/image picker) **or** [fileData]
/// (raw base64 bytes forwarded from the WebView form engine) — not both.
class UploadFileRequest {
  /// The form's server-issued configuration ID.
  final String feedbackConfigurationId;

  /// The question ID the file belongs to.
  final String questionId;

  /// Path to the local file on disk (e.g. from an image/document picker).
  /// Mutually exclusive with [fileData].
  final String? filePath;

  /// Base64-encoded file content forwarded from the WebView form engine.
  /// Accepts raw base64 or a data URL (`data:<mime>;base64,...`).
  /// Mutually exclusive with [filePath].
  final String? fileData;

  /// MIME type of the file (e.g. 'image/png').
  final String mimeType;

  /// File name to send to the server.
  /// Defaults to the basename of [filePath], or 'upload' when using [fileData].
  final String? fileName;

  /// Optional progress callback — receives upload percentage (0–100).
  final void Function(int percent)? onProgress;

  const UploadFileRequest({
    required this.feedbackConfigurationId,
    required this.questionId,
    this.filePath,
    this.fileData,
    required this.mimeType,
    this.fileName,
    this.onProgress,
  }) : assert(
         (filePath != null) != (fileData != null),
         'Provide exactly one of filePath or fileData',
       );
}

/// Response returned by [Encatch.uploadFile].
///
/// Contains the permanent server-hosted [fileUrl] for the uploaded file.
class UploadFileResponse {
  /// Permanent URL of the uploaded file.
  final String fileUrl;
  const UploadFileResponse({required this.fileUrl});

  factory UploadFileResponse.fromJson(Map<String, dynamic> json) =>
      UploadFileResponse(fileUrl: json['fileUrl'] as String? ?? '');
}

// ============================================================================
// Preferences
// ============================================================================

/// Persisted user preferences (locale and country).
class Preferences {
  final String? locale;
  final String? country;

  const Preferences({this.locale, this.country});

  factory Preferences.fromJson(Map<String, dynamic> json) {
    return Preferences(
      locale: json['locale'] as String?,
      country: json['country'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (locale != null) map['locale'] = locale;
    if (country != null) map['country'] = country;
    return map;
  }
}
