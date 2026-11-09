/// Bridge to packages/shared (owner AGENT-A), imported via RELATIVE path per
/// SPEC §9.
///
/// IMPORT MODE: real (packages/shared/lib/shared.dart from agent-a is present
/// in this branch). If shared is unavailable in a standalone checkout, create
/// a minimal local GeoPoint mirror matching SPEC §2 and export that instead.
library;

export 'package:shared/shared.dart';
