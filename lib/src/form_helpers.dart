/// Helpers for custom native forms (when using onBeforeShowForm interceptor).
/// Use these to build SubmitFormRequest from your native form responses.
/// Mirrors form-helpers.ts from the React Native SDK.
library;

import 'types.dart';

/// A valid native form answer value.
typedef NativeFormValue = dynamic;

/// A single question response from a custom native form.
class NativeFormResponse {
  /// The ID of the question being answered.
  final String questionId;

  /// The question type wire string (e.g. `'rating'`, `'nps'`, `'short_answer'`,
  /// `'single_choice'`, `'multiple_choice_multiple'`, `'signature'`, etc.).
  final String type;

  /// The answer value. The expected Dart type varies by [type]:
  /// - `int` / `double` for numeric answers (rating, nps, csat, opinion_scale)
  /// - `bool` for yes_no, consent
  /// - `String` for text, date, email, number, website, file URLs
  /// - `List<String>` for multi-select, ranking, picture_choice, nested_selection
  /// - A typed answer object for complex types (e.g. [SignatureAnswer], [PhoneNumberAnswer])
  final NativeFormValue value;

  const NativeFormResponse({
    required this.questionId,
    required this.type,
    required this.value,
  });
}

/// Options used when constructing a [SubmitFormRequest] via [buildSubmitRequest].
class BuildSubmitRequestOptions {
  final TriggerType? triggerType;
  final String formConfigurationId;
  final String? responseLanguageCode;
  final int? completionTimeInSeconds;
  final bool? isPartialSubmit;
  final String? feedbackIdentifier;

  /// Caller-provided metadata attached to the submission.
  /// [DateTime] values are automatically serialized to ISO 8601 strings.
  final Map<String, Object>? context;

  const BuildSubmitRequestOptions({
    this.triggerType,
    required this.formConfigurationId,
    this.responseLanguageCode,
    this.completionTimeInSeconds,
    this.isPartialSubmit,
    this.feedbackIdentifier,
    this.context,
  });
}

