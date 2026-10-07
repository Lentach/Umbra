import 'package:fireplace/providers/settings_provider.dart';
import 'package:fireplace/widgets/boot_honeycomb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host({required bool disableAnimations}) => ChangeNotifierProvider(
  create: (_) => SettingsProvider(),
  child: MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: const Scaffold(body: Center(child: BootHoneycomb())),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('animates the ripple and bar while motion is allowed', (
    tester,
  ) async {
    await tester.pumpWidget(_host(disableAnimations: false));
    expect(tester.hasRunningAnimations, isTrue);
  });

  testWidgets('reduce-motion parks the loop so the screen can settle', (
    tester,
  ) async {
    await tester.pumpWidget(_host(disableAnimations: true));
    // pumpAndSettle only returns once no frame is scheduled; a repeating
    // controller that ignored the setting would time it out.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });
}
