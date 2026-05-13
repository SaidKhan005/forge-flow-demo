// Slice C-5 - mobile handoff deep-link gateway.
//
// Wraps Lane B B11.1's low-level HandoffCodeClient with the URL shape
// mobile Settings needs: mint a short-TTL code from the proxy, then build
// the Operator Web landing URL. The proxy still receives the code only in
// JSON bodies; the browser URL belongs to the Operator Web app.

import 'dart:async';
import 'dart:io';

import 'handoff_code_client.dart';

final Uri kOperatorWebHandoffBaseUri = Uri.https('app.forgeflow.app');

class HandoffDeepLinkTarget {
  const HandoffDeepLinkTarget({required this.navId, required this.targetPath});

  final String navId;
  final String targetPath;
}

class HandoffDeepLink {
  const HandoffDeepLink({required this.url, required this.expiresIn});

  final Uri url;
  final Duration expiresIn;
}

abstract class HandoffCodeGateway {
  Future<HandoffDeepLink> createDeepLink({
    required HandoffDeepLinkTarget target,
  });
}

class ProxyHandoffCodeGateway implements HandoffCodeGateway {
  ProxyHandoffCodeGateway({
    required HandoffCodeClient client,
    Uri? operatorWebBaseUri,
  }) : _client = client,
       _operatorWebBaseUri = operatorWebBaseUri ?? kOperatorWebHandoffBaseUri;

  final HandoffCodeClient _client;
  final Uri _operatorWebBaseUri;

  @override
  Future<HandoffDeepLink> createDeepLink({
    required HandoffDeepLinkTarget target,
  }) async {
    final minted = await _client.mintHandoffCode(targetPath: target.targetPath);
    return HandoffDeepLink(
      url: _operatorWebBaseUri.replace(
        path: '/handoff',
        queryParameters: <String, String>{
          'code': minted.code,
          'nav': target.navId,
        },
      ),
      expiresIn: minted.expiresIn,
    );
  }
}

bool shouldFallbackToClipboardForHandoff(Object error) {
  if (error is HandoffCodeMintRejected) {
    return error.statusCode >= 500;
  }
  return error is SocketException ||
      error is TimeoutException ||
      error is HandshakeException ||
      error is HttpException;
}
