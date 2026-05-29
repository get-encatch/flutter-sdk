/// Encatch Flutter SDK
///
/// Import this file to access all public SDK APIs:
///
/// ```dart
/// import 'package:encatch_flutter/encatch_flutter.dart';
/// ```
library encatch_flutter;

export 'src/encatch.dart' show Encatch;
export 'src/encatch_provider.dart'
    show EncatchProvider, EncatchNavigatorObserver;
export 'src/encatch_webview.dart' show EncatchWebView;
export 'src/encatch_inline_form.dart' show EncatchInlineForm;
export 'src/form_helpers.dart'
    show
        buildSubmitRequest,
        NativeFormResponse,
        NativeFormValue,
        BuildSubmitRequestOptions;
export 'src/types.dart'
    show
        EncatchConfig,
        EncatchTheme,
        UserTraits,
        IdentifyOptions,
        SecureOptions,
        ResetMode,
        ShowFormOptions,
        StartSessionOptions,
        EventType,
        EventPayload,
        EventCallback,
        TriggerType,
        ShowFormInterceptorPayload,
        ShowFormResponse,
        ShowFormRequest,
        SubmitFormRequest,
        FormDetails,
        QuestionResponse,
        QuestionType,
        QuestionTypeExt,
        QuestionAnswer,
        // Structured answer types
        AnnotationMarker,
        AnnotationAnswer,
        SignatureAnswer,
        FileUploadAnswerItem,
        PhoneNumberAnswer,
        AddressAnswer,
        VideoAudioAnswer,
        SchedulerAnswer,
        QnaWithAiPair,
        PaymentsUpiAnswer,
        // Q&A with AI API types
        QnaWithAiConversationTurn,
        QnaWithAiRequest,
        QnaWithAiResponse,
        // Upload API types
        UploadFileRequest,
        UploadFileResponse,
        // Misc
        RefineTextRequest,
        RefineTextResponse,
        ApiDeviceInfo,
        IdentifyUserResponse,
        FormMessageType,
        FormMessageTypeExt,
        SdkMessageType,
        SdkMessageTypeExt,
        Preferences,
        FormPresentation;
