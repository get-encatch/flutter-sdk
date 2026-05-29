/// Shared WebView bridge logic used by both EncatchWebView (modal) and
/// EncatchInlineForm (inline).
///
/// Handles:
///  - InAppWebView settings + JS handler registration
///  - _injectSdkMessage (Native → WebView)
///  - _handleFormReady (config + prefill + theme + locale injection)
///  - _handleWebViewMessage (all form:* messages from the WebView)
///  - Navigation guard (external links → url_launcher)
///  - URL building via buildFormWebViewUrl
///  - section tall-height policy (_sectionUsesTallMaxHeight)
///  - instance key for WebView cache busting
///
/// Presentation-specific behaviour is delegated via callbacks:
///  - [onReady]          : called once when form is ready (after config injection)
///  - [onClose]          : called on form:complete, form:close, form:remindmelater
///  - [onHeightChange]   : called when form:resize reports a new height
///  - [onForceFullHeight]: called when form:layout reports fullHeight open/close
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'encatch.dart';
import 'form_webview_helpers.dart';
import 'logger.dart';
import 'pending_completion_cta.dart';
import 'types.dart';

// ============================================================================
// Callbacks
// ============================================================================

typedef OnBridgeReady = void Function();
typedef OnBridgeClose = void Function();
typedef OnBridgeHeightChange = void Function(double height);
typedef OnBridgeForceFullHeight = void Function(bool force);

// ============================================================================
// EncatchFormWebViewBridge widget
// ============================================================================

/// A widget that owns the [InAppWebView] and its message bridge.
///
/// Presenters (modal overlay, inline form) embed this widget and supply
/// callbacks for the presentation-specific responses.
class EncatchFormWebViewBridge extends StatefulWidget {
  final ShowFormPayload payload;
  final String logTag;

  /// Presentation mode — controls the `?presentation=` URL param.
  final FormPresentation presentation;

  final OnBridgeReady onReady;
  final OnBridgeClose onClose;
  final OnBridgeHeightChange onHeightChange;
  final OnBridgeForceFullHeight onForceFullHeight;

  const EncatchFormWebViewBridge({
    super.key,
    required this.payload,
    required this.logTag,
    required this.presentation,
    required this.onReady,
    required this.onClose,
    required this.onHeightChange,
    required this.onForceFullHeight,
  });

  @override
  State<EncatchFormWebViewBridge> createState() =>
      EncatchFormWebViewBridgeState();
}

class EncatchFormWebViewBridgeState extends State<EncatchFormWebViewBridge> {
  InAppWebViewController? _controller;
  bool _webViewReady = false;

  // Track which form journeys have already sent form:answered
  final Set<String> _formAnsweredTracked = {};

  // Instance key: incremented per new payload load to bust the WebView cache.
  int _instanceKey = 0;

  static final _logger = const EncatchLogger(debugMode: false);

  // ============================================================================
  // Public accessors (used by parent widgets for skeleton visibility etc.)
  // ============================================================================

  bool get webViewReady => _webViewReady;

  /// Call when the parent has a new payload (e.g. inline form receiving a new
  /// showForm event) to reset state and reload the WebView.
  void reloadForNewPayload() {
    _instanceKey++;
    _webViewReady = false;
    _formAnsweredTracked.clear();
    if (_controller != null) {
      final url = _buildUrl();
      _controller!
          .loadUrl(urlRequest: URLRequest(url: WebUri(url)))
          .catchError((_) {});
    }
  }

  // ============================================================================
  // URL builder
  // ============================================================================

  String _buildUrl() => buildFormWebViewUrl(
        webHost: Encatch.webHost,
        formId: widget.payload.formId,
        instanceKey: _instanceKey,
        debugMode: Encatch.debugMode,
        presentation: widget.presentation,
      );

  // ============================================================================
  // Native → WebView message injection
  // ============================================================================

  void _injectSdkMessage(SdkMessageType type, Map<String, dynamic> data) {
    if (_controller == null) return;
    final msg = jsonEncode({'type': type.value, 'data': data});
    final js = '''
      window.dispatchEvent(new MessageEvent('message', { data: $msg }));
      true;
    ''';
    _controller!.evaluateJavascript(source: js).catchError((_) {});
  }

