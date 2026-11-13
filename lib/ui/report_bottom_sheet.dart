import 'package:flutter/material.dart';
import '../domain/rain_intensity.dart';

class ReportSubmission {
  const ReportSubmission({
    required this.intensity,
    this.note,
  });

  final RainIntensity intensity;
  final String? note;
}

class ReportBottomSheet extends StatefulWidget {
  const ReportBottomSheet({
    super.key,
    required this.onSubmit,
  });

  final ValueChanged<ReportSubmission> onSubmit;

  @override
  State<ReportBottomSheet> createState() => _ReportBottomSheetState();
}

class _ReportBottomSheetState extends State<ReportBottomSheet> {
  RainIntensity _selected = RainIntensity.moderate;
  final TextEditingController _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  void _handleSubmit() {
    final rawNote = _noteController.text.trim();
    widget.onSubmit(
      ReportSubmission(
        intensity: _selected,
        note: rawNote.isEmpty ? null : rawNote,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Report Rain Nearby',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            'Your exact location is fuzzed (~100–200m) for privacy.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: RainIntensity.values.map((intensity) {
              return ChoiceChip(
                label: Text(intensity.label),
                selected: _selected == intensity,
                onSelected: (_) => setState(() => _selected = intensity),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _noteController,
            maxLength: 140,
            decoration: const InputDecoration(
              labelText: 'Optional short note',
              hintText: 'e.g., Heavy wind near station',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _handleSubmit,
            child: const Text('Submit Report'),
          ),
        ],
      ),
    );
  }
}
