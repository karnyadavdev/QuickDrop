import 'dart:math' as math;

class LocalIdentity {
  final String id;
  final String name;

  const LocalIdentity({required this.id, required this.name});

  factory LocalIdentity.random({math.Random? random}) {
    final source = random ?? math.Random.secure();
    final profileName = _names[source.nextInt(_names.length)];
    final pin = source.nextInt(9000) + 1000;

    return LocalIdentity(id: _randomHex(source, 8), name: '$profileName $pin');
  }

  static String _randomHex(math.Random random, int byteCount) {
    const hex = '0123456789abcdef';
    final buffer = StringBuffer();
    for (var i = 0; i < byteCount; i++) {
      final byte = random.nextInt(256);
      buffer
        ..write(hex[byte >> 4])
        ..write(hex[byte & 0x0f]);
    }
    return buffer.toString();
  }
}

const List<String> _names = [
  'Voyager',
  'Pioneer',
  'Apollo',
  'Node',
  'Station',
  'Terminal',
  'Host',
  'Device',
  'Beacon',
  'Satellite',
];
