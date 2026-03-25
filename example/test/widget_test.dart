import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yt_dlp_dart_example/main.dart';

void main() {
  testWidgets('app loads', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: YtDlpExampleApp(),
      ),
    );
    expect(find.text('yt_dlp_dart example'), findsWidgets);
    expect(find.text('Extract info'), findsOneWidget);
  });
}