  // ============================================================================
  // form:ready handler
  // ============================================================================

  void _handleFormReady(String formId) {
    if (!mounted) return;

    final payload = widget.payload;
    final config = payload.formConfig;
    // ignore: avoid_print
    print('[${widget.logTag}] form ready received: $formId');

    _injectSdkMessage(SdkMessageType.formConfig, {
      ...config.toJson(),
      'triggerType': payload.triggerType.name,
      if (payload.context != null) 'context': payload.context,
    });

    if (payload.resetMode == ResetMode.always) {
      _injectSdkMessage(SdkMessageType.resetData, {});
    }

    final prefills = payload.prefillResponses?.isNotEmpty == true
        ? payload.prefillResponses!
        : Encatch.getPendingResponses();
    if (prefills.isNotEmpty) {
      _injectSdkMessage(SdkMessageType.prefillResponses, {
        'responses': prefills,
      });
      if (payload.prefillResponses?.isEmpty ?? true) {
        Encatch.clearPendingResponses();
      }
    }

    if (payload.theme != null) {
      _injectSdkMessage(SdkMessageType.theme, {'theme': payload.theme!.name});
    }
    if (payload.locale != null) {
      _injectSdkMessage(SdkMessageType.locale, {'locale': payload.locale!});
    }

    _applySectionHeightPolicy(0);

    if (!_webViewReady) {
      setState(() => _webViewReady = true);
      widget.onReady();
    }
  }

  // ============================================================================
  // Section tall-height policy
  // ============================================================================

  bool _sectionUsesTallMaxHeight(int sectionIndex) {
    final questionnaireFields = widget.payload.formConfig.questionnaireFields;
    final sections = questionnaireFields?['sections'];
    final questions = questionnaireFields?['questions'];
    if (sections is! List || questions is! Map) return false;
    if (sectionIndex < 0 || sectionIndex >= sections.length) return false;

    final section = sections[sectionIndex];
    if (section is! Map) return false;
    final questionIds = section['questionIds'];
    if (questionIds is! List) return false;

    return questionIds.any((questionId) {
      final question = questions[questionId];
      if (question is! Map) return false;
      return question['type'] == 'qna_with_ai';
    });
  }

  void _applySectionHeightPolicy(Object? rawSectionIndex) {
    if (rawSectionIndex is! num) return;
    final uses = _sectionUsesTallMaxHeight(rawSectionIndex.toInt());
    widget.onForceFullHeight(uses);
  }

  bool _messageRequestsTallMaxHeight(Map<String, dynamic> data) {
    if (data['fullHeight'] == true) return true;
    final questionTypes = data['questionTypes'];
    if (questionTypes is List) {
      return questionTypes.any((type) => type == 'qna_with_ai');
    }
    final questionType = data['questionType'] ?? data['type'];
    return questionType == 'qna_with_ai';
  }

  // ============================================================================
  // WebView → Native message handling
  // ============================================================================

