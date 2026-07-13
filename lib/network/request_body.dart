import 'dart:async';
import 'dart:convert';

class RequestBody {
  static Future<String> readUtf8(
    Stream<List<int>> stream, {
    required int maxBytes,
  }) async {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes');
    }

    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const RequestTooLarge();
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }
}

class RequestTooLarge implements Exception {
  const RequestTooLarge();
}
