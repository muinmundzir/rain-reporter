enum RainIntensity {
  light('light', 'Light'),
  moderate('moderate', 'Moderate'),
  heavy('heavy', 'Heavy'),
  storm('storm', 'Storm'),
  stopped('stopped', 'Stopped');

  const RainIntensity(this.wireName, this.label);

  final String wireName;
  final String label;

  static RainIntensity fromWire(String value) {
    return RainIntensity.values.firstWhere(
      (e) => e.wireName == value,
      orElse: () => RainIntensity.light,
    );
  }
}
