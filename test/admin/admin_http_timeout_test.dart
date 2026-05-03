import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:forge_and_flow/admin/services/admin_http_timeout.dart';
import 'package:forge_and_flow/admin/services/feature_flags_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/health_admin_gateway.dart';

void main() {
  test(
    'sendAdminHttpRequest bounds the full request/response future',
    () async {
      final client = _NeverCompletingClient();
      final request = http.Request('GET', Uri.parse('https://proxy.test/slow'));

      await expectLater(
        sendAdminHttpRequest(
          client,
          request,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<AdminHttpTimeoutException>()),
      );
    },
  );

  test(
    'feature flag HTTP gateway maps timeout to a screen-readable error',
    () async {
      final gateway = HttpFeatureFlagsAdminGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'token',
        httpClient: _NeverCompletingClient(),
        timeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        gateway.listFlags(),
        throwsA(
          isA<FeatureFlagsAdminGatewayError>()
              .having((e) => e.statusCode, 'statusCode', 408)
              .having((e) => e.errorCode, 'errorCode', 'timeout'),
        ),
      );
    },
  );

  test(
    'health HTTP gateway maps timeout to the existing health error type',
    () async {
      final gateway = HttpHealthAdminGateway(
        baseUri: Uri.parse('https://proxy.test'),
        httpClient: _NeverCompletingClient(),
        timeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        gateway.fetch(),
        throwsA(
          isA<HealthAdminGatewayError>()
              .having((e) => e.statusCode, 'statusCode', 408)
              .having(
                (e) => e.message,
                'message',
                contains('/health timed out'),
              ),
        ),
      );
    },
  );
}

class _NeverCompletingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future;
  }
}
