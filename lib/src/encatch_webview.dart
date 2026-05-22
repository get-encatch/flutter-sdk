/// EncatchWebView
///
/// Headless widget that listens for Encatch.onShowForm / Encatch.onDismissForm
/// and inserts an OverlayEntry into the root Navigator's Overlay.
///
/// Because it uses the Overlay directly (not navigatorKey), it:
///  - requires zero extra setup from the user
///  - is compatible with Sentry, GetX, and any other SDK that also uses navigatorKey
///  - renders above the bottom nav bar and safe areas automatically
///
/// Usage: place [EncatchWebView] once inside [EncatchProvider] — no other config needed.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'encatch.dart';
import 'logger.dart';
import 'types.dart';

// ============================================================================
// Helpers
// ============================================================================

Color _parseHexColor(String hex, {double opacity = 0.3}) {
  var h = hex.replaceAll('#', '');
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length == 8) {
    final a = int.tryParse(h.substring(0, 2), radix: 16) ?? 0;
    final r = int.tryParse(h.substring(2, 4), radix: 16) ?? 0;
    final g = int.tryParse(h.substring(4, 6), radix: 16) ?? 0;
    final b = int.tryParse(h.substring(6, 8), radix: 16) ?? 0;
    return Color.fromARGB(a, r, g, b);
  }
  if (h.length == 6) {
    final r = int.tryParse(h.substring(0, 2), radix: 16) ?? 0;
    final g = int.tryParse(h.substring(2, 4), radix: 16) ?? 0;
    final b = int.tryParse(h.substring(4, 6), radix: 16) ?? 0;
    return Color.fromARGB((opacity * 255).round(), r, g, b);
  }
  return Colors.black.withValues(alpha: opacity);
}

({MainAxisAlignment main, CrossAxisAlignment cross}) _getPositionAlignment(
  String position,
) {
  MainAxisAlignment main;
  CrossAxisAlignment cross;
  if (position.startsWith('top')) {
    main = MainAxisAlignment.start;
  } else if (position.startsWith('bottom')) {
    main = MainAxisAlignment.end;
  } else {
    main = MainAxisAlignment.center;
  }
  if (position.endsWith('left')) {
    cross = CrossAxisAlignment.start;
  } else if (position.endsWith('right')) {
    cross = CrossAxisAlignment.end;
  } else {
    cross = CrossAxisAlignment.center;
  }
  return (main: main, cross: cross);
}

BorderRadius _getBorderRadius(String position) {
  final hasTop = position.contains('top');
  final hasBottom = position.contains('bottom');
  return BorderRadius.only(
    topLeft: hasTop ? Radius.zero : const Radius.circular(20),
    topRight: hasTop ? Radius.zero : const Radius.circular(20),
    bottomLeft: hasBottom ? Radius.zero : const Radius.circular(20),
    bottomRight: hasBottom ? Radius.zero : const Radius.circular(20),
  );
}

double _calcMaxWidth(double screenWidth) {
  if (screenWidth < 600) return screenWidth;
  if (screenWidth < 1200) return screenWidth * 0.5;
  return screenWidth * 0.4;
}

Color _getPopoverColor(dynamic themeJson, Color fallback) {
  if (themeJson == null || themeJson == '{}') return fallback;
  try {
    final vars = (jsonDecode(themeJson as String) as Map<String, dynamic>);
    final value = vars['--popover'];
    if (value is String && value.isNotEmpty) return _parseHexColor(value);
  } catch (_) {}
  return fallback;
}

Color _resolvePopoverColor(ShowFormPayload? payload) {
  if (payload == null) return Colors.white;
  final appearance = payload.formConfig.appearanceProperties;
  final shareableMode =
      (appearance?['featureSettings']?['shareableMode'] as String?) ?? 'light';
  final activeMode = shareableMode == 'dark' ? 'dark' : 'light';
  final themeJson = appearance?['themes']?[activeMode]?['theme'];
  final fallback = activeMode == 'dark'
      ? const Color(0xFF1a1a1a)
      : Colors.white;
  return _getPopoverColor(themeJson, fallback);
}

// ============================================================================
// EncatchWebView — headless listener widget
// ============================================================================

