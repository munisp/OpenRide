/// Small shared XML helpers for the GPX/TCX writers.
library;

String xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// ISO-8601 UTC with millisecond precision, e.g. 2024-06-01T10:15:30.123Z
String isoUtc(DateTime t) {
  final u = t.toUtc();
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return '${p(u.year, 4)}-${p(u.month)}-${p(u.day)}'
      'T${p(u.hour)}:${p(u.minute)}:${p(u.second)}.${p(u.millisecond, 3)}Z';
}

String fmtNum(double v, [int decimals = 7]) => v.toStringAsFixed(decimals);
