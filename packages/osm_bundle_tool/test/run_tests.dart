// Zero-dependency test harness for packages/osm_bundle_tool (SPEC §8).
//
// maps_core is a declared path dependency (pubspec.yaml), so the end-to-end
// test in e2e_bundle_test.dart always runs unconditionally.
import 'dart:io';

int _passed = 0;
int _failed = 0;

Future<void> _run(String name, String script) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    ['run', script],
    workingDirectory: Directory.current.path,
  );
  if (result.exitCode == 0) {
    _passed++;
    stdout.writeln('PASS $name');
  } else {
    _failed++;
    stdout.writeln('FAIL $name');
    stdout.writeln(result.stdout);
    stdout.writeln(result.stderr);
  }
}

Future<void> main() async {
  await _run('end-to-end tiny extract -> bundle files exist & load',
      'test/e2e_bundle_test.dart');
  await _run('bbox extract keeps interior ways+nodes, drops exterior',
      'test/bbox_extract_test.dart');
  await _run('mbf split-and-merge: merged store readable, split == direct',
      'test/mbf_merge_test.dart');

  stdout.writeln('---');
  stdout.writeln('osm_bundle_tool: $_passed passed, $_failed failed');
  if (_failed > 0) exit(1);
}
