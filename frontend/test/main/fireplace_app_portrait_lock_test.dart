import 'package:fireplace/main.dart';
import 'package:fireplace/theme/app_scroll_behavior.dart';
import 'package:fireplace/widgets/portrait_lock_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // FireplaceApp now builds PasscodeProvider, which reads its credential from
  // SharedPreferences at boot; without the mock that read never answers under
  // the test binding and leaves its timeout timer pending.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'FireplaceApp wraps routes with PortraitLockShell via MaterialApp.builder',
    (tester) async {
      await tester.pumpWidget(const FireplaceApp());

      expect(find.byType(PortraitLockShell), findsOneWidget);
      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.builder, isNotNull);
    },
  );

  testWidgets(
    'FireplaceApp wires AppScrollBehavior into MaterialApp',
    (tester) async {
      await tester.pumpWidget(const FireplaceApp());

      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.scrollBehavior, isA<AppScrollBehavior>());
    },
  );
}