int _toInt(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

List<String> _toStringList(dynamic value) {
  if (value is List) return value.map((e) => '$e').toList();
  if (value is String) return [value];
  return [];
}

/// Maps a native form response type + value to the [QuestionAnswer] wire format.
QuestionAnswer _toQuestionAnswer(String type, dynamic value) {
  switch (type) {
    case 'rating':
      return QuestionAnswer(rating: _toInt(value));
    case 'nps':
      return QuestionAnswer(nps: _toInt(value));
    case 'csat':
      return QuestionAnswer(csat: _toInt(value));
    case 'opinion_scale':
      return QuestionAnswer(opinionScale: _toInt(value));
    case 'short_answer':
      return QuestionAnswer(shortAnswer: '$value');
    case 'long_text':
      return QuestionAnswer(longText: '$value');
    case 'email':
      return QuestionAnswer(email: '$value');
    case 'number':
      return QuestionAnswer(number: '$value');
    case 'website':
      return QuestionAnswer(website: '$value');
    case 'date':
      return QuestionAnswer(date: '$value');
    case 'single_choice':
      return QuestionAnswer(singleChoice: '$value');
    case 'multiple_choice':
    case 'multiple_choice_multiple':
      return QuestionAnswer(multipleChoiceMultiple: _toStringList(value));
    case 'nested_selection':
      return QuestionAnswer(nestedSelection: _toStringList(value));
    case 'ranking':
      return QuestionAnswer(ranking: _toStringList(value));
    case 'picture_choice':
      return QuestionAnswer(pictureChoice: _toStringList(value));
    case 'yes_no':
      final boolVal = value is bool ? value : '$value'.toLowerCase() == 'true';
      return QuestionAnswer(yesNo: boolVal);
    case 'consent':
      final boolVal = value is bool ? value : '$value'.toLowerCase() == 'true';
      return QuestionAnswer(consent: boolVal);
    case 'rating_matrix':
      final mapVal = value is Map<String, dynamic>
          ? value
          : <String, dynamic>{};
      return QuestionAnswer(ratingMatrix: mapVal);
    case 'matrix_single_choice':
      final mapVal = value is Map<String, String>
          ? value
          : (value is Map
                ? value.map((k, v) => MapEntry('$k', '$v'))
                : <String, String>{});
      return QuestionAnswer(matrixSingleChoice: mapVal);
    case 'matrix_multiple_choice':
      final mapVal = value is Map<String, List<String>>
          ? value
          : (value is Map
                ? value.map(
                    (k, v) => MapEntry(
                      '$k',
                      v is List ? v.map((e) => '$e').toList() : ['$v'],
                    ),
                  )
                : <String, List<String>>{});
      return QuestionAnswer(matrixMultipleChoice: mapVal);
    case 'annotation':
      if (value is AnnotationAnswer) return QuestionAnswer(annotation: value);
      return const QuestionAnswer();
    case 'signature':
      if (value is SignatureAnswer) return QuestionAnswer(signature: value);
      if (value is String) {
        return QuestionAnswer(
          signature: SignatureAnswer(mode: 'type', typedName: value),
        );
      }
      return const QuestionAnswer();
    case 'file_upload':
      if (value is List<FileUploadAnswerItem>) {
        return QuestionAnswer(fileUpload: value);
      }
      if (value is FileUploadAnswerItem) {
        return QuestionAnswer(fileUpload: [value]);
      }
      return const QuestionAnswer();
    case 'phone_number':
      if (value is PhoneNumberAnswer) return QuestionAnswer(phoneNumber: value);
      return const QuestionAnswer();
    case 'address':
      if (value is AddressAnswer) return QuestionAnswer(address: value);
      return const QuestionAnswer();
    case 'video_audio':
      if (value is VideoAudioAnswer) return QuestionAnswer(videoAudio: value);
      return const QuestionAnswer();
    case 'scheduler':
      if (value is SchedulerAnswer) return QuestionAnswer(scheduler: value);
      return const QuestionAnswer();
    case 'qna_with_ai':
      if (value is List<QnaWithAiPair>) return QuestionAnswer(qnaWithAi: value);
      return const QuestionAnswer();
    case 'payments_upi':
      if (value is PaymentsUpiAnswer) return QuestionAnswer(paymentsUpi: value);
      return const QuestionAnswer();
    default:
      return QuestionAnswer(shortAnswer: '$value');
  }
}

/// Builds a [SubmitFormRequest] from native form responses.
///
/// Use this when you have a custom native form UI and need to submit responses
/// to the Encatch API (typically after intercepting via [EncatchConfig.onBeforeShowForm]).
///
/// Example:
/// ```dart
/// final request = buildSubmitRequest(
///   options: BuildSubmitRequestOptions(
///     formConfigurationId: formConfig.feedbackConfigurationId,
///     context: {'plan': 'pro'},
///   ),
///   responses: [
///     NativeFormResponse(questionId: 'q1', type: 'rating', value: 5),
///     NativeFormResponse(questionId: 'q2', type: 'short_answer', value: 'Great!'),
///     NativeFormResponse(questionId: 'q3', type: 'yes_no', value: true),
///   ],
/// );
/// await Encatch.submitForm(request);
/// ```
SubmitFormRequest buildSubmitRequest({
  required BuildSubmitRequestOptions options,
  required List<NativeFormResponse> responses,
}) {
  final questions = responses
      .map(
        (r) => QuestionResponse(
          questionId: r.questionId,
          type: QuestionTypeExt.fromString(r.type),
          answer: _toQuestionAnswer(r.type, r.value),
        ),
      )
      .toList();

  final formDetails = FormDetails(
    formConfigurationId: options.formConfigurationId,
    responseLanguageCode: options.responseLanguageCode,
    completionTimeInSeconds: options.completionTimeInSeconds,
    isPartialSubmit: options.isPartialSubmit,
    feedbackIdentifier: options.feedbackIdentifier,
    context: options.context,
    response: {'questions': questions.map((q) => q.toJson()).toList()},
  );

  return SubmitFormRequest(
    triggerType: options.triggerType ?? TriggerType.manual,
    formDetails: formDetails,
  );
}
