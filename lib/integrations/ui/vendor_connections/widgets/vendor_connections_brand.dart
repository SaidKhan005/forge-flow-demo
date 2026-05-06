// Phase 8.0 / Wave C1 — Vendor brand catalog + logo widgets for the
// shared Vendor Connections widget tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable.

part of '../vendor_connections_widget.dart';

class _VendorLogo extends StatelessWidget {
  const _VendorLogo({
    required this.vendorId,
    required this.displayName,
    this.size = 48,
  });

  final String vendorId;
  final String displayName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brand = _vendorBrand(vendorId, displayName);
    final fallback = _VendorInitials(brand: brand);
    return Tooltip(
      message: brand.iconUrl == null
          ? '${brand.displayName} logo'
          : 'Official ${brand.displayName} icon from ${brand.sourceHost}',
      child: SizedBox(
        width: size,
        height: size,
        child: brand.iconUrl == null || !kIsWeb
            ? fallback
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  brand.iconUrl!,
                  fit: BoxFit.cover,
                  webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                  errorBuilder: (_, __, ___) => fallback,
                ),
              ),
      ),
    );
  }
}

class _VendorInitials extends StatelessWidget {
  const _VendorInitials({required this.brand});

  final _VendorBrand brand;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: brand.color.withValues(alpha: 0.13),
        border: Border.all(color: brand.color.withValues(alpha: 0.44)),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        brand.initials,
        style: AppTextStyles.chipLabel(color: brand.color),
      ),
    );
  }
}

class _VendorBrand {
  const _VendorBrand({
    required this.displayName,
    required this.initials,
    required this.color,
    this.iconUrl,
    this.sourceHost,
  });

  final String displayName;
  final String initials;
  final Color color;
  final String? iconUrl;
  final String? sourceHost;
}

_VendorBrand _vendorBrand(String vendorId, String displayName) {
  switch (vendorId) {
    case 'aloha_ncr_voyix':
      return const _VendorBrand(
        displayName: 'Aloha (NCR Voyix)',
        initials: 'NCR',
        color: Color(0xFF004C97),
        iconUrl: 'https://developer.ncrvoyix.com/favicon.ico',
        sourceHost: 'developer.ncrvoyix.com',
      );
    case 'clover':
      return const _VendorBrand(
        displayName: 'Clover',
        initials: 'Cl',
        color: Color(0xFF00875A),
        iconUrl: 'https://www.clover.com/favicon.ico',
        sourceHost: 'clover.com',
      );
    case 'lightspeed_lsk':
      return const _VendorBrand(
        displayName: 'Lightspeed',
        initials: 'LS',
        color: Color(0xFFE21B2D),
        iconUrl: 'https://www.lightspeedhq.com/favicon.ico',
        sourceHost: 'lightspeedhq.com',
      );
    case 'oracle_micros_simphony':
      return const _VendorBrand(
        displayName: 'Oracle MICROS Simphony',
        initials: 'Or',
        color: Color(0xFFC74634),
        iconUrl: 'https://www.oracle.com/favicon.ico',
        sourceHost: 'oracle.com',
      );
    case 'revel':
      return const _VendorBrand(
        displayName: 'Revel Systems',
        initials: 'Rv',
        color: Color(0xFF2B5C8A),
        iconUrl: 'https://revelsystems.com/favicon.ico',
        sourceHost: 'revelsystems.com',
      );
    case 'square':
      return const _VendorBrand(
        displayName: 'Square',
        initials: 'Sq',
        color: Color(0xFF111827),
        iconUrl: 'https://squareup.com/favicon.ico',
        sourceHost: 'squareup.com',
      );
    case 'toast':
      return const _VendorBrand(
        displayName: 'Toast',
        initials: 'To',
        color: Color(0xFFFF4F00),
        iconUrl: 'https://www.toasttab.com/favicon.ico',
        sourceHost: 'toasttab.com',
      );
    case 'libro':
      return const _VendorBrand(
        displayName: 'Libro Reserve',
        initials: 'Li',
        color: Color(0xFF006C5B),
        iconUrl: 'https://librorez.com/favicon.ico',
        sourceHost: 'librorez.com',
      );
    case 'opentable':
      return const _VendorBrand(
        displayName: 'OpenTable',
        initials: 'OT',
        color: Color(0xFFDA3743),
        iconUrl: 'https://www.opentable.com/favicon.ico',
        sourceHost: 'opentable.com',
      );
    case 'sevenrooms':
      return const _VendorBrand(
        displayName: 'SevenRooms',
        initials: '7R',
        color: Color(0xFF25364A),
        iconUrl: 'https://sevenrooms.com/favicon.ico',
        sourceHost: 'sevenrooms.com',
      );
    case 'tock':
      return const _VendorBrand(
        displayName: 'Tock',
        initials: 'Tk',
        color: Color(0xFF1F2933),
        iconUrl: 'https://www.exploretock.com/favicon.ico',
        sourceHost: 'exploretock.com',
      );
    case 'adp':
      return const _VendorBrand(
        displayName: 'ADP Workforce Now / Workforce Manager',
        initials: 'ADP',
        color: Color(0xFFD0271D),
        iconUrl: 'https://www.adp.com/favicon.ico',
        sourceHost: 'adp.com',
      );
    case 'agendrix':
      return const _VendorBrand(
        displayName: 'Agendrix',
        initials: 'Ag',
        color: Color(0xFF246BFE),
        iconUrl: 'https://www.agendrix.com/favicon.ico',
        sourceHost: 'agendrix.com',
      );
    case 'humanity':
      return const _VendorBrand(
        displayName: 'Humanity',
        initials: 'Hu',
        color: Color(0xFF2463EB),
        iconUrl: 'https://www.humanity.com/favicon.ico',
        sourceHost: 'humanity.com',
      );
    case 'push_operations':
      return const _VendorBrand(
        displayName: 'Push Operations',
        initials: 'Pu',
        color: Color(0xFF22577A),
        iconUrl: 'https://www.pushoperations.com/favicon.ico',
        sourceHost: 'pushoperations.com',
      );
    case 'quickbooks_time':
      return const _VendorBrand(
        displayName: 'QuickBooks Time',
        initials: 'QB',
        color: Color(0xFF2CA01C),
        iconUrl: 'https://www.intuit.com/favicon.ico',
        sourceHost: 'quickbooks.intuit.com',
      );
    case 'seven_shifts':
      return const _VendorBrand(
        displayName: '7shifts',
        initials: '7s',
        color: Color(0xFF2E6B4F),
        iconUrl: 'https://www.7shifts.com/favicon.ico',
        sourceHost: '7shifts.com',
      );
    default:
      final words = displayName
          .split(RegExp(r'\s+'))
          .where((word) => word.trim().isNotEmpty)
          .take(2)
          .toList();
      final initials = words.isEmpty
          ? '?'
          : words.map((word) => word.substring(0, 1)).join();
      return _VendorBrand(
        displayName: displayName,
        initials: initials,
        color: AppColors.sunsetDark,
      );
  }
}