/// Headless widget that listens for [Encatch.onShowForm] / [Encatch.onDismissForm]
/// and renders the Encatch survey/feedback form as a full-screen overlay using
/// [flutter_inappwebview].
///
/// Place this widget once inside your [EncatchProvider] — no other configuration
/// is required:
///
/// ```dart
/// EncatchProvider(
///   config: EncatchConfig(apiKey: 'YOUR_KEY'),
///   child: MaterialApp(
///     home: Stack(
///       children: [
///         YourApp(),
///         EncatchWebView(),
///       ],
///     ),
///   ),
/// )
/// ```
class EncatchWebView extends StatefulWidget {
  const EncatchWebView({super.key});

  @override
  State<EncatchWebView> createState() => _EncatchWebViewState();
}

class _EncatchWebViewState extends State<EncatchWebView> {
  StreamSubscription<ShowFormPayload>? _showSub;
  StreamSubscription<DismissPayload>? _dismissSub;

  OverlayEntry? _activeEntry;

  @override
  void initState() {
    super.initState();
    _showSub = Encatch.onShowForm.listen(_handleShowForm);
    _dismissSub = Encatch.onDismissForm.listen(_handleDismissForm);
  }

  @override
  void dispose() {
    _showSub?.cancel();
    _dismissSub?.cancel();
    _removeEntry();
    super.dispose();
  }

  void _handleShowForm(ShowFormPayload payload) {
    if (!mounted) return;

    // EncatchWebView lives above MaterialApp so its context has no Navigator.
    // Walk up from the root element to find the first OverlayState instead.
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return;

    OverlayState? overlay;
    void visitor(Element el) {
      if (overlay != null) return;
      if (el is StatefulElement && el.state is OverlayState) {
        overlay = el.state as OverlayState;
        return;
      }
      el.visitChildren(visitor);
    }

    rootElement.visitChildren(visitor);

    if (overlay == null) return;

    // Remove any existing entry before inserting a new one
    _removeEntry();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _EncatchFormOverlay(
        payload: payload,
        onDismiss: () {
          _removeEntry();
          Encatch.setFormVisible(false);
        },
      ),
    );

