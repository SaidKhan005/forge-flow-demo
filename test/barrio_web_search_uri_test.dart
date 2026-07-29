// Pure unit tests for the Barrio manual reader's in-app web search URL
// builder. The reader opens Google results in an in-app browser view;
// [barrioWebSearchUri] builds that URL, so its encoding is the piece
// worth locking down: spaces, reserved characters like `&`, and
// accented letters must all percent-encode into a valid query.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_web_search.dart';

void main() {
  group('barrioWebSearchUri', () {
    test('encodes a simple query with spaces as +', () {
      final uri = barrioWebSearchUri('coffee beans');
      expect(
        uri.toString(),
        'https://www.google.com/search?q=coffee+beans',
      );
    });

    test('percent-encodes the reserved & character', () {
      final uri = barrioWebSearchUri('salt & pepper');
      expect(
        uri.toString(),
        'https://www.google.com/search?q=salt+%26+pepper',
      );
      // A decode of the q parameter round-trips to the original text.
      expect(uri.queryParameters['q'], 'salt & pepper');
    });

    test('percent-encodes accented letters (tequila añejo)', () {
      final uri = barrioWebSearchUri('tequila añejo');
      expect(
        uri.toString(),
        'https://www.google.com/search?q=tequila+a%C3%B1ejo',
      );
      expect(uri.queryParameters['q'], 'tequila añejo');
    });

    test('trims surrounding whitespace before encoding', () {
      final uri = barrioWebSearchUri('   pozole   ');
      expect(
        uri.toString(),
        'https://www.google.com/search?q=pozole',
      );
    });

    test('always targets Google search over https', () {
      final uri = barrioWebSearchUri('mezcal');
      expect(uri.scheme, 'https');
      expect(uri.host, 'www.google.com');
      expect(uri.path, '/search');
    });
  });

  group('barrioAskChatUri', () {
    test('seeds ChatGPT q with a simple query (spaces as +)', () {
      final uri = barrioAskChatUri('what is horchata');
      expect(uri.toString(), 'https://chatgpt.com/?q=what+is+horchata');
    });

    test('percent-encodes reserved and accented characters', () {
      final uri = barrioAskChatUri('tequila añejo & mezcal');
      expect(uri.queryParameters['q'], 'tequila añejo & mezcal');
    });

    test('trims surrounding whitespace before encoding', () {
      final uri = barrioAskChatUri('   pozole   ');
      expect(uri.toString(), 'https://chatgpt.com/?q=pozole');
    });

    test('always targets ChatGPT over https', () {
      final uri = barrioAskChatUri('mezcal');
      expect(uri.scheme, 'https');
      expect(uri.host, 'chatgpt.com');
    });
  });
}
