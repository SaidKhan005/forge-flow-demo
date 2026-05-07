// Wave W2.D — gateway provider re-export for the connector backfill
// jobs read surface.
//
// This thin file lets the operator-web auth source + screen import the
// provider sentinel and the live + demo impls from a single path that
// matches the naming pattern other operator-web gateway providers use
// (`*_gateway_provider.dart`). The actual interfaces + impls live in
// `operator_web_connector_backfill_jobs_gateway.dart` so the gateway +
// provider sentinel stay co-located with the wire types.

export 'operator_web_connector_backfill_jobs_gateway.dart'
    show
        OperatorWebConnectorBackfillJob,
        OperatorWebConnectorBackfillJobsBundle,
        OperatorWebConnectorBackfillJobsError,
        OperatorWebConnectorBackfillJobsGateway,
        OperatorWebConnectorBackfillJobsGatewayInMemory,
        OperatorWebConnectorBackfillJobsGatewayLive,
        OperatorWebConnectorBackfillJobsGatewayProvider;