    _activeEntry = entry;
    overlay!.insert(entry);
    Encatch.setFormVisible(true);
  }

  void _handleDismissForm(DismissPayload _) {
    // The overlay widget (_EncatchFormOverlay) has its own onDismissForm listener
    // and handles the exit animation + calls onDismiss which removes the entry.
    // Nothing to do here; _removeEntry is called via the onDismiss callback.
  }

  void _removeEntry() {
    _activeEntry?.remove();
    _activeEntry = null;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

// ============================================================================
// _EncatchFormOverlay — full-screen overlay content
// ============================================================================

class _EncatchFormOverlay extends StatefulWidget {
  final ShowFormPayload payload;
  final VoidCallback onDismiss;

  const _EncatchFormOverlay({required this.payload, required this.onDismiss});

  @override
  State<_EncatchFormOverlay> createState() => _EncatchFormOverlayState();
}

class _EncatchFormOverlayState extends State<_EncatchFormOverlay>
    with TickerProviderStateMixin {
  // WebView controller
  InAppWebViewController? _controller;

  // Overlay state
  bool _webViewReady = false;
  bool _isClosing = false;

  // Height animation
  late AnimationController _heightController;
  late Animation<double> _heightAnimation;
  double _currentHeight = 300;
  double _targetHeight = 300;
  double? _lastMeasuredContentHeight;
  Timer? _heightDebounceTimer;
  bool _useTallMaxHeight = false;

  // Entrance / exit animation
  late AnimationController _entranceController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;

  // Track which form journeys have already sent form:answered
  final Set<String> _formAnsweredTracked = {};

  // SDK-triggered programmatic dismiss subscription
  StreamSubscription<DismissPayload>? _dismissSub;

  static final _logger = const EncatchLogger(debugMode: false);

  @override
  void initState() {
    super.initState();

    _heightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _heightAnimation = Tween<double>(
      begin: 300,
      end: 300,
    ).animate(_heightController);

    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOut),
    );
    _scaleAnimation = Tween<double>(begin: 0.8, end: 1).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOutBack),
    );
    _slideAnimation = Tween<Offset>(
      begin: Offset.zero,
      end: Offset.zero,
    ).animate(_entranceController);

    // Listen for SDK-triggered dismisses (e.g. from Encatch.dismissForm())
    _dismissSub = Encatch.onDismissForm.listen((_) => _handleClose());
  }

  @override
  void dispose() {
    _dismissSub?.cancel();
    _heightController.dispose();
    _entranceController.dispose();
    _heightDebounceTimer?.cancel();
    super.dispose();
  }

  // ============================================================================
  // Animations
  // ============================================================================

  String get _position =>
      (widget.payload.formConfig.appearanceProperties?['selectedPosition']
          as String?) ??
      'center';

  /// maxDialogHeightPercentInApp (10–100) from featureSettings, converted to a
  /// fraction (0.0–1.0). Defaults to 0.8 when the property is absent.
  double get _maxHeightFraction {
    final raw = widget
        .payload
        .formConfig
        .appearanceProperties?['featureSettings']?['maxDialogHeightPercentInApp'];
    if (raw is num) return (raw.toDouble() / 100.0).clamp(0.1, 1.0);
    return 0.8;
  }

  double get _effectiveMaxHeightFraction =>
      _useTallMaxHeight ? 0.95 : _maxHeightFraction;

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
      final type = question['type'];
      return type == 'qna_with_ai';
    });
  }

  void _applyTallMaxHeight(bool useTallMaxHeight) {
    if (useTallMaxHeight == _useTallMaxHeight) return;

    setState(() => _useTallMaxHeight = useTallMaxHeight);
    final lastMeasuredHeight = _lastMeasuredContentHeight;
    if (lastMeasuredHeight != null && lastMeasuredHeight > 0) {
      _updateHeight(lastMeasuredHeight);
    }
  }

  void _applySectionHeightPolicy(Object? rawSectionIndex) {
    if (rawSectionIndex is! num) return;
    _applyTallMaxHeight(_sectionUsesTallMaxHeight(rawSectionIndex.toInt()));
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

  double _visibleHeight(MediaQueryData mediaQuery) {
    return (mediaQuery.size.height - mediaQuery.viewInsets.bottom)
        .clamp(0.0, mediaQuery.size.height)
        .toDouble();
  }

  void _runEntranceAnimation() {
    final pos = _position;
    Offset beginOffset;
    if (pos.startsWith('top')) {
      beginOffset = const Offset(0, -1);
    } else if (pos.startsWith('bottom')) {
      beginOffset = const Offset(0, 1);
    } else if (pos.endsWith('left')) {
      beginOffset = const Offset(-1, 0);
    } else if (pos.endsWith('right')) {
      beginOffset = const Offset(1, 0);
    } else {
      beginOffset = Offset.zero;
    }
    _slideAnimation = Tween<Offset>(begin: beginOffset, end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _entranceController,
            curve: Curves.easeOutBack,
          ),
        );
    _entranceController.forward(from: 0);
  }

  void _runExitAnimation(VoidCallback onDone) {
    final pos = _position;
    Offset endOffset;
    if (pos.startsWith('top')) {
      endOffset = const Offset(0, -1);
    } else if (pos.startsWith('bottom')) {
      endOffset = const Offset(0, 1);
    } else if (pos.endsWith('left')) {
      endOffset = const Offset(-1, 0);
    } else if (pos.endsWith('right')) {
      endOffset = const Offset(1, 0);
    } else {
      endOffset = Offset.zero;
    }
    _slideAnimation = Tween<Offset>(begin: Offset.zero, end: endOffset).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeIn),
    );
    _entranceController.reverse(from: 1).then((_) => onDone());
  }

  // ============================================================================
  // Height update (debounced, capped at _maxHeightFraction of viewport; defaults to 80%)
  // ============================================================================

  void _updateHeight(double newHeight) {
    _lastMeasuredContentHeight = newHeight;
    _heightDebounceTimer?.cancel();
    _heightDebounceTimer = Timer(const Duration(milliseconds: 10), () {
      if (!mounted) return;
      final visibleHeight = _visibleHeight(MediaQuery.of(context));
      final capped = newHeight
          .clamp(0.0, visibleHeight * _effectiveMaxHeightFraction)
          .toDouble();
      if ((capped - _targetHeight).abs() > 1) {
        setState(() {
          _targetHeight = capped;
          _heightAnimation = Tween<double>(begin: _currentHeight, end: capped)
              .animate(
                CurvedAnimation(
                  parent: _heightController,
                  curve: Curves.easeOut,
                ),
              );
          _currentHeight = capped;
        });
        _heightController.forward(from: 0);
      }
    });
  }

  // ============================================================================
  // Close handlers
  // ============================================================================

  void _handleClose() {
    if (_isClosing || !mounted) return;
    setState(() => _isClosing = true);
    _runExitAnimation(widget.onDismiss);
  }

  // ============================================================================
  // Native → WebView message injection
  // ============================================================================

  void _injectSdkMessage(SdkMessageType type, Map<String, dynamic> data) {
    if (_controller == null) return;
    final msg = jsonEncode({'type': type.value, 'data': data});
    final js =
        '''
      window.dispatchEvent(new MessageEvent('message', { data: $msg }));
      true;
    ''';
    _controller!.evaluateJavascript(source: js).catchError((_) {});
  }

  void _handleFormReady(String formId) {
    if (!mounted) return;

    final payload = widget.payload;
    final config = payload.formConfig;
    // ignore: avoid_print
    print('[EncatchWebView] form ready received: $formId');

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
      _runEntranceAnimation();
    }
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
        print('[EncatchWebView] form resize: $h');
        if (h is num && h > 0) _updateHeight(h.toDouble());

      case FormMessageType.formCloseButton:
        // Close button is rendered by the web form itself — no native action needed.
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
        _handleClose();

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
        _handleClose();

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
        print('[EncatchWebView] form:error received: $data');
        Encatch.emitEvent(
          EventType.formError,
          EventPayload(
            formId: formId,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            data: data,
          ),
        );

      case FormMessageType.formLayout:
        _applyTallMaxHeight(_messageRequestsTallMaxHeight(data));
        break;

      case FormMessageType.formReadyToDismiss:
        // No-op: partial-submit-before-dismiss is now handled by the web form itself.
        break;

      case FormMessageType.formUploadFileRequest:
        if (data.isEmpty) break;
        final requestId = data['requestId'] as String? ?? '';
        // The web form sends raw base64 content (no data-URI prefix).
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
        _handleClose();

      case null:
        break;
    }
  }

  // ============================================================================
  // Build WebView URL
  // ============================================================================

  String get _webViewUrl {
    final base = Encatch.webHost;
    final formId = widget.payload.formId;
    final params = <String, String>{'formId': formId};
    if (Encatch.debugMode) params['debug'] = 'true';
    return '$base/s/flutter-sdk-form?${params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
  }

  // ============================================================================
  // Render
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final maxHeight = _visibleHeight(mediaQuery) * _effectiveMaxHeightFraction;
    final maxWidth = _calcMaxWidth(screenSize.width);
    final pos = _position;
    final alignment = _getPositionAlignment(pos);
    final borderRadius = _getBorderRadius(pos);
    final popoverColor = _resolvePopoverColor(widget.payload);
    final overlayColor = _parseHexColor(
      (widget
                  .payload
                  .formConfig
                  .appearanceProperties?['themes']?['dark']?['overlayColor']
              as String?) ??
          '#000000',
      opacity: 0.3,
    );
    final isCenter = pos == 'center';
    // ignore: avoid_print
    print(
      '[EncatchWebView] build ready=$_webViewReady '
      'size=${screenSize.width}x${screenSize.height} '
      'keyboardInset=$keyboardInset maxHeight=$maxHeight '
      'height=$_currentHeight',
    );

    // Material is required so widgets like Text, InkWell work correctly
    // inside an OverlayEntry (which has no Material ancestor by default).
    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: _entranceController,
        builder: (context, child) {
          return Opacity(
            opacity: _webViewReady ? _fadeAnimation.value : 0.0,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: overlayColor,
              child: AnimatedPadding(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(bottom: keyboardInset),
                child: Column(
                  mainAxisAlignment: alignment.main,
                  crossAxisAlignment: alignment.cross,
                  children: [
                    _buildPopup(
                      maxWidth: maxWidth,
                      maxHeight: maxHeight,
                      borderRadius: borderRadius,
                      popoverColor: popoverColor,
                      isCenter: isCenter,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPopup({
    required double maxWidth,
    required double maxHeight,
    required BorderRadius borderRadius,
    required Color popoverColor,
    required bool isCenter,
  }) {
    return Transform(
      transform: isCenter
          ? (Matrix4.identity()..scaleByDouble(
              _scaleAnimation.value,
              _scaleAnimation.value,
              _scaleAnimation.value,
              1.0,
            ))
          : Matrix4.translationValues(
              _slideAnimation.value.dx * maxWidth,
              _slideAnimation.value.dy * 200,
              0,
            ),
      alignment: Alignment.center,
      child: AnimatedBuilder(
        animation: _heightAnimation,
        builder: (context, child) {
          return ClipRRect(
            borderRadius: borderRadius,
            clipBehavior: Clip.hardEdge,
            child: ColoredBox(
              color: popoverColor,
              child: SizedBox(
                width: maxWidth,
                height: _heightAnimation.value.clamp(0.0, maxHeight).toDouble(),
                child: _buildWebView(),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildWebView() {
    final url = _webViewUrl;
    if (url.isEmpty) return const SizedBox.shrink();

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
        // Force the native WKWebView/WebView to fill its Flutter bounds
        // rather than shrinking to content height.
        useWideViewPort: false,
        loadWithOverviewMode: false,
        // Disable iOS rubber-band bounce effect
        disallowOverScroll: true,
      ),
      onLoadStart: (controller, url) {
        // ignore: avoid_print
        print('[EncatchWebView] Load start: $url');
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final uri = navigationAction.request.url;
        if (uri == null) return NavigationActionPolicy.ALLOW;

        // Allow subframe navigation freely (e.g. Calendly/scheduler iframes)
        if (navigationAction.isForMainFrame == false) {
          return NavigationActionPolicy.ALLOW;
        }

        // Allow special schemes and data URLs in-page
        final scheme = uri.scheme.toLowerCase();
        if (scheme == 'about' || scheme == 'data' || scheme == 'blob') {
          return NavigationActionPolicy.ALLOW;
        }

        // Custom schemes (upi://, intent://, etc.) cannot be loaded by
        // WKWebView/Android WebView. Hand them to the OS instead.
        if (scheme != 'https' && scheme != 'http') {
          try {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (e) {
            // ignore: avoid_print
            print('[EncatchWebView] Failed to open external URL: $e');
          }
          return NavigationActionPolicy.CANCEL;
        }

        // Allow the initial form page load (same origin + path)
        try {
          final formUri = Uri.parse(url);
          if (uri.origin == formUri.origin && uri.path == formUri.path) {
            return NavigationActionPolicy.ALLOW;
          }
        } catch (_) {
          return NavigationActionPolicy.CANCEL;
        }

        // Open all other http/https links in the system browser.
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
              print('[EncatchWebView] Failed to parse message: $e');
            }
          },
        );
      },
      onPermissionRequest: (controller, request) async {
        // ignore: avoid_print
        print('[EncatchWebView] permission request: ${request.resources}');
        return PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.GRANT,
        );
      },
      onLoadStop: (controller, url) {
        // ignore: avoid_print
        print('[EncatchWebView] Load stop: $url');
        _logger.debug('WebView loaded: $url');
        // Force html/body to fill the full native WebView frame so the
        // Flutter ColoredBox background isn't visible behind short content.
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
          // On real iOS devices, the page can fire form:ready before
          // flutter_inappwebview has injected its JS handler.
          _handleFormReady(widget.payload.formId);
        });
      },
      onReceivedHttpError: (controller, request, errorResponse) {
        // ignore: avoid_print
        print(
          '[EncatchWebView] HTTP error: '
          '${errorResponse.statusCode} ${errorResponse.reasonPhrase} '
          '${request.url}',
        );
      },
      onConsoleMessage: (controller, consoleMessage) {
        // ignore: avoid_print
        print(
          '[EncatchWebView][console] '
          '${consoleMessage.messageLevel}: ${consoleMessage.message}',
        );
      },
      onWebContentProcessDidTerminate: (controller) {
        // ignore: avoid_print
        print('[EncatchWebView] Web content process terminated');
      },
      onReceivedError: (controller, request, error) {
        // ignore: avoid_print
        print('[EncatchWebView] Load error: ${error.description}');
        if (request.isForMainFrame == false) return;
        final scheme = request.url.scheme.toLowerCase();
        if (scheme != 'https' && scheme != 'http') return;
        _handleClose();
      },
    );
  }
}
