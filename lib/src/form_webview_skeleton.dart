/// Theme-aware WebView loading skeleton overlay.
///
/// Used as a [Stack] overlay on top of an [InAppWebView], covering the full
/// loading gap — from widget mount through native HTTP fetch and JS
/// initialisation — until `form:ready` fires and the WebView becomes ready.
///
/// Mirrors FormWebViewLoading.tsx / FormWebViewSkeleton from the React Native SDK.
library;

import 'package:flutter/material.dart';

class FormWebViewSkeleton extends StatefulWidget {
  final Color backgroundColor;

  /// [Brightness.dark] renders lighter skeleton rows; [Brightness.light] renders
  /// darker rows — matching the RN skeleton row colours.
  final Brightness activeMode;

  const FormWebViewSkeleton({
    super.key,
    required this.backgroundColor,
    required this.activeMode,
  });

  @override
  State<FormWebViewSkeleton> createState() => _FormWebViewSkeletonState();
}

class _FormWebViewSkeletonState extends State<FormWebViewSkeleton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    // Pulse 0.4 → 1.0 → 0.4, 700 ms each direction — mirrors RN skeleton.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _opacity = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color get _rowColor => widget.activeMode == Brightness.dark
      ? const Color(0x1AFFFFFF) // rgba(255,255,255,0.10)
      : const Color(0x14000000); // rgba(0,0,0,0.08)

  Widget _row({
    required double height,
    required double widthFraction,
    double marginBottom = 0,
    double borderRadius = 6,
    AlignmentGeometry? alignment,
  }) {
    return FractionallySizedBox(
      widthFactor: widthFraction,
      alignment: alignment ?? AlignmentDirectional.centerStart,
      child: Container(
        height: height,
        margin: EdgeInsets.only(bottom: marginBottom),
        decoration: BoxDecoration(
          color: _rowColor,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
    );
  }

  Widget _fullSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header bar — ~16 px tall, 60% wide
          _row(
            height: 16,
            widthFraction: 0.6,
            marginBottom: 24,
            borderRadius: 8,
          ),
          // Question text row 1 — 12 px, 90% wide
          _row(height: 12, widthFraction: 0.9, marginBottom: 10),
          // Question text row 2 — 12 px, 65% wide
          _row(height: 12, widthFraction: 0.65, marginBottom: 24),
          // Input block — 44 px, full width
          _row(
            height: 44,
            widthFraction: 1.0,
            marginBottom: 20,
            borderRadius: 10,
          ),
          // Button — 44 px, 50% wide, centred
          _row(
            height: 44,
            widthFraction: 0.5,
            borderRadius: 10,
            alignment: Alignment.center,
          ),
        ],
      ),
    );
  }

  Widget _mediumSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(height: 14, widthFraction: 0.6, marginBottom: 18),
          _row(height: 12, widthFraction: 0.9, marginBottom: 8),
          _row(height: 12, widthFraction: 0.65, marginBottom: 18),
          _row(height: 40, widthFraction: 1.0, borderRadius: 10),
        ],
      ),
    );
  }

  Widget _compactSkeleton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row(height: 12, widthFraction: 0.6, marginBottom: 12),
          _row(height: 10, widthFraction: 0.85, marginBottom: 8),
          _row(height: 32, widthFraction: 1.0, borderRadius: 8),
        ],
      ),
    );
  }

  Widget _tinySkeleton(double availableHeight) {
    if (availableHeight <= 0) return const SizedBox.shrink();

    final barHeight = (availableHeight * 0.35)
        .clamp(1.0, 12.0)
        .clamp(0.0, availableHeight)
        .toDouble();

    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.45,
        child: Container(
          height: barHeight,
          decoration: BoxDecoration(
            color: _rowColor,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }

  Widget _skeletonForHeight(double height) {
    if (height >= 240) return _fullSkeleton();
    if (height >= 140) return _mediumSkeleton();
    if (height >= 80) return _compactSkeleton();
    return _tinySkeleton(height);
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: widget.backgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return FadeTransition(
            opacity: _opacity,
            child: _skeletonForHeight(constraints.maxHeight),
          );
        },
      ),
    );
  }
}
