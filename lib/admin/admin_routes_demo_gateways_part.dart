part of 'admin_routes.dart';

// Demo / share-preview / widget-test fallback gateways for the admin
// console routes. Extracted from admin_routes.dart as a `part` (size-lint
// slim-down, 2026-05-24) so privacy and the shared library scope are
// preserved; AdminConsoleServicesScope (in admin_routes.dart) wires these
// as the default gateways when no production gateway is injected.

/// Fix #4 / S4 (G41 + G42) — shared seeded in-memory fallback for
/// the READ-ONLY admin business-timing resolution gateway. Seeded
/// demo locations mirror the Data Accuracy demo locations so the
/// share-preview path can resolve a business date before mounting
/// the operator web Data Accuracy surface. Unknown locations still
/// render their honest "no timing profile yet" state instead of
/// fabricating values when no production gateway is wired.
final AdminBusinessTimingResolutionGateway _defaultTimingResolutionDemoGateway =
    InMemoryAdminBusinessTimingResolutionGateway(
      seed: <String, AdminBusinessTimingResolution>{
        InMemoryAdminBusinessTimingResolutionGateway.keyFor(
          '00000000-0000-4000-8000-000000000001',
          '00000000-0000-4000-8000-0000000000a1',
        ): _demoTimingResolution(
          operatorId: '00000000-0000-4000-8000-000000000001',
          locationId: '00000000-0000-4000-8000-0000000000a1',
          locationName: 'Toronto Yorkville',
          timezone: 'America/Toronto',
          businessDayStartLocal: '04:00',
        ),
        InMemoryAdminBusinessTimingResolutionGateway.keyFor(
          '00000000-0000-4000-8000-000000000001',
          '00000000-0000-4000-8000-0000000000a2',
        ): _demoTimingResolution(
          operatorId: '00000000-0000-4000-8000-000000000001',
          locationId: '00000000-0000-4000-8000-0000000000a2',
          locationName: 'Vancouver Robson',
          timezone: 'America/Vancouver',
          businessDayStartLocal: '04:00',
        ),
        InMemoryAdminBusinessTimingResolutionGateway.keyFor(
          '00000000-0000-4000-8000-000000000002',
          '00000000-0000-4000-8000-0000000000b1',
        ): _demoTimingResolution(
          operatorId: '00000000-0000-4000-8000-000000000002',
          locationId: '00000000-0000-4000-8000-0000000000b1',
          locationName: 'Brooklyn Williamsburg',
          timezone: 'America/New_York',
          businessDayStartLocal: '05:00',
        ),
      },
    );

AdminBusinessTimingResolution _demoTimingResolution({
  required String operatorId,
  required String locationId,
  required String locationName,
  required String timezone,
  required String businessDayStartLocal,
}) {
  return AdminBusinessTimingResolution(
    operatorId: operatorId,
    locationId: locationId,
    businessDate: '2026-05-24',
    ianaTimezone: timezone,
    candidates: <AdminResolutionCandidate>[
      AdminResolutionCandidate(
        profileId: 'demo-timing-$locationId',
        scopeType: 'location',
        scopeId: locationId,
        scopeLabel: locationName,
        scopeDepthRank: 3,
        ianaTimezone: timezone,
        effectiveAtBusinessDate: '2026-01-01',
        weekStartDay: 'monday',
        businessDayStartLocal: businessDayStartLocal,
        servicePeriods: _demoTimingServicePeriods,
      ),
    ],
  );
}

const List<AdminResolutionServicePeriod> _demoTimingServicePeriods =
    <AdminResolutionServicePeriod>[
      AdminResolutionServicePeriod(
        key: 'breakfast',
        label: 'Breakfast',
        shortLabel: 'Breakfast',
        startLocal: '06:00',
        endLocal: '11:00',
        rollsPastMidnight: false,
        sortOrder: 0,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      ),
      AdminResolutionServicePeriod(
        key: 'lunch',
        label: 'Lunch',
        shortLabel: 'Lunch',
        startLocal: '11:00',
        endLocal: '15:00',
        rollsPastMidnight: false,
        sortOrder: 1,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      ),
      AdminResolutionServicePeriod(
        key: 'dinner',
        label: 'Dinner',
        shortLabel: 'Dinner',
        startLocal: '17:00',
        endLocal: '22:00',
        rollsPastMidnight: false,
        sortOrder: 2,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      ),
      AdminResolutionServicePeriod(
        key: 'late_night',
        label: 'Late night',
        shortLabel: 'Late',
        startLocal: '22:00',
        endLocal: '02:00',
        rollsPastMidnight: true,
        sortOrder: 3,
        applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
      ),
    ];

/// Timing-editable parity — shared seeded in-memory fallback for the
/// admin business-timing PROFILE WRITE gateway. Empty by default, so the
/// admin Timing editor opens on the starter profile and the first Save
/// creates a profile for the selected scope. A single shared instance
/// (mirrors [_defaultTimingResolutionDemoGateway]) so demo / share-
/// preview / widget-test paths see the same store across rebuilds when
/// no production [HttpAdminBusinessTimingProfilesGateway] is wired.
final AdminBusinessTimingProfilesGateway _defaultTimingProfilesDemoGateway =
    InMemoryAdminBusinessTimingProfilesGateway();

/// Monotonic id minter for locations added through the demo operator
/// gateway. Uses a `c`-prefixed hex tail so a minted id can never
/// collide with a seeded operator id (`...001` / `...002`), a seeded
/// location id (`...a1` / `...a2` / `...b1`), or the default
/// [InMemoryOperatorLocationAdminGateway] counter (which starts at
/// `...001` and so would otherwise reuse the Demo Diner operator id for
/// the first added location). Origin: the 404 `unknown_location` on
/// added-location actions (location id == operator id) in the demo
/// Business accounts screen.
int _demoAddedLocationCounter = 0;
String _mintDemoAddedLocationId() {
  _demoAddedLocationCounter += 1;
  final hex = _demoAddedLocationCounter.toRadixString(16).padLeft(2, '0');
  return '00000000-0000-4000-8000-0000000000c$hex';
}

