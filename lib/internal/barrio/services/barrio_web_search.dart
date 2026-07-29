/// Web-search URL construction for the Barrio manual reader.
///
/// Kept as a tiny pure function (no Flutter, no I/O) so the encoding is
/// unit-testable in isolation from the screen that launches it.
library;

/// Builds the Google web-search URL for a reader's [query].
///
/// The query is trimmed and percent-encoded with
/// [Uri.encodeQueryComponent], so spaces become `+`, `&` becomes
/// `%26`, and accented letters (for example the `ñ` in `tequila añejo`)
/// become their UTF-8 percent-escapes. The result is placed in the `q`
/// parameter of a standard Google search URL.
///
/// The manual reader opens the returned URL in an in-app browser view so
/// a reader can look something up without leaving the app.
Uri barrioWebSearchUri(String query) {
  final encoded = Uri.encodeQueryComponent(query.trim());
  return Uri.parse('https://www.google.com/search?q=$encoded');
}

/// Builds the ChatGPT URL that opens a conversation seeded with the
/// reader's [query] (the "Ask chat" selection action, 2026-07-29).
///
/// The trimmed query is percent-encoded with [Uri.encodeQueryComponent]
/// (same rules as [barrioWebSearchUri]) and placed in ChatGPT's `q`
/// parameter, which starts a chat with that prompt. The manual reader
/// opens the result in an in-app browser view, so a reader can ask an
/// assistant about a highlighted term without leaving the app.
Uri barrioAskChatUri(String query) {
  final encoded = Uri.encodeQueryComponent(query.trim());
  return Uri.parse('https://chatgpt.com/?q=$encoded');
}
