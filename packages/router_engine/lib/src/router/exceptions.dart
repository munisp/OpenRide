/// Router exceptions (SPEC §3.4).
library exceptions;

/// Thrown when no route can be found (disconnected network, inaccessible
/// target, empty graph, ...).
class NoRouteException implements Exception {
  final String message;
  const NoRouteException(this.message);

  @override
  String toString() => 'NoRouteException: $message';
}
