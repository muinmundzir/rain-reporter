import 'package:flutter/material.dart';
import '../domain/rain_report.dart';

class PinDetailBottomSheet extends StatelessWidget {
  const PinDetailBottomSheet({
    super.key,
    required this.report,
    required this.now,
    required this.onConfirmStillRaining,
    required this.onMarkStopped,
  });

  final RainReport report;
  final DateTime now;
  final VoidCallback onConfirmStillRaining;
  final VoidCallback onMarkStopped;

  @override
  Widget build(BuildContext context) {
    final minutesAgo = now.difference(report.createdAt).inMinutes.clamp(0, 999);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${report.intensity.label} Rain',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Chip(
                label: Text('${minutesAgo}m ago'),
              ),
            ],
          ),
          if (report.note != null) ...[
            const SizedBox(height: 8),
            Text(
              report.note!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Confirmed by ${report.confirmCount} user(s)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onConfirmStillRaining,
                  icon: const Icon(Icons.water_drop),
                  label: const Text('Still raining'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onMarkStopped,
                  icon: const Icon(Icons.wb_sunny_outlined),
                  label: const Text('Stopped here'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
