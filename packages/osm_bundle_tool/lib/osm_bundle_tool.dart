/// Public entrypoint for in-app bundle building (SPEC §7 Offline Data import).
///
/// The implementation lives in `src/bundle_build.dart` and is shared with the
/// CLI (`bin/build_bundle.dart`).
library osm_bundle_tool;

export 'src/bundle_build.dart' show buildBundle, OsmDataAdapter;