/// Demo gateway shared by walkthrough + admin shell when no
/// production scope is mounted. Seeded with two fixture operators
/// so the click path has something to show on first paint without
/// asking the F&F admin to manually run onboarding.
///
/// `idGenerator` + `onLocationAdded` / `onLocationRemoved` keep this
/// operator store consistent with the sibling hierarchy demo store
/// [_defaultRolesHierarchySessionsAdminDemoGateway]: an added location
/// gets a unique id AND is registered as a tree leaf, so the Hierarchy
/// tree's Delete / Move / Suspend / Reactivate actions resolve it
/// instead of 404ing. The hooks reference the hierarchy gateway lazily
/// (only at add/remove time), so the forward reference across these two
/// lazily-initialized top-level finals is safe.
final OperatorLocationAdminGateway _defaultDemoGateway =
    InMemoryOperatorLocationAdminGateway(
      idGenerator: _mintDemoAddedLocationId,
      onLocationAdded: (location) {
        final orgUnitId = location.parentOrgUnitId;
        if (orgUnitId == null || orgUnitId.trim().isEmpty) return;
        (_defaultRolesHierarchySessionsAdminDemoGateway
                as InMemoryRolesHierarchySessionsAdminGateway)
            .registerDemoLocation(
              operatorId: location.operatorId,
              locationId: location.locationId,
              name: location.name,
              orgUnitId: orgUnitId.trim(),
            );
      },
      onLocationRemoved: ({required operatorId, required locationId}) {
        (_defaultRolesHierarchySessionsAdminDemoGateway
                as InMemoryRolesHierarchySessionsAdminGateway)
            .removeDemoLocation(operatorId: operatorId, locationId: locationId);
      },
      seed: <OperatorAdminBundle>[
        OperatorAdminBundle(
          operator: OperatorAdminRecord(
            operatorId: '00000000-0000-4000-8000-000000000001',
            businessName: 'Demo Diner Co.',
            ownerEmail: 'owner@demo-diner.test',
            subscriptionTier: 'pro',
            preferredCurrency: 'CAD',
            primaryLocationId: '00000000-0000-4000-8000-0000000000a1',
            suspendedAt: null,
            createdAt: DateTime.utc(2026, 1, 12, 14, 30),
            updatedAt: DateTime.utc(2026, 4, 1, 10, 0),
          ),
          locations: <LocationAdminRecord>[
            LocationAdminRecord(
              locationId: '00000000-0000-4000-8000-0000000000a1',
              operatorId: '00000000-0000-4000-8000-000000000001',
              name: 'Toronto Yorkville',
              address: '123 Main St, Toronto, ON',
              timezone: 'America/Toronto',
              businessDayRolloverHour: 4,
              createdAt: DateTime.utc(2026, 1, 12, 14, 30),
              updatedAt: DateTime.utc(2026, 1, 12, 14, 30),
            ),
            LocationAdminRecord(
              locationId: '00000000-0000-4000-8000-0000000000a2',
              operatorId: '00000000-0000-4000-8000-000000000001',
              name: 'Vancouver Robson',
              address: '456 Robson St, Vancouver, BC',
              timezone: 'America/Vancouver',
              businessDayRolloverHour: 4,
              createdAt: DateTime.utc(2026, 2, 1, 9, 0),
              updatedAt: DateTime.utc(2026, 2, 1, 9, 0),
            ),
          ],
        ),
        OperatorAdminBundle(
          operator: OperatorAdminRecord(
            operatorId: '00000000-0000-4000-8000-000000000002',
            businessName: 'Sunset Cafe Group',
            ownerEmail: 'owner@sunset-cafe.test',
            subscriptionTier: 'pilot',
            preferredCurrency: 'USD',
            primaryLocationId: '00000000-0000-4000-8000-0000000000b1',
            suspendedAt: null,
            createdAt: DateTime.utc(2026, 3, 5, 11, 0),
            updatedAt: DateTime.utc(2026, 4, 18, 12, 0),
          ),
          locations: <LocationAdminRecord>[
            LocationAdminRecord(
              locationId: '00000000-0000-4000-8000-0000000000b1',
              operatorId: '00000000-0000-4000-8000-000000000002',
              name: 'Brooklyn Williamsburg',
              address: '78 Bedford Ave, Brooklyn, NY',
              timezone: 'America/New_York',
              businessDayRolloverHour: 5,
              createdAt: DateTime.utc(2026, 3, 5, 11, 0),
              updatedAt: DateTime.utc(2026, 3, 5, 11, 0),
            ),
          ],
        ),
      ],
    );

/// 11A.2 fallback pricing gateway. Mirrors the two demo operators
/// from `_defaultDemoGateway` so the walkthrough can hop between
/// Operators and Pricing without a backing service. The Pilot operator
/// (Sunset Cafe Group) starts with the locked Pilot template caps; the
/// Pro operator (Demo Diner Co.) has no caps yet so the walkthrough
/// exercises "Apply template" too.
final PricingTierAdminGateway _defaultPricingDemoGateway =
    InMemoryPricingTierAdminGateway(
      seed: <PricingOperatorBundle>[
        PricingOperatorBundle(
          operatorId: '00000000-0000-4000-8000-000000000001',
          businessName: 'Demo Diner Co.',
          subscriptionTier: 'pro',
          preferredCurrency: 'CAD',
          primaryLocationId: '00000000-0000-4000-8000-0000000000a1',
          primaryLocationName: 'Toronto Yorkville',
          suspended: false,
          caps: <UsageCapRow>[],
        ),
        PricingOperatorBundle(
          operatorId: '00000000-0000-4000-8000-000000000002',
          businessName: 'Sunset Cafe Group',
          subscriptionTier: 'pilot',
          preferredCurrency: 'USD',
          primaryLocationId: '00000000-0000-4000-8000-0000000000b1',
          primaryLocationName: 'Brooklyn Williamsburg',
          suspended: false,
          caps: <UsageCapRow>[
            UsageCapRow(
              capId: '00000000-0000-4000-8000-0000000000c1',
              operatorId: '00000000-0000-4000-8000-000000000002',
              locationId: '00000000-0000-4000-8000-0000000000b1',
              usageClass: 'advisor_qa',
              monthlyCapUsd: 50.0,
              perInvocationCapUsd: 0.10,
              staffId: null,
              workflowId: null,
              createdBy: 'demo-super-admin',
              updatedBy: 'demo-super-admin',
              createdAt: DateTime.utc(2026, 3, 5, 11, 0),
              updatedAt: DateTime.utc(2026, 4, 18, 12, 0),
            ),
          ],
        ),
      ],
    );

