// Wave 2 Q-2a — email soak harness latency budget config.
//
// Two budgets enforced per scenario:
//   * `inboxLatencyBudgetMs` — Mailosaur receipt half (send accepted
//     by the proxy → message arrives in the loopback inbox). Default
//     30s — SendGrid sandbox + Mailosaur trip is typically < 5s.
//   * `webhookLatencyBudgetMs` — SendGrid event webhook half (send
//     accepted → `delivered` event row visible via the proxy probe).
//     Default 45s — SendGrid event delivery is async and may straggle
//     by several seconds.
//
// Both budgets are independent and BOTH must pass for an outcome to be
// `success`. Any miss falls into either `inboxTimeout` (Mailosaur
// poll exhausted), `webhookMissing` (probe poll exhausted with no
// matching event), or `budgetExceeded` (a hit arrived but later than
// the budget).
//
// The budgets are deliberately loose by default — Q-2a is end-to-end
// LOOPBACK observability, not performance gating. A future tightening
// slice can drive them down once the harness has baseline numbers.

class EmailSoakBudget {
  const EmailSoakBudget({
    required this.inboxLatencyBudgetMs,
    required this.webhookLatencyBudgetMs,
  });

  final int inboxLatencyBudgetMs;
  final int webhookLatencyBudgetMs;

  /// Default budgets when no env override applies.
  factory EmailSoakBudget.defaults() {
    return const EmailSoakBudget(
      inboxLatencyBudgetMs: 30000,
      webhookLatencyBudgetMs: 45000,
    );
  }

  /// Returns true when [latencyMs] is within the inbox budget.
  bool inboxWithinBudget(int latencyMs) =>
      latencyMs <= inboxLatencyBudgetMs;

  /// Returns true when [latencyMs] is within the webhook budget.
  bool webhookWithinBudget(int latencyMs) =>
      latencyMs <= webhookLatencyBudgetMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'inbox_latency_budget_ms': inboxLatencyBudgetMs,
        'webhook_latency_budget_ms': webhookLatencyBudgetMs,
      };
}
