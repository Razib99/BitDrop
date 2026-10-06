import 'package:bitdrop/app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('boots to Home with the mock core', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: BitDropApp()));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('BitDrop'), findsWidgets);

    // Disposing the scope cancels the mock core's tickers so no timer leaks
    // into the next test.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 60));
  });
}