/// 11A.3a fallback corpus admin gateway. Seeded so the walkthrough has
/// a prior version, a current version, AND a content set that spans the
/// plain-English kinds the Knowledge tab can show (Manual, SOP, Policy,
/// Concept, Metric, Formula, Risk, Role) — mirroring the approved
/// preview. Demo chunks live entirely in memory; no `demo_*` tables, no
/// reader fork (HP #2). Each section's heading is the only kind signal:
/// [corpusTopicKindForChunk] derives the kind from that text, so nothing
/// here fabricates a kind. The graph-candidate seed below populates the
/// Connections tab with a realistic, multi-bucket set so the summary,
/// lists, and map all read as a real review queue.
final CorpusAdminGateway _defaultCorpusDemoGateway = InMemoryCorpusAdminGateway(
  graphCandidateSeed: _demoKnowledgeGraphCandidates(),
  seed: <CorpusBundle>[
    // Prior version: the original methodology seed, before the broader
    // manuals + handbook + playbook landed. Kept so the Update history
    // timeline has a real "go back" target.
    CorpusBundle(
      version: CorpusVersionRef(
        versionId: '00000000-0000-4000-9000-000000000001',
        createdBy: 'demo-super-admin',
        createdAt: DateTime.utc(2026, 1, 14, 9, 0),
        summary: 'Added the Forge & Flow methodology',
        rollbackOf: null,
        supersededAt: DateTime.utc(2026, 3, 1, 10, 0),
        chunkCount: 2,
      ),
      chunks: <ChunkPreview>[
        _demoChunk(
          source: 'forge_and_flow_methodology.md',
          heading: 'The Core Labor Equation',
          snippet:
              'The Core Labor Equation turns sales and hours into the '
              'metrics the advisor coaches on.',
          version: '00000000-0000-4000-9000-000000000001',
          tokens: 64,
          active: false,
          hashSeed: 'a',
        ),
        _demoChunk(
          source: 'forge_and_flow_methodology.md',
          heading: 'Cost per Labor Hour (CPLH)',
          snippet:
              'Cost per Labor Hour is a core metric you track each shift, '
              'compared against the locked target.',
          version: '00000000-0000-4000-9000-000000000001',
          tokens: 80,
          active: false,
          hashSeed: 'b',
        ),
      ],
    ),
    // Current version: the full launch content set, grouped by the
    // document it came from, spanning every kind the Topics card shows.
    CorpusBundle(
      version: CorpusVersionRef(
        versionId: '00000000-0000-4000-9000-000000000002',
        createdBy: 'demo-super-admin',
        createdAt: DateTime.utc(2026, 3, 1, 10, 0),
        summary: 'Added the Food Safety Manual and the company handbook',
        rollbackOf: null,
        supersededAt: null,
        chunkCount: 12,
      ),
      chunks: <ChunkPreview>[
        // Food Safety Manual: a manual that contains SOPs, a concept,
        // and a risk.
        _demoChunk(
          source: 'food_safety_manual.md',
          heading: 'Food Safety Manual',
          snippet:
              'The Food Safety Manual collects the kitchen safety steps, '
              'rules, and the risks they guard against.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 96,
          hashSeed: 'c',
        ),
        _demoChunk(
          source: 'food_safety_manual.md',
          heading: 'FIFO (First In, First Out)',
          snippet:
              'FIFO is the step-by-step stock-rotation procedure: the '
              'oldest product is always used first.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 72,
          hashSeed: 'd',
        ),
        _demoChunk(
          source: 'food_safety_manual.md',
          heading: 'HACCP plan',
          snippet:
              'HACCP is the procedure for finding and controlling the '
              'points where food safety can fail.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 70,
          hashSeed: 'e',
        ),
        _demoChunk(
          source: 'food_safety_manual.md',
          heading: "The 4 C's",
          snippet:
              "The 4 C's are the core food-safety concept: cleaning, "
              'cooking, chilling, and cross-contamination.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 66,
          hashSeed: 'f',
        ),
        _demoChunk(
          source: 'food_safety_manual.md',
          heading: 'Temperature Danger Zone',
          snippet:
              'The Temperature Danger Zone is the risk window between 4 '
              'and 60 degrees where bacteria multiply fastest.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 68,
          hashSeed: 'g',
        ),
        // Company handbook: policies + a role.
        _demoChunk(
          source: 'company_handbook.md',
          heading: 'Workplace Harassment Policy',
          snippet:
              'The Workplace Harassment Policy is the rule everyone must '
              'follow, with clear reporting steps.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 74,
          hashSeed: 'h',
        ),
        _demoChunk(
          source: 'company_handbook.md',
          heading: 'WHMIS labelling',
          snippet:
              'WHMIS is the policy for labelling and handling hazardous '
              'workplace materials safely.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 64,
          hashSeed: 'i',
        ),
        _demoChunk(
          source: 'company_handbook.md',
          heading: 'Expo (role)',
          snippet:
              'The Expo is the role that plates, checks, and calls each '
              'order at the pass.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 58,
          hashSeed: 'j',
        ),
        // BOLD by Design playbook: a metric, a formula, and concepts.
        _demoChunk(
          source: 'bold_by_design.md',
          heading: 'Cost per Labor Hour (CPLH)',
          snippet:
              'Cost per Labor Hour is the metric you track each shift to '
              'see if labor spend matches the plan.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 78,
          hashSeed: 'k',
        ),
        _demoChunk(
          source: 'bold_by_design.md',
          heading: 'The Core Labor Equation',
          snippet:
              'The Core Labor Equation is the formula behind CPLH, SPLH, '
              'and PPA: sales and hours become coaching metrics.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 82,
          hashSeed: 'l',
        ),
        _demoChunk(
          source: 'bold_by_design.md',
          heading: 'Optimal Productivity Zone',
          snippet:
              'The Optimal Productivity Zone is the concept of the staffing '
              'band where service and labor cost both stay healthy.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 80,
          hashSeed: 'm',
        ),
        _demoChunk(
          source: 'bold_by_design.md',
          heading: 'Hospitality culture',
          snippet:
              'Hospitality culture is the principle that guest experience '
              'and team care drive every decision.',
          version: '00000000-0000-4000-9000-000000000002',
          tokens: 60,
          hashSeed: 'n',
        ),
      ],
    ),
  ],
  actorUserId: 'demo-super-admin',
);

