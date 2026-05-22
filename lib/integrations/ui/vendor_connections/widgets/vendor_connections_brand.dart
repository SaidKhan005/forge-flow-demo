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
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) {
                        if (wasSynchronouslyLoaded || frame != null) {
                          return child;
                        }
                        return fallback;
                      },
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

String _brandIconUrl(String domain) =>
    'https://www.google.com/s2/favicons?domain=$domain&sz=64';

_VendorBrand _vendorBrand(String vendorId, String displayName) {
  switch (vendorId) {
    case 'aloha_ncr_voyix':
      return _VendorBrand(
        displayName: 'Aloha (NCR Voyix)',
        initials: 'NCR',
        color: const Color(0xFF004C97),
        iconUrl: _brandIconUrl('ncrvoyix.com'),
        sourceHost: 'ncrvoyix.com',
      );
    case 'clover':
      return _VendorBrand(
        displayName: 'Clover',
        initials: 'Cl',
        color: const Color(0xFF00875A),
        iconUrl: _brandIconUrl('clover.com'),
        sourceHost: 'clover.com',
      );
    case 'lightspeed_lsk':
      return _VendorBrand(
        displayName: 'Lightspeed',
        initials: 'LS',
        color: const Color(0xFFE21B2D),
        iconUrl: _brandIconUrl('lightspeedhq.com'),
        sourceHost: 'lightspeedhq.com',
      );
    case 'oracle_micros_simphony':
      return _VendorBrand(
        displayName: 'Oracle MICROS Simphony',
        initials: 'Or',
        color: const Color(0xFFC74634),
        iconUrl: _brandIconUrl('oracle.com'),
        sourceHost: 'oracle.com',
      );
    case 'revel':
      return _VendorBrand(
        displayName: 'Revel Systems',
        initials: 'Rv',
        color: const Color(0xFF2B5C8A),
        iconUrl: _brandIconUrl('revelsystems.com'),
        sourceHost: 'revelsystems.com',
      );
    case 'square':
      return _VendorBrand(
        displayName: 'Square',
        initials: 'Sq',
        color: const Color(0xFF111827),
        iconUrl: _brandIconUrl('squareup.com'),
        sourceHost: 'squareup.com',
      );
    case 'toast':
      return _VendorBrand(
        displayName: 'Toast',
        initials: 'To',
        color: const Color(0xFFFF4F00),
        iconUrl: _brandIconUrl('toasttab.com'),
        sourceHost: 'toasttab.com',
      );
    case 'libro':
      return _VendorBrand(
        displayName: 'Libro Reserve',
        initials: 'Li',
        color: const Color(0xFF006C5B),
      );
    case 'opentable':
      return _VendorBrand(
        displayName: 'OpenTable',
        initials: 'OT',
        color: const Color(0xFFDA3743),
        iconUrl: _brandIconUrl('opentable.com'),
        sourceHost: 'opentable.com',
      );
    case 'sevenrooms':
      return _VendorBrand(
        displayName: 'SevenRooms',
        initials: '7R',
        color: const Color(0xFF25364A),
        iconUrl: _brandIconUrl('sevenrooms.com'),
        sourceHost: 'sevenrooms.com',
      );
    case 'tock':
      return _VendorBrand(
        displayName: 'Tock',
        initials: 'Tk',
        color: const Color(0xFF1F2933),
        iconUrl: _brandIconUrl('exploretock.com'),
        sourceHost: 'exploretock.com',
      );
    case 'adp':
      return _VendorBrand(
        displayName: 'ADP Workforce Now / Workforce Manager',
        initials: 'ADP',
        color: const Color(0xFFD0271D),
        iconUrl: _brandIconUrl('adp.com'),
        sourceHost: 'adp.com',
      );
    case 'agendrix':
      return _VendorBrand(
        displayName: 'Agendrix',
        initials: 'Ag',
        color: const Color(0xFF246BFE),
        iconUrl: _brandIconUrl('agendrix.com'),
        sourceHost: 'agendrix.com',
      );
    case 'humanity':
      return _VendorBrand(
        displayName: 'Humanity',
        initials: 'Hu',
        color: const Color(0xFF2463EB),
        iconUrl: _brandIconUrl('humanity.com'),
        sourceHost: 'humanity.com',
      );
    case 'push_operations':
      return _VendorBrand(
        displayName: 'Push Operations',
        initials: 'Pu',
        color: const Color(0xFF22577A),
        iconUrl: _brandIconUrl('pushoperations.com'),
        sourceHost: 'pushoperations.com',
      );
    case 'quickbooks_time':
      return _VendorBrand(
        displayName: 'QuickBooks Time',
        initials: 'QB',
        color: const Color(0xFF2CA01C),
        iconUrl: _brandIconUrl('quickbooks.intuit.com'),
        sourceHost: 'quickbooks.intuit.com',
      );
    case 'seven_shifts':
      return _VendorBrand(
        displayName: '7shifts',
        initials: '7s',
        color: const Color(0xFF2E6B4F),
        iconUrl: _brandIconUrl('7shifts.com'),
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
