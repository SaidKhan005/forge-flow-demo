#!/usr/bin/env bash
# B-FU-dev-csp: Rewrite the Content-Security-Policy <meta> tag in the
# supplied Flutter web `index.html` to the dev-relaxed CSP used by the
# Phase 2 operator-web walkthrough. The dev CSP allows the Flutter DDC
# bundle to evaluate inline scripts and connect to the local
# `ws://localhost:*` / `http://localhost:*` web-server ports.
#
# This helper is invoked from two places:
#
#   1. `Dockerfile.operator_web` — when built with
#      `--build-arg OPERATOR_WEB_DEV_DDC=true`, after the operator-web
#      web shell has been overlaid onto `web/index.html` and before
#      `flutter build web` runs.
#
#   2. `scripts/run_operator_web_dev.ps1` (recommended local-run
#      helper) — applied to a temporary copy of `web/index.html` for
#      the duration of a `flutter run` session; the helper restores
#      the production CSP from backup on exit.
#
# The source `web/index.html` + `web/operator/index.html` on disk are
# left prod-strict; the swap is build-time / run-time only so a
# production `scripts/deploy_operator_web.ps1` invocation never
# accidentally ships the dev CSP to Cloud Run.
#
# Usage:
#   apply_operator_web_dev_csp.sh <path-to-index.html>

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <path-to-index.html>" >&2
  exit 2
fi

target="$1"

if [ ! -f "$target" ]; then
  echo "B-FU-dev-csp: target index.html not found: $target" >&2
  exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "B-FU-dev-csp: perl is required but not on PATH" >&2
  exit 1
fi

echo "B-FU-dev-csp: applying dev-relaxed CSP to $target"

# Multi-line replace of the existing <meta http-equiv="Content-Security-Policy" ...>
# block with the dev-relaxed variant. The match is anchored on the
# opening `<meta http-equiv="Content-Security-Policy"` token and the
# closing `">` to avoid greedily consuming downstream tags.
perl -0777 -i -pe '
  my $dev_csp = "<meta http-equiv=\"Content-Security-Policy\" content=\"\n" .
    "    default-src '"'"'self'"'"' '"'"'unsafe-inline'"'"' '"'"'unsafe-eval'"'"';\n" .
    "    script-src '"'"'self'"'"' '"'"'unsafe-inline'"'"' '"'"'unsafe-eval'"'"' '"'"'wasm-unsafe-eval'"'"' https://www.gstatic.com https://*.firebaseapp.com;\n" .
    "    style-src '"'"'self'"'"' '"'"'unsafe-inline'"'"' https://fonts.googleapis.com;\n" .
    "    img-src '"'"'self'"'"' data: blob: https:;\n" .
    "    font-src '"'"'self'"'"' data: https://fonts.gstatic.com;\n" .
    "    connect-src '"'"'self'"'"' ws://localhost:* http://localhost:* https://www.gstatic.com https://fonts.gstatic.com https://*.googleapis.com https://*.firebaseio.com https://*.cloudfunctions.net wss://*.firebaseio.com https://admin-proxy.forgeflow.app https://proxy.forgeflow.app https://*.forgeflow.app https://*.run.app;\n" .
    "    frame-src '"'"'self'"'"' https://*.firebaseapp.com;\n" .
    "    object-src '"'"'none'"'"';\n" .
    "    base-uri '"'"'self'"'"';\n" .
    "    form-action '"'"'self'"'"';\n" .
    "  \">";
  my $count = s{<meta\s+http-equiv="Content-Security-Policy".*?">}{$dev_csp}s;
  if ($count != 1) {
    die "B-FU-dev-csp: failed to locate CSP <meta> tag (count=$count)\n";
  }
' "$target"

echo "B-FU-dev-csp: dev CSP applied to $target"