  Future<void> _handleWebViewMessage(Map<String, dynamic> msg) async {
    final typeStr = msg['type'] as String? ?? '';
    final type = FormMessageTypeExt.fromString(typeStr);
    final data = (msg['data'] as Map<String, dynamic>?) ?? {};
    final formId = msg['formId'] as String? ?? '';

    switch (type) {
      case FormMessageType.formReady:
        _handleFormReady(formId);

      case FormMessageType.formResize:
        final h = data['height'];
        // ignore: avoid_print
        print('[${widget.logTag}] form resize: $h');
        if (h is num && h > 0) widget.onHeightChange(h.toDouble());

      case FormMessageType.formCloseButton:
        break;

      case FormMessageType.formThemeData:
        break;

      case FormMessageType.formSubmit:
        if (data.isEmpty) break;
        final rawContext = data['context'];
        Encatch.submitForm(
          SubmitFormRequest(
            triggerType: data['triggerType'] == 'automatic'
                ? TriggerType.automatic
                : TriggerType.manual,
            formDetails: FormDetails(
              formConfigurationId:
                  data['feedbackConfigurationId'] as String? ?? '',
              isPartialSubmit: data['isPartialSubmit'] as bool? ?? false,
              feedbackIdentifier: data['feedbackIdentifier'] as String?,
              responseLanguageCode: data['responseLanguageCode'] as String?,
              response: data['response'] as Map<String, dynamic>?,
              completionTimeInSeconds: data['completionTimeInSeconds'] as int?,
              context: rawContext is Map
                  ? Map<String, Object>.from(rawContext)
                  : null,
              visitedQuestionIds: data['visitedQuestionIds'] is List
                  ? List<String>.from(data['visitedQuestionIds'] as List)
                  : null,
            ),
          ),
        ).catchError((_) {});
        Encatch.emitEvent(
          EventType.formSubmit,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );

      case FormMessageType.formComplete:
        Encatch.emitEvent(
          EventType.formComplete,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );
        Encatch.trackFormEvent(
          'form:complete',
          data['feedbackConfigurationId'] as String?,
        ).catchError((_) {});
        _formAnsweredTracked.remove(formId);
        widget.onClose();
        final pendingRaw = data['pendingCompletionCta'];
        if (pendingRaw is Map) {
          final pending = PendingCompletionCta.fromMap(
            Map<String, dynamic>.from(pendingRaw),
          );
          if (pending != null) {
            PendingCompletionCtaScheduler.schedule(formId, pending);
          }
        }

      case FormMessageType.formClose:
        Encatch.emitEvent(
          EventType.formClose,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );
        _formAnsweredTracked.remove(
          (data['feedbackConfigurationId'] as String?) ?? formId,
        );
        widget.onClose();

      case FormMessageType.formStarted:
        Encatch.emitEvent(
          EventType.formStarted,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );
        Encatch.trackFormEvent(
          'form:started',
          data['feedbackConfigurationId'] as String?,
        ).catchError((_) {});

      case FormMessageType.formAnswered:
        Encatch.emitEvent(
          EventType.formAnswered,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );
        final answeredKey =
            (data['feedbackConfigurationId'] as String?) ?? formId;
        if (answeredKey.isNotEmpty &&
            !_formAnsweredTracked.contains(answeredKey)) {
          _formAnsweredTracked.add(answeredKey);
          Encatch.trackFormEvent(
            'form:answered',
            data['feedbackConfigurationId'] as String?,
          ).catchError((_) {});
        }

      case FormMessageType.formSectionChange:
        _applySectionHeightPolicy(data['sectionIndex']);
        Encatch.emitEvent(
          EventType.formSectionChange,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );

      case FormMessageType.formShow:
        Encatch.emitEvent(
          EventType.formShow,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );
        Encatch.trackFormEvent(
          'form:show',
          data['feedbackConfigurationId'] as String?,
        ).catchError((_) {});

      case FormMessageType.formRefineTextRequest:
        if (data.isEmpty) break;
        try {
          final res = await Encatch.refineText(
            RefineTextRequest(
              questionId: data['questionId'] as String? ?? '',
              feedbackConfigurationId:
                  data['feedbackConfigurationId'] as String? ?? '',
              userText: data['userText'] as String? ?? '',
            ),
          );
          _injectSdkMessage(SdkMessageType.refineTextResponse, {
            'requestId': data['requestId'],
            ...res.toJson(),
          });
        } catch (_) {
          _injectSdkMessage(SdkMessageType.refineTextResponse, {
            'requestId': data['requestId'],
            'error': 'Refine text request failed',
          });
        }

      case FormMessageType.formError:
        // ignore: avoid_print
        print('[${widget.logTag}] form:error received: $data');
        Encatch.emitEvent(
          EventType.formError,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );

      case FormMessageType.formLayout:
        widget.onForceFullHeight(_messageRequestsTallMaxHeight(data));

      case FormMessageType.formReadyToDismiss:
        break;

      case FormMessageType.formUploadFileRequest:
        if (data.isEmpty) break;
        final requestId = data['requestId'] as String? ?? '';
        final fileData = data['fileData'] as String?;
        final mimeType =
            data['mimeType'] as String? ?? 'application/octet-stream';
        final feedbackConfigurationId =
            data['feedbackConfigurationId'] as String? ?? formId;
        final questionId = data['questionId'] as String? ?? '';
        final fileName = data['fileName'] as String?;

        if (fileData == null || fileData.isEmpty) {
          _injectSdkMessage(SdkMessageType.uploadFileResponse, {
            'requestId': requestId,
            'error': 'No file data received',
          });
          break;
        }

        Encatch.uploadFile(
              UploadFileRequest(
                feedbackConfigurationId: feedbackConfigurationId,
                questionId: questionId,
                fileData: fileData,
                mimeType: mimeType,
                fileName: fileName,
                onProgress: (percent) {
                  _injectSdkMessage(SdkMessageType.uploadFileProgress, {
                    'requestId': requestId,
                    'percent': percent,
                  });
                },
              ),
            )
            .then((res) {
              _injectSdkMessage(SdkMessageType.uploadFileResponse, {
                'requestId': requestId,
                'fileUrl': res.fileUrl,
              });
            })
            .catchError((Object e) {
              _injectSdkMessage(SdkMessageType.uploadFileResponse, {
                'requestId': requestId,
                'error': e.toString(),
              });
            });

      case FormMessageType.formQnaWithAiRequest:
        if (data.isEmpty) break;
        final requestId = data['requestId'] as String? ?? '';
        final feedbackConfigurationId =
            data['feedbackConfigurationId'] as String? ?? formId;
        final questionId = data['questionId'] as String? ?? '';
        final rawConversation = data['conversation'];
        final conversation = <QnaWithAiConversationTurn>[];
        if (rawConversation is List) {
          for (final item in rawConversation) {
            if (item is Map<String, dynamic>) {
              conversation.add(
                QnaWithAiConversationTurn(
                  question: item['question'] as String? ?? '',
                  answer: item['answer'] as String? ?? '',
                ),
              );
            }
          }
        }

        Encatch.streamQnaWithAi(
              QnaWithAiRequest(
                feedbackConfigurationId: feedbackConfigurationId,
                questionId: questionId,
                conversation: conversation,
              ),
              onChunk: (chunk) {
                _injectSdkMessage(SdkMessageType.qnaWithAiChunk, {
                  'requestId': requestId,
                  'chunk': chunk,
                });
              },
            )
            .then((res) {
              _injectSdkMessage(SdkMessageType.qnaWithAiDone, {
                'requestId': requestId,
                'answer': res.answer,
              });
            })
            .catchError((Object e) {
              _injectSdkMessage(SdkMessageType.qnaWithAiResponse, {
                'requestId': requestId,
                'error': e.toString(),
              });
            });

      case FormMessageType.formRemindMeLater:
        Encatch.emitEvent(
          EventType.formRemindMeLater,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );
        Encatch.trackFormEvent(
          'form:remindmelater',
          data['feedbackConfigurationId'] as String?,
        ).catchError((_) {});
        widget.onClose();

      case FormMessageType.formCtaTriggered:
        final action = data['action'] as String?;
        final urlStr = data['url'] as String?;

        if (action == 'app_navigate') {
          // Emit first so host Encatch.on() subscribers can navigate, then close
          // the overlay the same way form:close does for redirect/dismiss CTAs.
          Encatch.emitEvent(
            EventType.formCtaTriggered,
            EventPayload(
              formId: formId,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              data: data,
            ),
          );
          widget.onClose();
        } else if ((action == 'redirect_internal' || action == 'redirect_external') &&
            urlStr != null) {
          final uri = Uri.tryParse(urlStr);
          if (uri != null) {
            // redirect_internal → SFSafariViewController (iOS) / Chrome Custom Tabs (Android)
            // redirect_external → system browser (Safari / default browser)
            final mode = action == 'redirect_internal'
                ? LaunchMode.inAppBrowserView
                : LaunchMode.externalApplication;
            launchUrl(uri, mode: mode).catchError((Object e) {
              // ignore: avoid_print
              print('[${widget.logTag}] ctaTriggered: failed to open URL ($action): $e');
              return false;
            });
          }
          // Form closes automatically via the form:close message sent by the engine.
          Encatch.emitEvent(
            EventType.formCtaTriggered,
            EventPayload(
              formId: formId,
              timestamp: DateTime.now().millisecondsSinceEpoch,
              data: data,
            ),
          );
        }

      case null:
        break;
    }
  }

