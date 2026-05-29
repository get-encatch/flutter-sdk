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
import 'package:flutter/material.dart';
import 'encatch.dart';
import 'encatch_form_webview_bridge.dart';
import 'form_webview_helpers.dart';
import 'form_webview_skeleton.dart';
import 'types.dart';

// ============================================================================
// Layout helpers (modal-only)
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

// ============================================================================
// EncatchWebView — headless listener widget
// ============================================================================

/// Headless widget that listens for [Encatch.onShowForm] / [Encatch.onDismissForm]
/// and renders the Encatch survey/feedback form as a full-screen overlay using
/// [flutter_inappwebview].
///
/// Place this widget once inside your [EncatchProvider] — no other configuration
/// is required.
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

    // An inline slot is handling this form — clear any active modal and return.
    if (payload.presentation == FormPresentation.inline) {
      _removeEntry();
      return;
    }

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

    // Remove any existing entry before inserting a new one.
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
  // Overlay state
  bool _webViewReady = false;
  bool _isClosing = false;
  bool _useTallMaxHeight = false;

  // Height animation
  late AnimationController _heightController;
  late Animation<double> _heightAnimation;
  double _currentHeight = 300;
  double _targetHeight = 300;
  double? _lastMeasuredContentHeight;
  Timer? _heightDebounceTimer;

  // Entrance / exit animation
  late AnimationController _entranceController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;

  // SDK-triggered programmatic dismiss subscription
  StreamSubscription<DismissPayload>? _dismissSub;

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
  // Position / size helpers
  // ============================================================================

  String get _position =>
      (widget.payload.formConfig.appearanceProperties?['selectedPosition']
          as String?) ??
      'center';

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

  double _visibleHeight(MediaQueryData mediaQuery) {
    return (mediaQuery.size.height - mediaQuery.viewInsets.bottom)
        .clamp(0.0, mediaQuery.size.height)
        .toDouble();
  }

  // ============================================================================
  // Animations
  // ============================================================================

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
  // Height update (debounced, capped at _effectiveMaxHeightFraction of viewport)
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
  // Bridge callbacks
  // ============================================================================

  void _handleBridgeReady() {
    if (!mounted) return;
    setState(() => _webViewReady = true);
    _runEntranceAnimation();
  }

  void _handleBridgeHeightChange(double h) {
    _updateHeight(h);
  }

  void _handleBridgeForceFullHeight(bool force) {
    if (force == _useTallMaxHeight) return;
    setState(() => _useTallMaxHeight = force);
    final last = _lastMeasuredContentHeight;
    if (last != null && last > 0) _updateHeight(last);
  }

  void _handleClose() {
    if (_isClosing || !mounted) return;
    setState(() => _isClosing = true);
    _runExitAnimation(widget.onDismiss);
  }

  // ============================================================================
  // Build
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
    final formTheme = resolveFormWebViewTheme(
      widget.payload,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
      debugLabel: 'EncatchWebView',
    );
    final backgroundColor = formTheme.backgroundColor;
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

    final skeletonMode = formTheme.activeMode;

    // Material is required so widgets like Text, InkWell work correctly
    // inside an OverlayEntry (which has no Material ancestor by default).
    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: _entranceController,
        builder: (context, child) {
          return Opacity(
            opacity: _webViewReady ? _fadeAnimation.value : 1.0,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: _webViewReady ? overlayColor : Colors.transparent,
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
                      backgroundColor: backgroundColor,
                      isCenter: isCenter,
                      skeletonMode: skeletonMode,
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
    required Color backgroundColor,
    required bool isCenter,
    required Brightness skeletonMode,
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
              color: backgroundColor,
              child: SizedBox(
                width: maxWidth,
                height: _heightAnimation.value.clamp(0.0, maxHeight).toDouble(),
                child: Stack(
                  children: [
                    EncatchFormWebViewBridge(
                      payload: widget.payload,
                      logTag: 'EncatchWebView',
                      presentation: FormPresentation.modal,
                      onReady: _handleBridgeReady,
                      onClose: _handleClose,
                      onHeightChange: _handleBridgeHeightChange,
                      onForceFullHeight: _handleBridgeForceFullHeight,
                    ),
                    // Loading skeleton — shown until form:ready fires.
                    if (!_webViewReady)
                      Positioned.fill(
                        child: FormWebViewSkeleton(
                          backgroundColor: backgroundColor,
                          activeMode: skeletonMode,
                        ),
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
}
