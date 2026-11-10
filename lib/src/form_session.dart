/// What the SDK does with the messages one open survey sends: which events
/// reach the app, which survey events go to the server, and whether closing it
/// counts as a dismissal. Internal; not exported from the package.
///
/// The WebView bridge owns the widget side (sizing, closing, opening links)
/// and hands the rest to this class, which has no widgets and can be tested
/// without a WebView.
library;

import 'encatch.dart';
import 'types.dart';

class FormSession {
  /// [configId] is the form's id from the show-form reply (a UUID).
  FormSession(this.configId);

  final String configId;

  /// The final (not partial) submit has happened, or the form completed. The
  /// thank-you screen always comes after it.
  bool _finalSubmitDone = false;

  /// The survey is closing for a reason that is not a dismissal: "remind me
  /// later" or a call-to-action button.
  bool _closingForAnotherReason = false;

  bool _closed = false;
  bool _answeredTracked = false;

  /// The form id to report. The survey page sends an empty id on most
  /// messages; the page's own id wins when it does send one, then the id in
  /// the message's data, then the survey this view opened.
  String formIdFor(String pageFormId, Map<String, dynamic> data) {
    if (pageFormId.isNotEmpty) return pageFormId;
    final fromData = data['feedbackConfigurationId'];
    if (fromData is String && fromData.isNotEmpty) return fromData;
    return configId;
  }

  /// The id sent to the server with a survey event: the one in the message's
  /// data when present, else the id from the show-form reply.
  String _serverFormId(Map<String, dynamic> data) {
    final fromData = data['feedbackConfigurationId'];
    return fromData is String && fromData.isNotEmpty ? fromData : configId;
  }

  void _emit(EventType type, String pageFormId, Map<String, dynamic> data) {
    Encatch.emitEvent(
      type,
      EventPayload(
        formId: formIdFor(pageFormId, data),
        timestamp: DateTime.now().millisecondsSinceEpoch,
        data: data,
      ),
    );
  }

  void _track(String eventName, Map<String, dynamic> data) {
    Encatch.trackFormEvent(eventName, _serverFormId(data)).catchError((_) {});
  }

  void show(String pageFormId, Map<String, dynamic> data) {
    _emit(EventType.formShow, pageFormId, data);
    _track('form:show', data);
  }

  void started(String pageFormId, Map<String, dynamic> data) {
    _emit(EventType.formStarted, pageFormId, data);
    _track('form:started', data);
  }

  /// The server hears about the first answer only.
  void answered(String pageFormId, Map<String, dynamic> data) {
    _emit(EventType.formAnswered, pageFormId, data);
    if (_answeredTracked) return;
    _answeredTracked = true;
    _track('form:answered', data);
  }

  void sectionChange(String pageFormId, Map<String, dynamic> data) {
    _emit(EventType.formSectionChange, pageFormId, data);
  }

  /// A submit from the page. The request itself is sent by the bridge.
  void submit(String pageFormId, Map<String, dynamic> data) {
    if (data['isPartialSubmit'] != true) _finalSubmitDone = true;
    _emit(EventType.formSubmit, pageFormId, data);
  }

  void complete(String pageFormId, Map<String, dynamic> data) {
    _finalSubmitDone = true;
    _emit(EventType.formComplete, pageFormId, data);
    _track('form:complete', data);
  }

  void remindMeLater(String pageFormId, Map<String, dynamic> data) {
    _closingForAnotherReason = true;
    _emit(EventType.formRemindMeLater, pageFormId, data);
    _track('form:remindmelater', data);
  }

  void ctaTriggered(String pageFormId, Map<String, dynamic> data) {
    _closingForAnotherReason = true;
    _emit(EventType.formCtaTriggered, pageFormId, data);
  }

  void error(String pageFormId, Map<String, dynamic> data) {
    _emit(EventType.formError, pageFormId, data);
  }

  /// The user closed the survey with its X.
  ///
  /// Before the final submit this is a dismissal, including after partial
  /// submits on a multi-page form. It is not one on the thank-you screen (which
  /// always follows the final submit), after "remind me later", or after a
  /// call-to-action button.
  ///
  /// For an identified user a dismissal sends the `form:dismissed` survey
  /// event and the dismiss-form request, and the app gets `form:dismissed`. A
  /// visitor's sends nothing, not even the app's event: the server ignores
  /// both for visitors.
  void close(String pageFormId, Map<String, dynamic> data) {
    _emit(EventType.formClose, pageFormId, data);
    if (_closed) return;
    _closed = true;
    if (_finalSubmitDone || _closingForAnotherReason) return;
    if (Encatch.userName == null || Encatch.userId == null) return;

    _track('form:dismissed', data);
    // dismiss-form needs the form's UUID, which the page's close message does
    // not carry: use the one from the show-form reply.
    Encatch.dismissForm(formConfigurationId: configId).catchError((_) {});
  }
}