/// Builds one demo [ChunkPreview]. The [heading] is the only kind signal
/// the Topics card reads, so giving each section a plainly-named heading
/// is what lets [corpusTopicKindForChunk] show varied kinds without any
/// backend. [hashSeed] just keeps content hashes distinct; it never
/// appears in the everyday view (it sits behind "Show technical
/// details").
ChunkPreview _demoChunk({
  required String source,
  required String heading,
  required String snippet,
  required String version,
  required int tokens,
  required String hashSeed,
  bool active = true,
}) {
  return ChunkPreview(
    chunkId: '$source#${heading.hashCode.toRadixString(16)}',
    docId: source,
    sourcePath: source,
    headingPath: <String>[heading],
    snippet: snippet,
    estimatedTokens: tokens,
    riskLevel: 'standard',
    contentSha256: hashSeed * 64,
    versionId: version,
    active: active,
  );
}

/// Deterministic, realistic graph-candidate seed for the demo
/// Connections tab. Mirrors the kind of edges the importer would emit
/// from the seeded corpus above, spanning all three clarity buckets so
/// the summary, the clarity-grouped lists, and the focusable map all
/// read as a real review queue (not a thin one-edge stub). Confidence
/// scores drive the honest clarity bucketing; nothing here is fabricated
/// beyond being demo data. `from_node_type` / `to_node_type` let each
/// flow row show the right kind icon per node.
GraphCandidateDiff _demoKnowledgeGraphCandidates() {
  return GraphCandidateDiff(
    graphScope: 'methodology',
    graphVersion: '1',
    graphifyVersion: 'v5',
    graphifySourceCommit: 'demo-seed',
    extracted: _demoExtractedGraphCandidates(),
    inferred: _demoInferredGraphCandidates(),
    ambiguous: _demoAmbiguousGraphCandidates(),
  );
}

/// Shared edge builder for the demo knowledge-graph candidate buckets.
/// `sourceFile` is fixed to `food_safety_manual.md` because the seeded
/// corpus is rooted in that manual; per-bucket helpers pass everything
/// else through verbatim.
GraphCandidate _demoKnowledgeGraphEdge({
  required String id,
  required String from,
  required String to,
  required String type,
  required GraphCandidateLabel label,
  required double score,
  required String fromType,
  required String toType,
  required String sentence,
}) {
  return GraphCandidate(
    candidateId: id,
    kind: GraphCandidateKind.edge,
    candidateKey: 'graphify:$id',
    candidateType: type,
    label: label,
    confidenceScore: score,
    sourceFile: 'food_safety_manual.md',
    sourceRef: null,
    fromNodeKey: 'graphify:$from',
    toNodeKey: 'graphify:$to',
    payload: <String, Object?>{
      'graphify_relation': type,
      'label': sentence,
      'from_node_type': fromType,
      'to_node_type': toType,
    },
  );
}

/// Clear, high-confidence "includes" edges: the manual contains its
/// SOPs and concepts.
List<GraphCandidate> _demoExtractedGraphCandidates() {
  return <GraphCandidate>[
    _demoKnowledgeGraphEdge(
      id: 'edge:manual:fifo:contains',
      from: 'food_safety_manual',
      to: 'fifo',
      type: 'CONTAINS',
      label: GraphCandidateLabel.extracted,
      score: 0.96,
      fromType: 'MANUAL',
      toType: 'SOP',
      sentence: 'manual contains fifo',
    ),
    _demoKnowledgeGraphEdge(
      id: 'edge:manual:haccp:contains',
      from: 'food_safety_manual',
      to: 'haccp',
      type: 'CONTAINS',
      label: GraphCandidateLabel.extracted,
      score: 0.94,
      fromType: 'MANUAL',
      toType: 'SOP',
      sentence: 'manual contains haccp',
    ),
    _demoKnowledgeGraphEdge(
      id: 'edge:manual:fourcs:contains',
      from: 'food_safety_manual',
      to: 'the_four_cs',
      type: 'CONTAINS',
      label: GraphCandidateLabel.extracted,
      score: 0.90,
      fromType: 'MANUAL',
      toType: 'CONCEPT',
      sentence: 'manual contains the four cs',
    ),
    _demoKnowledgeGraphEdge(
      id: 'edge:handbook:harassment:contains',
      from: 'company_handbook',
      to: 'workplace_harassment_policy',
      type: 'CONTAINS',
      label: GraphCandidateLabel.extracted,
      score: 0.93,
      fromType: 'DOCUMENT',
      toType: 'POLICY',
      sentence: 'handbook contains harassment policy',
    ),
    _demoKnowledgeGraphEdge(
      id: 'edge:equation:cplh:calculates',
      from: 'the_core_labor_equation',
      to: 'cost_per_labor_hour',
      type: 'CALCULATES',
      label: GraphCandidateLabel.extracted,
      score: 0.91,
      fromType: 'FORMULA',
      toType: 'METRIC',
      sentence: 'the core labor equation calculates cplh',
    ),
  ];
}

/// Worth-checking, mid-confidence edges: plausible but not obvious.
List<GraphCandidate> _demoInferredGraphCandidates() {
  return <GraphCandidate>[
    _demoKnowledgeGraphEdge(
      id: 'edge:fourcs:contamination:reduces',
      from: 'the_four_cs',
      to: 'cross_contamination',
      type: 'REDUCES_RISK_OF',
      label: GraphCandidateLabel.inferred,
      score: 0.80,
      fromType: 'CONCEPT',
      toType: 'RISK',
      sentence: 'the four cs reduce the risk of cross contamination',
    ),
    _demoKnowledgeGraphEdge(
      id: 'edge:fifo:danger_zone:reduces',
      from: 'fifo',
      to: 'temperature_danger_zone',
      type: 'REDUCES_RISK_OF',
      label: GraphCandidateLabel.inferred,
      score: 0.74,
      fromType: 'SOP',
      toType: 'RISK',
      sentence: 'fifo reduces the risk of the temperature danger zone',
    ),
    _demoKnowledgeGraphEdge(
      id: 'edge:opz:cplh:informs',
      from: 'optimal_productivity_zone',
      to: 'cost_per_labor_hour',
      type: 'INFORMS',
      label: GraphCandidateLabel.inferred,
      score: 0.77,
      fromType: 'CONCEPT',
      toType: 'METRIC',
      sentence: 'the optimal productivity zone informs cplh',
    ),
  ];
}