  // ============================================================================
  // Build
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    final url = _buildUrl();

    return InAppWebView(
      gestureRecognizers: {
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      },
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        useWideViewPort: false,
        loadWithOverviewMode: false,
        disallowOverScroll: true,
      ),
      onLoadStart: (controller, loadUrl) {
        // ignore: avoid_print
        print('[${widget.logTag}] Load start: $loadUrl');
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url;
        if (uri == null) return NavigationActionPolicy.ALLOW;

        if (navigationAction.isForMainFrame == false) {
          return NavigationActionPolicy.ALLOW;
        }

        final scheme = uri.scheme.toLowerCase();
        if (scheme == 'about' || scheme == 'data' || scheme == 'blob') {
          return NavigationActionPolicy.ALLOW;
        }

        if (scheme != 'https' && scheme != 'http') {
          try {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (e) {
            // ignore: avoid_print
            print('[${widget.logTag}] Failed to open external URL: $e');
          }
          return NavigationActionPolicy.CANCEL;
        }

        try {
          final formUri = Uri.parse(url);
          if (uri.origin == formUri.origin && uri.path == formUri.path) {
            return NavigationActionPolicy.ALLOW;
          }
        } catch (_) {
          return NavigationActionPolicy.CANCEL;
        }

        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          return NavigationActionPolicy.ALLOW;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onWebViewCreated: (controller) {
        _controller = controller;
        controller.addJavaScriptHandler(
          handlerName: 'EncatchFlutterChannel',
          callback: (args) {
            if (args.isEmpty) return;
            try {
              final raw = args[0] as String;
              final msg = jsonDecode(raw) as Map<String, dynamic>;
              _handleWebViewMessage(msg);
            } catch (e) {
              // ignore: avoid_print
              print('[${widget.logTag}] Failed to parse message: $e');
            }
          },
        );
      },
      onPermissionRequest: (controller, request) async {
        // ignore: avoid_print
        print('[${widget.logTag}] permission request: ${request.resources}');
        return PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.GRANT,
        );
      },
      onLoadStop: (controller, loadUrl) {
        // ignore: avoid_print
        print('[${widget.logTag}] Load stop: $loadUrl');
        _logger.debug('WebView loaded: $loadUrl');
        controller
            .evaluateJavascript(
              source: '''
          document.documentElement.style.height = '100%';
          document.body.style.minHeight = '100%';
        ''',
            )
            .catchError((_) {});
        Timer(const Duration(milliseconds: 300), () {
          if (!mounted || _webViewReady) return;
          _handleFormReady(widget.payload.formId);
        });
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        // ignore: avoid_print
        print(
          '[${widget.logTag}] HTTP error: '
          '${errorResponse.statusCode} ${errorResponse.reasonPhrase} '
          '${request.url}',
        );
      },
      onConsoleMessage: (controller, consoleMessage) {
        // ignore: avoid_print
        print(
          '[${widget.logTag}][console] '
          '${consoleMessage.messageLevel}: ${consoleMessage.message}',
        );
      },
      onWebContentProcessDidTerminate: (controller) {
        // ignore: avoid_print
        print('[${widget.logTag}] Web content process terminated');
      },
      onReceivedError: (controller, request, error) {
        // ignore: avoid_print
        print('[${widget.logTag}] Load error: ${error.description}');
        if (request.isForMainFrame == false) return;
        final scheme = request.url.scheme.toLowerCase();
        if (scheme != 'https' && scheme != 'http') return;
        widget.onClose();
      },
    );
  }
}
