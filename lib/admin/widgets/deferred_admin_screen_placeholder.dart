// Phase 11A — Admin deferred route placeholder.
//
// Renders a gentle "coming soon" state for deferred 11A routes
// (operators/<id>/{members,roles,audit}) when they are routed to
// ahead of their slice landing. The widget displays a soft illustration
// + "Arriving in your next update" + operator-friendly one-line copy
// explaining what the surface will do.

import 'package:flutter/material.dart';

/// Deferred placeholder for Admin Console 11A routes.
///
/// Renders when a route is navigated to before its slice lands.
/// The screen provides a gentle, encouraging "coming soon" experience
/// with operator-friendly copy about what's arriving.
class DeferredAdminScreenPlaceholder extends StatelessWidget {
  const DeferredAdminScreenPlaceholder({
    super.key,
    required this.title,
    required this.description,
  });

  /// The name of the surface (e.g., "People", "Access", "Security & audit").
  final String title;

  /// One-line operator-friendly copy explaining what this surface does
  /// (e.g., "Review team members and manage their role assignments").
  final String description;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const SizedBox(height: 40),
            // Soft illustration placeholder (gentle circle with icon)
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
              ),
              child: Center(
                child: Icon(
                  Icons.schedule_outlined,
                  size: 60,
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                ),
              ),
            ),
            const SizedBox(height: 32),
            // Title
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            // "Arriving in your next update" message
            Text(
              'Arriving in your next update',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                    fontWeight: FontWeight.w500,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            // Operator-friendly description
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }
}