/// Not-sure: the producer could not pin the relationship. These read
/// "Not sure" and must be edited before they can be approved.
List<GraphCandidate> _demoAmbiguousGraphCandidates() {
  return <GraphCandidate>[
    _demoKnowledgeGraphEdge(
      id: 'edge:whmis:danger_zone:relates',
      from: 'whmis_labelling',
      to: 'temperature_danger_zone',
      type: 'RELATES_TO',
      label: GraphCandidateLabel.ambiguous,
      score: 0.42,
      fromType: 'POLICY',
      toType: 'RISK',
      sentence: 'whmis labelling near the temperature danger zone',
    ),
    _demoKnowledgeGraphEdge(
      id: 'edge:expo:fourcs:relates',
      from: 'expo_role',
      to: 'the_four_cs',
      type: 'RELATES_TO',
      label: GraphCandidateLabel.ambiguous,
      score: 0.38,
      fromType: 'ROLE',
      toType: 'CONCEPT',
      sentence: 'expo role near the four cs',
    ),
  ];
}

/// 11A.4 fallback integration gateway. Seeds Anthropic + Voyage with
/// pre-rotated masked rows; Azure DB starts empty so the walkthrough
/// can exercise the "no row yet → first rotation" path. The KMS
/// stub is the same provider production would bind in pre-launch.
final IntegrationAdminGateway _defaultIntegrationDemoGateway =
    InMemoryIntegrationAdminGateway(
      actorUserId: 'demo-super-admin',
      seed: <ProviderKeyRow>[
        ProviderKeyRow(
          credentialId: '00000000-0000-4000-8000-0000000000d1',
          keyKind: ProviderKeyKind.anthropic,
          maskedValue: 'sk-a***Q9aB',
          kmsSecretName: 'kms://stub/seed-anthropic',
          createdBy: 'demo-super-admin',
          updatedBy: 'demo-super-admin',
          rotatedAt: DateTime.utc(2026, 4, 1, 14, 0),
        ),
        ProviderKeyRow(
          credentialId: '00000000-0000-4000-8000-0000000000d2',
          keyKind: ProviderKeyKind.voyage,
          maskedValue: 'pa-v***RtZx',
          kmsSecretName: 'kms://stub/seed-voyage',
          createdBy: 'demo-super-admin',
          updatedBy: 'demo-super-admin',
          rotatedAt: DateTime.utc(2026, 4, 5, 9, 30),
        ),
      ],
    );

/// F.1 fallback health gateway. Seeded with the demo envelope from
/// `health_admin_gateway.dart` so the walkthrough renders all three
/// tabs with realistic green/yellow signals and exercises the
/// dependencies strip without a live proxy.
final HealthAdminGateway _defaultHealthDemoGateway = InMemoryHealthAdminGateway(
  envelope: kHealthAdminDemoEnvelope,
);

/// 11A.6 fallback observability gateway. Seeded with the demo
/// envelope from `observability_admin_gateway.dart`; the click path
/// renders cost telemetry, dormancy, margin, cap events, graph, and
/// Cloud Run sections without the production cost / dormancy proxy
/// endpoints having to be live.
final ObservabilityAdminGateway _defaultObservabilityDemoGateway =
    InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );

/// 11A.7 fallback feature flags gateway. Seeds the launch flag
/// catalog so the demo walkthrough can exercise the toggle and
/// destructive-confirmation paths end-to-end. Mirrors the rows
/// landed by the launch migrations:
///
///   * `audit_logs_cutover_enabled` (destructive) - B.2 cutover flag.
///   * `kms_real_provider_<kind>_enabled` (destructive) - per-lane
///     KMS rollout gates.
///   * `advisor_enabled` (standard) - example launch flag for the
///     advisor surface.
final FeatureFlagsAdminGateway _defaultFeatureFlagsDemoGateway =
    InMemoryFeatureFlagsAdminGateway(
      actorUserId: 'demo-super-admin',
      seed: <FeatureFlagAdminRow>[
        FeatureFlagAdminRow(
          flagId: '00000000-0000-4000-8000-0000000000f1',
          flagName: 'audit_logs_cutover_enabled',
          operatorId: null,
          locationId: null,
          enabled: true,
          kind: kFeatureFlagKindDestructive,
          description:
              'Routes sign-in and admin changes into the permanent audit log. '
              'Turn off only for a rollback.',
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 1, 10, 0),
          updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
        ),
        FeatureFlagAdminRow(
          flagId: '00000000-0000-4000-8000-0000000000f2',
          flagName: 'kms_real_provider_anthropic_enabled',
          operatorId: null,
          locationId: null,
          enabled: false,
          kind: kFeatureFlagKindDestructive,
          description:
              'Uses secure cloud storage for Anthropic service keys instead '
              'of demo storage.',
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 2, 2, 0),
          updatedAt: DateTime.utc(2026, 5, 2, 2, 0),
        ),
        FeatureFlagAdminRow(
          flagId: '00000000-0000-4000-8000-0000000000f3',
          flagName: 'kms_real_provider_voyage_enabled',
          operatorId: null,
          locationId: null,
          enabled: false,
          kind: kFeatureFlagKindDestructive,
          description:
              'Uses secure cloud storage for Voyage service keys instead of '
              'demo storage.',
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 2, 2, 0),
          updatedAt: DateTime.utc(2026, 5, 2, 2, 0),
        ),
        FeatureFlagAdminRow(
          flagId: '00000000-0000-4000-8000-0000000000f4',
          flagName: 'advisor_enabled',
          operatorId: null,
          locationId: null,
          enabled: true,
          kind: kFeatureFlagKindStandard,
          description:
              'Controls whether the advisor experience is available in the '
              'app.',
          updatedBy: 'demo-super-admin',
          createdAt: DateTime.utc(2026, 5, 1, 10, 0),
          updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
        ),
      ],
    );

/// 11A.5 fallback debug console gateway. Seeded with the per-operator
/// request log demo (mixed operators / usage_class / status / opt-ins)
/// so the walkthrough exercises filters, search, live-tail, and the
/// full-content opt-in paths without hitting the proxy.
final DebugConsoleAdminGateway _defaultDebugConsoleDemoGateway =
    InMemoryDebugConsoleAdminGateway(
      seed: kDebugConsoleDemoEntries,
      optInSeed: kDebugConsoleDemoOptIns,
    );

