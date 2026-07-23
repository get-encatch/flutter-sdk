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
import 'modal_backdrop_blur.dart';
import 'types.dart';

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

  /// Updated each build — used to ignore form:resize in full-center mode.
  bool _isFullCenter = false;

  /// Updated each build — debounced height cap (mirrors RN maxDialogHeightRef).
  double _maxDialogHeightPx = 0;

  Map<String, dynamic>? get _appearanceProperties =>
      widget.payload.formConfig.appearanceProperties;

  String _effectivePosition(double screenWidth) => normalizePosition(
    resolveSelectedPositionFromFormConfig(_appearanceProperties),
    screenWidth,
  );

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

    // Match RN: fade backdrop + animate card in immediately on showForm so the
    // skeleton is visible while the WebView boots — not after form:ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pos = _effectivePosition(MediaQuery.sizeOf(context).width);
      _runEntranceAnimation(pos);
    });
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

  double _usableHeight(MediaQueryData mediaQuery) {
    final padding = mediaQuery.padding;
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final height =
        mediaQuery.size.height -
        padding.top -
        (keyboardInset > 0 ? 0 : padding.bottom) -
        keyboardInset;
    return height.clamp(100.0, mediaQuery.size.height).toDouble();
  }

  double _resolveMaxDialogHeightPx(
    MediaQueryData mediaQuery,
    String effectivePosition,
  ) {
    final usableHeight = _usableHeight(mediaQuery);
    final maxHeightFraction = resolveMaxHeightFractionFromFormConfig(
      _appearanceProperties,
    );
    return resolveMaxDialogHeightPx(
      position: effectivePosition,
      usableHeightPx: usableHeight,
      maxHeightFraction: maxHeightFraction,
      keyboardVisible: mediaQuery.viewInsets.bottom > 0,
      useTallMaxHeight: _useTallMaxHeight,
    );
  }

  // ============================================================================
  // Animations
  // ============================================================================

  void _runEntranceAnimation(String pos) {
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

  void _runExitAnimation(String pos, VoidCallback onDone) {
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
    if (_isFullCenter || _useTallMaxHeight) return;
    _lastMeasuredContentHeight = newHeight;
    _heightDebounceTimer?.cancel();
    _heightDebounceTimer = Timer(const Duration(milliseconds: 10), () {
      if (!mounted || _isFullCenter || _useTallMaxHeight) return;
      final cap = _maxDialogHeightPx > 0
          ? _maxDialogHeightPx
          : _resolveMaxDialogHeightPx(
              MediaQuery.of(context),
              _effectivePosition(MediaQuery.sizeOf(context).width),
            );
      final capped = newHeight.clamp(0.0, cap).toDouble();
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
  }

  void _handleBridgeHeightChange(double h) {
    _updateHeight(h);
  }

  void _handleBridgeForceFullHeight(bool force) {
    if (force == _useTallMaxHeight) return;
    setState(() => _useTallMaxHeight = force);
    final last = _lastMeasuredContentHeight;
    if (last != null && last > 0) {
      _updateHeight(last);
    }
  }

  void _handleClose() {
    if (_isClosing || !mounted) return;
    setState(() => _isClosing = true);
    final pos = _effectivePosition(MediaQuery.sizeOf(context).width);
    _runExitAnimation(pos, widget.onDismiss);
  }

  // ============================================================================
  // Build
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final screenSize = mediaQuery.size;
    final safePadding = mediaQuery.padding;
    final keyboardInset = mediaQuery.viewInsets.bottom;
    final appearanceProperties = _appearanceProperties;
    final effectivePosition = _effectivePosition(screenSize.width);
    _isFullCenter = effectivePosition == 'full-center';
    final inAppSize = resolveInAppSizeFromFormConfig(appearanceProperties);
    final horizontalSafeInset = (safePadding.left > safePadding.right
        ? safePadding.left
        : safePadding.right);
    final popupWidth = resolveInAppMaxWidthPx(
      inAppSize,
      effectivePosition,
      screenSize.width,
      horizontalInsetPx: _isFullCenter ? 0 : horizontalSafeInset,
    );
    final usableHeight = _usableHeight(mediaQuery);
    _maxDialogHeightPx = _resolveMaxDialogHeightPx(
      mediaQuery,
      effectivePosition,
    );
    final maxHeight = _maxDialogHeightPx;
    final forcedHeight = usableHeight * 0.95;
    final usesFixedViewportHeight = _useTallMaxHeight;
    final alignment = getPositionAlignment(effectivePosition);
    final corners = resolveCornersFromFormConfig(appearanceProperties);
    final borderRadius = getBorderRadii(effectivePosition, corners: corners);
    final formTheme = resolveFormWebViewTheme(
      widget.payload,
      systemBrightness: MediaQuery.platformBrightnessOf(context),
      debugLabel: 'EncatchWebView',
    );
    final backgroundColor = formTheme.backgroundColor;
    final darkOverlay = resolveDarkOverlayFromFormConfig(appearanceProperties);
    final modalOverlayBackgroundColor = resolveModalOverlayBackgroundColor(
      appearanceProperties: appearanceProperties,
      activeMode: formTheme.activeMode,
      darkOverlay: darkOverlay,
    );
    final usesScaleAnimation = isCenterAlignedPosition(effectivePosition);
    final shellPadding = EdgeInsets.only(
      top: safePadding.top,
      bottom: keyboardInset > 0 ? keyboardInset : safePadding.bottom,
      left: _isFullCenter ? 0 : safePadding.left,
      right: _isFullCenter ? 0 : safePadding.right,
    );
    // ignore: avoid_print
    print(
      '[EncatchWebView] build ready=$_webViewReady '
      'size=${screenSize.width}x${screenSize.height} '
      'keyboardInset=$keyboardInset maxHeight=$maxHeight '
      'height=$_currentHeight target=$_targetHeight anim=${_heightAnimation.value}',
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
            opacity: _fadeAnimation.value,
            child: Container(
              width: double.infinity,
              height: double.infinity,
              color: modalOverlayBackgroundColor,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (!darkOverlay)
                    ModalBackdropBlur(activeMode: formTheme.activeMode),
                  Padding(
                    padding: shellPadding,
                    child: Column(
                      mainAxisAlignment: _isFullCenter
                          ? MainAxisAlignment.start
                          : alignment.main,
                      crossAxisAlignment: _isFullCenter
                          ? CrossAxisAlignment.stretch
                          : alignment.cross,
                      children: [
                        if (_isFullCenter)
                          Expanded(
                            child: _buildPopup(
                              popupWidth: popupWidth,
                              maxHeight: maxHeight,
                              forcedHeight: forcedHeight,
                              borderRadius: borderRadius,
                              backgroundColor: backgroundColor,
                              usesScaleAnimation: usesScaleAnimation,
                              usesFixedViewportHeight: true,
                              skeletonMode: skeletonMode,
                            ),
                          )
                        else
                          _buildPopup(
                            popupWidth: popupWidth,
                            maxHeight: maxHeight,
                            forcedHeight: forcedHeight,
                            borderRadius: borderRadius,
                            backgroundColor: backgroundColor,
                            usesScaleAnimation: usesScaleAnimation,
                            usesFixedViewportHeight: usesFixedViewportHeight,
                            skeletonMode: skeletonMode,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPopup({
    required double popupWidth,
    required double maxHeight,
    required double forcedHeight,
    required BorderRadius borderRadius,
    required Color backgroundColor,
    required bool usesScaleAnimation,
    required bool usesFixedViewportHeight,
    required Brightness skeletonMode,
  }) {
    return Transform(
      transform: usesScaleAnimation
          ? (Matrix4.identity()..scaleByDouble(
              _scaleAnimation.value,
              _scaleAnimation.value,
              _scaleAnimation.value,
              1.0,
            ))
          : Matrix4.translationValues(
              _slideAnimation.value.dx * popupWidth,
              _slideAnimation.value.dy * 200,
              0,
            ),
      alignment: Alignment.center,
      child: usesFixedViewportHeight && _isFullCenter
          ? ClipRRect(
              borderRadius: borderRadius,
              clipBehavior: Clip.hardEdge,
              child: ColoredBox(
                color: backgroundColor,
                child: _buildPopupContent(
                  backgroundColor: backgroundColor,
                  skeletonMode: skeletonMode,
                ),
              ),
            )
          : AnimatedBuilder(
              animation: _heightAnimation,
              builder: (context, child) {
                final popupHeight = usesFixedViewportHeight
                    ? forcedHeight
                    : _heightAnimation.value.clamp(0.0, maxHeight).toDouble();
                // The drop shadow lives on this outer DecoratedBox so it isn't
                // cut off by the ClipRRect below, which clips the rounded
                // corners of the actual popup content.
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    boxShadow: getModalPopupShadowStyle(),
                  ),
                  child: ClipRRect(
                    borderRadius: borderRadius,
                    clipBehavior: Clip.hardEdge,
                    child: ColoredBox(
                      color: backgroundColor,
                      child: SizedBox(
                        width: popupWidth,
                        height: popupHeight,
                        child: _buildPopupContent(
                          backgroundColor: backgroundColor,
                          skeletonMode: skeletonMode,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Widget _buildPopupContent({
    required Color backgroundColor,
    required Brightness skeletonMode,
  }) {
    return Stack(
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
        if (!_webViewReady)
          Positioned.fill(
            child: FormWebViewSkeleton(
              backgroundColor: backgroundColor,
              activeMode: skeletonMode,
            ),
          ),
      ],
    );
  }
}
