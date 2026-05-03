import 'dart:async';

import 'package:http/http.dart' as http;

const Duration kAdminHttpRequestTimeout = Duration(seconds: 30);
const Duration kAdminHealthHttpRequestTimeout = Duration(seconds: 60);

class AdminHttpTimeoutException implements Exception {
  const AdminHttpTimeoutException({
    required this.method,
    required this.uri,
    required this.timeout,
  });

  final String method;
  final Uri uri;
  final Duration timeout;

  @override
  String toString() =>
      'AdminHttpTimeoutException($method $uri after ${timeout.inSeconds}s)';
}

Future<http.Response> sendAdminHttpRequest(
  http.Client client,
  http.BaseRequest request, {
  Duration timeout = kAdminHttpRequestTimeout,
}) async {
  try {
    return await (() async {
      final streamed = await client.send(request);
      return http.Response.fromStream(streamed);
    })().timeout(timeout);
  } on TimeoutException {
    throw AdminHttpTimeoutException(
      method: request.method,
      uri: request.url,
      timeout: timeout,
    );
  }
}
