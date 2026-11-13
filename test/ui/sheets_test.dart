import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rain_reporter/domain/rain_intensity.dart';
import 'package:rain_reporter/domain/rain_report.dart';
import 'package:rain_reporter/ui/pin_detail_bottom_sheet.dart';
import 'package:rain_reporter/ui/report_bottom_sheet.dart';

void main() {
  testWidgets('ReportBottomSheet selects intensity and submits note', (tester) async {
    ReportSubmission? submitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportBottomSheet(
            onSubmit: (value) => submitted = value,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Heavy'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Visibility low');
    await tester.tap(find.text('Submit Report'));
    await tester.pump();

    expect(submitted, isNotNull);
    expect(submitted!.intensity, RainIntensity.heavy);
    expect(submitted!.note, 'Visibility low');
  });

  testWidgets('PinDetailBottomSheet displays report details and triggers vote callbacks', (tester) async {
    var confirmed = false;
    var stopped = false;
    final t0 = DateTime.utc(2026, 11, 13, 10, 0);
    final report = RainReport.create(
      id: 'r1',
      uid: 'u1',
      intensity: RainIntensity.storm,
      note: 'Thunder and heavy wind',
      lat: -6.2,
      lng: 106.8,
      createdAt: t0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PinDetailBottomSheet(
            report: report,
            now: t0.add(const Duration(minutes: 4)),
            onConfirmStillRaining: () => confirmed = true,
            onMarkStopped: () => stopped = true,
          ),
        ),
      ),
    );

    expect(find.textContaining('Storm'), findsOneWidget);
    expect(find.text('Thunder and heavy wind'), findsOneWidget);
    expect(find.textContaining('4m ago'), findsOneWidget);

    await tester.tap(find.text('Still raining'));
    expect(confirmed, isTrue);

    await tester.tap(find.text('Stopped here'));
    expect(stopped, isTrue);
  });
}
