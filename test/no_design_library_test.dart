// The SDK's own code uses Flutter's widgets library only. Flutter 3.50
// deprecated `package:flutter/material.dart` and `cupertino.dart`, and their
// replacements (`material_ui`, `cupertino_ui`) need a newer Flutter than the
// SDK supports. Using neither keeps the SDK working in apps on either side.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/ imports no Material or Cupertino library', () {
    final designLibrary = RegExp(
      r'''^\s*(import|export)\s+['"]package:(flutter/(material|cupertino)\.dart|material_ui/|cupertino_ui/)''',
      multiLine: true,
    );
    final offenders =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'))
            .where((file) => designLibrary.hasMatch(file.readAsStringSync()))
            .map((file) => file.path)
            .toList()
          ..sort();

    expect(offenders, isEmpty);
  });
}