/// Lane B B2.2 fallback Default Role catalog admin gateway. The
/// in-memory implementation persists nothing across runs; the
/// walkthrough lands on the genesis state (no current version) so the
/// click path exercises the empty-state copy + the first-publish flow
/// end-to-end without the Cloud Run admin proxy.
final DefaultRoleCatalogAdminGateway _defaultRoleCatalogAdminDemoGateway =
    InMemoryDefaultRoleCatalogAdminGateway();

/// Phase 8 spine-bridge Lane .C fallback data accuracy + polling/pricing
/// admin gateway. Mirrors the two demo operators on `_defaultDemoGateway`
/// so the walkthrough hops between Operators / Data Accuracy / Polling
/// & Pricing without a backing service. Tier definitions are baked from
/// `kDemoStandardTierDefinition` / `kDemoPremiumTierDefinition` /
/// `kDemoCustomTierDefinition`. One illustrative tier change request
/// drives the Tab 2 Card 4 demo path. Demo Diner Co. → Toronto Yorkville
/// is pre-seeded with a historical admin override so the per-location
/// Data Accuracy audit panel shows a real audit row (RP-15 admin-undo
/// path) instead of the "0 events / No admin overrides recorded yet."
/// empty state.
final DataAccuracyAdminGateway _defaultDataAccuracyDemoGateway = () {
  const dinerOperatorId = '00000000-0000-4000-8000-000000000001';
  const yorkvilleLocationId = '00000000-0000-4000-8000-0000000000a1';
  const yorkvilleSettingsKey = '$dinerOperatorId/$yorkvilleLocationId';
  final overrideAppliedAt = DateTime.utc(2026, 5, 10, 14, 17);
  return InMemoryDataAccuracyAdminGateway(
    operatorLocations: const <OperatorLocationRef>[
      OperatorLocationRef(
        operatorId: dinerOperatorId,
        businessName: 'Demo Diner Co.',
        locationId: yorkvilleLocationId,
        locationName: 'Toronto Yorkville',
      ),
      OperatorLocationRef(
        operatorId: dinerOperatorId,
        businessName: 'Demo Diner Co.',
        locationId: '00000000-0000-4000-8000-0000000000a2',
        locationName: 'Vancouver Robson',
      ),
      OperatorLocationRef(
        operatorId: '00000000-0000-4000-8000-000000000002',
        businessName: 'Sunset Cafe Group',
        locationId: '00000000-0000-4000-8000-0000000000b1',
        locationName: 'Brooklyn Williamsburg',
      ),
    ],
    initialSettings: <String, DataAccuracySettings>{
      yorkvilleSettingsKey: DataAccuracySettings(
        settingId: 'demo-setting-$yorkvilleSettingsKey',
        operatorId: dinerOperatorId,
        locationId: yorkvilleLocationId,
        // Per-Daypart V1 Slice R5 (Gap 27/36): covers source keyed by
        // service period. Lunch = manual; dinner / late_night fall
        // through to the vendor default via coversSourceFor.
        coversSourcePerServicePeriod: const <String, CoversSource>{
          'lunch': CoversSource.manual,
        },
        coversManualEntries: const <String, Map<String, int>>{},
        wageSource: WageSource.manualMix,
        createdAt: DateTime.utc(2026, 5, 1, 9),
        updatedAt: overrideAppliedAt,
        updatedBy: 'support@forgeflow.app',
      ),
    },
    initialTierDefinitions: <PollingTierKey, TierDefinition>{
      PollingTierKey.standard: kDemoStandardTierDefinition(),
      PollingTierKey.premium: kDemoPremiumTierDefinition(),
      PollingTierKey.custom: kDemoCustomTierDefinition(),
    },
    initialChangeRequests: <TierChangeRequest>[
      TierChangeRequest(
        requestId: 'demo-change-request-1',
        operatorRef: const OperatorLocationRef(
          operatorId: dinerOperatorId,
          businessName: 'Demo Diner Co.',
          locationId: yorkvilleLocationId,
          locationName: 'Toronto Yorkville',
        ),
        currentTier: PollingTierKey.standard,
        requestedTier: PollingTierKey.premium,
        operatorNote: 'We need tighter mid-service awareness on dinner volume.',
        submittedAt: DateTime.utc(2026, 5, 4, 14, 30),
        status: TierChangeRequestStatus.pending,
      ),
    ],
    initialAuditLog: <DataAccuracyAdminAuditEvent>[
      DataAccuracyAdminAuditEvent(
        eventId: 'demo-audit-rp15-1',
        eventType: 'admin.data_accuracy.override',
        occurredAt: overrideAppliedAt,
        actorUserId: 'support@forgeflow.app',
        operatorId: dinerOperatorId,
        locationId: yorkvilleLocationId,
        diff: const <String, Object?>{
          'service_period_key': 'lunch',
          'covers_source': <String, Object?>{'from': 'vendor', 'to': 'manual'},
          'wage_source': <String, Object?>{
            'from': 'vendor',
            'to': 'manual_mix',
          },
        },
        reasonNote:
            'Operator reported Toast lunch covers drift; switching to '
            'manual entry while the integration is investigated.',
        actorDisplayName: 'F&F Support',
        actorRole: 'Forge & Flow admin',
        actorEmail: 'support@forgeflow.app',
      ),
    ],
  );
}();

// Realistic demo seed for vendor_applicability — mirrors what an F&F super
// admin would have populated by the time staging/prod is in steady state. All
// 17 supported vendors (POS x7, labor x6, reservation x4) appear at least
// once per applicable kind, with metadata that matches the per-kind schemas
// in lib/services/settings/applicability_metadata_schemas.dart. operator_id
// stays NULL — these are global F&F-admin defaults; per-operator overrides
// would land as separate rows from the admin upsert flow.
final VendorApplicabilityAdminGateway _defaultVendorApplicabilityDemoGateway =
    _InMemoryVendorApplicabilityAdminGateway(
      seed: _seedVendorApplicabilityRows(),
    );

