// Zero-dependency test harness for packages/osm_bundle_tool (SPEC §8).
//
// maps_core is a declared path dependency (pubspec.yaml), so the end-to-end
// test in e2e_bundle_test.dart always runs unconditionally.
import 'dart:io';

int _passed = 0;
int _failed = 0;

Future<void> main() async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', 'test/e2e_bundle_test.dart'],
    workingDirectory: Directory.current.path,
  );
  if (result.exitCode == 0) {
    _passed++;
    stdout.writeln('PASS end-to-end tiny extract -> bundle files exist & load');
  } else {
    _failed++;
    stdout.writeln('FAIL end-to-end tiny extract -> bundle files exist & load');
    stdout.writeln(result.stdout);
    stdout.writeln(result.stderr);
  }

  stdout.writeln('---');
  stdout.writeln('osm_bundle_tool: $_passed passed, $_failed failed');
  if (_failed > 0) exit(1);
}
