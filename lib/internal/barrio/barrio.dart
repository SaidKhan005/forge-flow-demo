/// Barrio -- Private Internal Boundary
///
/// This library is the entry point for all Barrio-private code inside the
/// Forge & Flow repository.
///
/// ## Ownership Rules
///
/// - **Forge & Flow** is the shared customer-facing product.
///   All core domain models, persistence, services, screens, and navigation
///   live outside this boundary and must not be duplicated here.
///
/// - **Barrio** is an internal build identity that lives *inside* the same
///   repo. It is not a fork of Forge & Flow. It is a private layer that
///   adds internal-only destinations, content surfaces, and branding on
///   top of the shared product core.
///
/// - The private shell, route map, and destination screens were built in
///   7.52f. Content surfaces (7.52g/h) and real auth gating (Phase 9)
///   are future work.
///
/// ## What Belongs Here
///
/// - Barrio-private route/destination definitions
/// - Barrio-private shell, screen, and widget implementations
/// - Source-material metadata references (not the raw files themselves)
/// - Internal content models for handbook, playbook, and labor-model surfaces
///
/// ## What Does NOT Belong Here
///
/// - Copies of Forge & Flow domain models, services, or persistence code
/// - Auth, login, or permission enforcement (Phase 9)
/// - Cross-device sync logic (Phase 10)
/// - Raw document viewers for PDF/HTML source material
/// - Anything that modifies the public Forge & Flow runtime bundle
library;

// Route/destination metadata
export 'routes/barrio_destinations.dart';
export 'routes/barrio_route_map.dart';

// Source-material catalog
export 'content/barrio_source_material.dart';

// El Podio scoreboard
export 'content/el_podio_demo_data.dart';
export 'screens/el_podio_screen.dart';

// Shell entry point
export 'screens/barrio_home_screen.dart';

// Reusable shell widgets
export 'widgets/barrio_destination_scaffold.dart';
export 'widgets/barrio_bubble_hub.dart';
export 'widgets/barrio_ambient_leaves.dart';