List<VendorApplicabilityAdminRow> _seedVendorApplicabilityRows() {
  final seededAt = DateTime.utc(2026, 5, 13, 15);
  final rows = <VendorApplicabilityAdminRow>[];

  VendorApplicabilityAdminRow row({
    required String id,
    required String settingKind,
    required String settingKey,
    required String vendorSlug,
    required bool enabled,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return VendorApplicabilityAdminRow(
      id: id,
      operatorId: null,
      settingKind: settingKind,
      settingKey: settingKey,
      vendorSlug: vendorSlug,
      enabled: enabled,
      metadata: metadata,
      effectiveFrom: seededAt,
      effectiveUntil: null,
      createdAt: seededAt,
      createdBy: 'demo-super-admin',
    );
  }

  // -- Wage --------------------------------------------------------------
  // Labor vendors are eligible wage sources; POS vendors with payroll
  // add-ons (Toast, Square) are also eligible. Other POS show as disabled
  // so the screen demonstrates both the enabled and disabled states.
  rows.addAll(<VendorApplicabilityAdminRow>[
    row(
      id: 'demo-va-wage-adp',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'adp',
      enabled: true,
      metadata: const <String, Object?>{
        'authority_basis': 'job_code',
        'requires_job_code': true,
        'vendor_field': 'gross_wages',
      },
    ),
    row(
      id: 'demo-va-wage-agendrix',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'agendrix',
      enabled: true,
      metadata: const <String, Object?>{
        'authority_basis': 'job_code',
        'requires_job_code': true,
      },
    ),
    row(
      id: 'demo-va-wage-humanity',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'humanity',
      enabled: true,
      metadata: const <String, Object?>{'authority_basis': 'vendor_pay_rate'},
    ),
    row(
      id: 'demo-va-wage-push-operations',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'push_operations',
      enabled: true,
      metadata: const <String, Object?>{'authority_basis': 'vendor_pay_rate'},
    ),
    row(
      id: 'demo-va-wage-quickbooks-time',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'quickbooks_time',
      enabled: true,
      metadata: const <String, Object?>{'authority_basis': 'vendor_pay_rate'},
    ),
    row(
      id: 'demo-va-wage-seven-shifts',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'seven_shifts',
      enabled: true,
      metadata: const <String, Object?>{
        'authority_basis': 'job_code',
        'requires_job_code': true,
      },
    ),
    row(
      id: 'demo-va-wage-toast',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'toast',
      enabled: true,
      metadata: const <String, Object?>{
        'authority_basis': 'vendor_pay_rate',
        'vendor_field': 'gross_wages',
        'notes': 'Requires Toast Payroll add-on.',
      },
    ),
    row(
      id: 'demo-va-wage-square',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'square',
      enabled: true,
      metadata: const <String, Object?>{
        'authority_basis': 'vendor_pay_rate',
        'notes': 'Requires Square Payroll subscription.',
      },
    ),
    row(
      id: 'demo-va-wage-clover',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'clover',
      enabled: false,
      metadata: const <String, Object?>{
        'authority_basis': 'manual_mapping',
        'notes': 'Clover labor module not certified for wage authority.',
      },
    ),
    row(
      id: 'demo-va-wage-oracle-micros-simphony',
      settingKind: 'wage',
      settingKey: 'default',
      vendorSlug: 'oracle_micros_simphony',
      enabled: false,
      metadata: const <String, Object?>{
        'authority_basis': 'manual_mapping',
        'notes': 'Simphony exports rates only; not approved as wage source.',
      },
    ),
  ]);

  // -- Covers ------------------------------------------------------------
  // Reservation vendors track real guest counts (all_covers); POS vendors
  // approximate covers from dine-in checks (dine_in_only) with voids
  // excluded so service-period totals do not double-count.
  rows.addAll(<VendorApplicabilityAdminRow>[
    row(
      id: 'demo-va-covers-libro',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'libro',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'all_covers',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-opentable',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'opentable',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'all_covers',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-sevenrooms',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'sevenrooms',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'all_covers',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-tock',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'tock',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'all_covers',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-toast',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'toast',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-square',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'square',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-clover',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'clover',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-aloha-ncr-voyix',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'aloha_ncr_voyix',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-lightspeed-lsk',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'lightspeed_lsk',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-revel',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'revel',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
    row(
      id: 'demo-va-covers-oracle-micros-simphony',
      settingKind: 'covers',
      settingKey: 'default',
      vendorSlug: 'oracle_micros_simphony',
      enabled: true,
      metadata: const <String, Object?>{
        'cover_filter': 'dine_in_only',
        'exclude_voids': true,
      },
    ),
  ]);

  // -- Polling -----------------------------------------------------------
  // Every supported vendor lands on the standard polling tier by default.
  // Toast also has a premium-tier override row so the screen demonstrates
  // multi-setting_key grouping (production typically has tiered overrides
  // for high-volume operators).
  const standardPollingVendors = <String>[
    'adp',
    'agendrix',
    'aloha_ncr_voyix',
    'clover',
    'humanity',
    'libro',
    'lightspeed_lsk',
    'opentable',
    'oracle_micros_simphony',
    'push_operations',
    'quickbooks_time',
    'revel',
    'seven_shifts',
    'sevenrooms',
    'square',
    'toast',
    'tock',
  ];
  for (final vendor in standardPollingVendors) {
    rows.add(
      row(
        id: 'demo-va-polling-standard-${vendor.replaceAll('_', '-')}',
        settingKind: 'polling',
        settingKey: 'standard',
        vendorSlug: vendor,
        enabled: true,
        metadata: const <String, Object?>{'tier_key': 'standard'},
      ),
    );
  }
  rows.add(
    row(
      id: 'demo-va-polling-premium-toast',
      settingKind: 'polling',
      settingKey: 'premium',
      vendorSlug: 'toast',
      enabled: true,
      metadata: const <String, Object?>{
        'tier_key': 'premium',
        'polling_seconds_override': 60,
      },
    ),
  );

  return rows;
}

class _InMemoryVendorApplicabilityAdminGateway
    implements VendorApplicabilityAdminGateway {
  _InMemoryVendorApplicabilityAdminGateway({
    required Iterable<VendorApplicabilityAdminRow> seed,
  }) : _rows = seed.toList(growable: true);

  final List<VendorApplicabilityAdminRow> _rows;
  int _sequence = 0;

  @override
  Future<List<VendorApplicabilityAdminRow>> list({
    VendorApplicabilityAdminFilter filter =
        const VendorApplicabilityAdminFilter(),
  }) async {
    return _rows
        .where((row) {
          if (filter.operatorId != null &&
              row.operatorId != filter.operatorId) {
            return false;
          }
          if (filter.locationId != null &&
              row.locationId != filter.locationId) {
            return false;
          }
          if (filter.settingKind != null &&
              row.settingKind != filter.settingKind) {
            return false;
          }
          if (filter.settingKey != null &&
              row.settingKey != filter.settingKey) {
            return false;
          }
          if (filter.vendorSlug != null &&
              row.vendorSlug != filter.vendorSlug) {
            return false;
          }
          if (filter.currentOnly && row.effectiveUntil != null) return false;
          return true;
        })
        .toList(growable: false);
  }

  @override
  Future<VendorApplicabilityAdminRow> upsert(
    VendorApplicabilityUpsertCommand command,
  ) async {
    final now = DateTime.now().toUtc();
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      // Close only the row in the exact same scope (operator + location
      // + kind/key/vendor), so a location write never closes the
      // operator-level row and vice versa. Mirrors the repository's
      // `is not distinct from` temporal close.
      if (row.operatorId == command.operatorId &&
          row.locationId == command.locationId &&
          row.settingKind == command.settingKind &&
          row.settingKey == command.settingKey &&
          row.vendorSlug == command.vendorSlug &&
          row.effectiveUntil == null) {
        _rows[i] = _copyRow(row, effectiveUntil: now);
      }
    }
    _sequence += 1;
    final row = VendorApplicabilityAdminRow(
      id: 'demo-va-row-$_sequence',
      operatorId: command.operatorId,
      locationId: command.locationId,
      settingKind: command.settingKind,
      settingKey: command.settingKey,
      vendorSlug: command.vendorSlug,
      enabled: command.enabled,
      metadata: command.metadata,
      effectiveFrom: command.effectiveFrom ?? now,
      effectiveUntil: null,
      createdAt: now,
      createdBy: 'demo-super-admin',
    );
    _rows.add(row);
    return row;
  }

  @override
  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  ) async {
    final until = command.effectiveUntil ?? DateTime.now().toUtc();
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row.operatorId == command.operatorId &&
          row.locationId == command.locationId &&
          row.settingKind == command.settingKind &&
          row.settingKey == command.settingKey &&
          row.vendorSlug == command.vendorSlug &&
          row.effectiveUntil == null) {
        final ended = _copyRow(row, effectiveUntil: until);
        _rows[i] = ended;
        return ended;
      }
    }
    return null;
  }

  VendorApplicabilityAdminRow _copyRow(
    VendorApplicabilityAdminRow row, {
    DateTime? effectiveUntil,
  }) {
    return VendorApplicabilityAdminRow(
      id: row.id,
      operatorId: row.operatorId,
      locationId: row.locationId,
      settingKind: row.settingKind,
      settingKey: row.settingKey,
      vendorSlug: row.vendorSlug,
      enabled: row.enabled,
      metadata: row.metadata,
      effectiveFrom: row.effectiveFrom,
      effectiveUntil: effectiveUntil,
      createdAt: row.createdAt,
      createdBy: row.createdBy,
    );
  }
}

