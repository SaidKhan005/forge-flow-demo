// Throwaway static file server for previewing docs/_mockups/*.html in the
// Claude Preview pane. Depends only on dart:io (no packages). Not committed.
// Root "/" serves the vendor applicability redesign mockup.
import 'dart:io';

const int kPort = 8190;
const String kDefault = '/docs/_mockups/vendor_applicability_redesign_mock.html';

Future<void> main() async {
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? kPort;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('mock preview server: http://localhost:$port');
  await for (final HttpRequest req in server) {
    try {
      var rel = Uri.decodeComponent(req.uri.path);
      if (rel == '/' || rel.isEmpty) rel = kDefault;
      if (rel.contains('..')) {
        req.response.statusCode = 400;
      } else {
        final file = File('.$rel');
        if (await file.exists()) {
          final ext = rel.contains('.') ? rel.split('.').last.toLowerCase() : '';
          final ct = switch (ext) {
            'html' => 'text/html; charset=utf-8',
            'css' => 'text/css; charset=utf-8',
            'js' => 'application/javascript; charset=utf-8',
            'json' => 'application/json; charset=utf-8',
            'svg' => 'image/svg+xml',
            _ => 'application/octet-stream',
          };
          req.response.headers.contentType = ContentType.parse(ct);
          await req.response.addStream(file.openRead());
        } else {
          req.response.statusCode = 404;
          req.response.write('not found: $rel');
        }
      }
    } catch (e) {
      req.response.statusCode = 500;
      req.response.write('error: $e');
    }
    await req.response.close();
  }
}
