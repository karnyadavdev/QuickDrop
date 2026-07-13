import 'package:path/path.dart' as p;

class SafeFileName {
  static String clean(String rawName, {required bool isFolder}) =>
      _clean(rawName, isFolder: isFolder);

  static String _clean(String rawName, {required bool isFolder}) {
    final raw = rawName.trim();
    final fallback = isFolder ? 'SharedFolder' : 'SharedFile';
    if (raw.isEmpty) return fallback;

    final slashNormalized = raw.replaceAll('\\', '/');
    final base = p.basename(slashNormalized);
    final clean = _trimEnd(
      base.replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_').trim(),
    );
    if (_notAllowed(clean)) {
      return fallback;
    }

    final shortName = clean.length > 180
        ? _trimEnd(clean.substring(0, 180))
        : clean;
    if (_notAllowed(shortName)) return fallback;
    return _fixCopyName(shortName);
  }

  static bool _notAllowed(String name) {
    return name.isEmpty ||
        name == '.' ||
        name == '..' ||
        _windowsReserved(name);
  }

  static bool _windowsReserved(String name) {
    final stem = p.basenameWithoutExtension(name).toUpperCase();
    return stem == 'CON' ||
        stem == 'PRN' ||
        stem == 'AUX' ||
        stem == 'NUL' ||
        RegExp(r'^COM[1-9]$').hasMatch(stem) ||
        RegExp(r'^LPT[1-9]$').hasMatch(stem);
  }

  static String _trimEnd(String name) {
    var result = name;
    while (result.endsWith('.') || result.endsWith(' ')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static String _fixCopyName(String name) {
    final match = RegExp(r'^(.*)(\.[^. ]+) \((\d+)\)$').firstMatch(name);
    if (match == null) return name;
    return '${match.group(1)} (${match.group(3)})${match.group(2)}';
  }
}