/// Phase 11A.12 - cross-operator Members + Invites demo gateway.
/// Seeded from `kDemoMembersByOperator` / `kDemoInvitesByOperator`
/// (same demo identities the .C / 11A.1 walkthroughs use) so a F&F
/// admin can sign in, pick an operator, and exercise filter chips +
/// row actions + the invite flow without a live proxy.
final MembersAdminGateway _defaultMembersAdminDemoGateway =
    InMemoryMembersAdminGateway(
      membersByOperator: kDemoMembersByOperator(),
      invitesByOperator: kDemoInvitesByOperator(),
    );

/// Phase 11A.13 - Roles + Hierarchy + Sessions demo gateway. Reuses
/// the operators on the Members demo so the walkthrough can hop
/// straight from the Members surface into Roles / Hierarchy /
/// Sessions for the same operator.
final RolesHierarchySessionsAdminGateway
_defaultRolesHierarchySessionsAdminDemoGateway =
    InMemoryRolesHierarchySessionsAdminGateway(
      rolesByOperator: kDemoRolesByOperator(),
      orgUnitsByOperator: kDemoOrgUnitsByOperator(),
      locationsByOperator: kDemoHierarchyLocationsByOperator(),
      sessionsByOperator: kDemoSessionsByOperator(),
    );

/// Phase 11A.14 - Audited support actions demo gateway. Seeded with
/// the audit-log entries + members fixture from
/// `kDemoAuditLogByOperator` / `kDemoSupportActionsMembersByOperator`
/// so the walkthrough can hop straight from any prior 11W / 11A
/// operator-scoped surface into the audit-log + support-actions
/// surface for the same operator.
final AuditedSupportActionsAdminGateway
_defaultAuditedSupportActionsAdminDemoGateway =
    InMemoryAuditedSupportActionsAdminGateway(
      auditLogByOperator: kDemoAuditLogByOperator(),
      membersByOperator: kDemoSupportActionsMembersByOperator(),
    );

/// Audit fix-first #2 (G2) — seeded in-memory admin Active Sessions
/// gateway shared by the kDemoMode / share-preview walkthrough when no
/// live `AdminSessionsGateway` is wired. Lets the My Account Active
/// Sessions card render its list + revoke + sign-out-everywhere click
/// path without the Cloud Run admin proxy.
final AdminSessionsGateway _defaultAdminSessionsDemoGateway =
    InMemoryAdminSessionsGateway();

/// Audit fix-first #7 (cross-surface parity finding G4) — seeded
/// in-memory admin Security gateway shared by the kDemoMode /
/// share-preview walkthrough when no live `AdminSecurityGateway` is
/// wired. Seeded with NO enrolled factor so the walkthrough exercises
/// the enroll → confirm path (and the recovery + password-change
/// paths) without the Cloud Run admin proxy.
final AdminSecurityGateway _defaultAdminSecurityDemoGateway =
    InMemoryAdminSecurityGateway();

/// X-G71 — seeded in-memory admin notification-preferences gateway
/// shared by the kDemoMode / share-preview walkthrough when no live
/// `AdminNotificationPreferencesGateway` is wired. Seeded EMPTY so
/// every catalog row renders at its default channels until the admin
/// toggles one (the walkthrough exercises the toggle + save click path
/// without the Cloud Run admin proxy).
final AdminNotificationPreferencesGateway
_defaultAdminNotificationPreferencesDemoGateway =
    InMemoryAdminNotificationPreferencesGateway();
