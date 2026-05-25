import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/role_key_generator.dart';

void main() {
  group('generateRoleKeyFromDisplayName', () {
    test('turns a plain display name into a backend-safe key', () {
      expect(generateRoleKeyFromDisplayName('Kitchen Lead'), 'kitchen_lead');
    });

    test('uses a role prefix when the name starts with a number', () {
      expect(
        generateRoleKeyFromDisplayName('24 Hour Manager'),
        'role_24_hour_manager',
      );
    });

    test('adds a suffix when the generated key already exists', () {
      expect(
        generateRoleKeyFromDisplayName(
          'Kitchen Lead',
          existingKeys: <String>{'kitchen_lead', 'kitchen_lead_2'},
        ),
        'kitchen_lead_3',
      );
    });

    test('keeps generated keys within the gateway length limit', () {
      final key = generateRoleKeyFromDisplayName(
        'This role name is deliberately far longer than the role key limit',
      );

      expect(key.length, lessThanOrEqualTo(64));
      expect(key, startsWith('this_role_name'));
    });
  });
}
