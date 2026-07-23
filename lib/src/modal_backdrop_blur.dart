/// Frosted backdrop for modal overlays when darkOverlay is off.
/// Mirrors RN ModalBackdropBlur.tsx (expo-blur intensity 52 iOS / 72 Android).
library;

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

/// expo-blur intensity 52 (iOS) / 72 (Android) — Flutter sigma is visually
/// stronger than expo intensity, so use ~intensity × 0.065 (not 1:1).
const double modalBackdropBlurSigmaAndroid = 3.5;
const double modalBackdropBlurSigmaIos = 2.5;

class ModalBackdropBlur extends StatelessWidget {
  final Brightness activeMode;

  const ModalBackdropBlur({super.key, required this.activeMode});

  @override
  Widget build(BuildContext context) {
    final sigma = Platform.isAndroid
        ? modalBackdropBlurSigmaAndroid
        : modalBackdropBlurSigmaIos;

    return IgnorePointer(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        // No extra tint layer — RN BlurView tint is part of the native blur only.
        child: const ColoredBox(color: Colors.transparent),
      ),
    );
  }
}
