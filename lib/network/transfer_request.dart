import 'dart:convert';
import 'dart:typed_data';

import 'file_encryption.dart';

class TransferRequest {
  final String senderId;
  final String requestId;
  final String senderName;
  final String senderDeviceType;
  final String fileName;
  final int fileSize;
  final bool isFolder;
  final String publicKey;
  final Uint8List publicKeyBytes;
  final String contentEncryption;
  final int encryptionChunkSize;

  const TransferRequest({
    required this.senderId,
    required this.requestId,
    required this.senderName,
    required this.senderDeviceType,
    required this.fileName,
    required this.fileSize,
    required this.isFolder,
    required this.publicKey,
    required this.publicKeyBytes,
    required this.contentEncryption,
    required this.encryptionChunkSize,
  });

  factory TransferRequest.fromJson(Map<String, dynamic> json) {
    final fileSize = _readFileSize(json['fileSize']);
    final publicKey = _readText(json, 'publicKey', maxLength: 128);
    final contentEncryption = _readEncryption(json['contentEncryption']);
    final encryptionChunkSize = _readChunkSize(
      json['encryptionChunkSize'],
      contentEncryption,
    );
    return TransferRequest(
      senderId: _readText(json, 'id', maxLength: 64),
      requestId: _readText(json, 'requestId', maxLength: 128),
      senderName: _readText(json, 'name', maxLength: 32),
      senderDeviceType: _readDeviceType(json['deviceType']),
      fileName: _readText(json, 'fileName', maxLength: 220),
      fileSize: fileSize,
      isFolder: json['isFolder'] == true,
      publicKey: publicKey,
      publicKeyBytes: _decodeKey(publicKey),
      contentEncryption: contentEncryption,
      encryptionChunkSize: encryptionChunkSize,
    );
  }

  static String _readText(
    Map<String, dynamic> json,
    String key, {
    required int maxLength,
  }) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Missing transfer field: $key.');
    }

    final trimmed = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (trimmed.isEmpty) {
      throw FormatException('Empty transfer field: $key.');
    }
    return trimmed.length > maxLength
        ? trimmed.substring(0, maxLength)
        : trimmed;
  }

  static int _readFileSize(Object? value) {
    if (value is! int) {
      throw const FormatException('Invalid file size in transfer request.');
    }

    if (value < 0) {
      throw const FormatException('Invalid file size in transfer request.');
    }
    return value;
  }

  static String _readEncryption(Object? value) {
    if (value is! String) {
      throw const FormatException('Missing content encryption mode.');
    }
    if (value != noEncryption && value != fileEncryption) {
      throw const UnsupportedEncryption();
    }
    return value;
  }

  static int _readChunkSize(Object? value, String encryption) {
    if (value is! int) {
      throw const FormatException('Missing encryption chunk size.');
    }
    final expected = encryption == fileEncryption ? encryptionBlockSize : 0;
    if (value != expected) {
      throw const UnsupportedEncryption();
    }
    return value;
  }

  static String _readDeviceType(Object? value) {
    if (value is String &&
        (value == 'mobile' || value == 'desktop' || value == 'linux')) {
      return value;
    }
    return 'desktop';
  }

  static Uint8List _decodeKey(String value) {
    try {
      final bytes = Uint8List.fromList(base64Decode(value));
      if (bytes.length != 32) {
        throw const FormatException('Invalid public key.');
      }
      return bytes;
    } catch (_) {
      throw const FormatException('Invalid public key.');
    }
  }
}

class TransferReply {
  final String status;
  final String? publicKey;
  final Uint8List? publicKeyBytes;
  final String contentEncryption;
  final int encryptionChunkSize;

  const TransferReply({
    required this.status,
    required this.publicKey,
    required this.publicKeyBytes,
    required this.contentEncryption,
    required this.encryptionChunkSize,
  });

  factory TransferReply.fromJson(Map<String, dynamic> json) {
    final value = json['status'];
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('Missing transfer response status.');
    }

    final status = value.trim();
    if (status == 'rejected') {
      return const TransferReply(
        status: 'rejected',
        publicKey: null,
        publicKeyBytes: null,
        contentEncryption: noEncryption,
        encryptionChunkSize: 0,
      );
    }
    if (status != 'accepted' && status != 'pending') {
      throw const FormatException('Invalid transfer response status.');
    }
    final publicKey = TransferRequest._readText(
      json,
      'publicKey',
      maxLength: 128,
    );
    final contentEncryption = TransferRequest._readEncryption(
      json['contentEncryption'],
    );
    final encryptionChunkSize = TransferRequest._readChunkSize(
      json['encryptionChunkSize'],
      contentEncryption,
    );
    return TransferReply(
      status: status,
      publicKey: publicKey,
      publicKeyBytes: TransferRequest._decodeKey(publicKey),
      contentEncryption: contentEncryption,
      encryptionChunkSize: encryptionChunkSize,
    );
  }
}

class UploadReply {
  const UploadReply();

  factory UploadReply.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    if (status != 'success') {
      throw const FormatException('Receiver did not confirm upload success.');
    }
    return const UploadReply();
  }
}

class UploadInfo {
  final String fileName;
  final int fileSize;
  final bool isFolder;
  final String senderId;
  final String requestId;
  final String contentEncryption;
  final int encryptionChunkSize;

  const UploadInfo({
    required this.fileName,
    required this.fileSize,
    required this.isFolder,
    required this.senderId,
    required this.requestId,
    required this.contentEncryption,
    required this.encryptionChunkSize,
  });

  factory UploadInfo.fromHeaders({
    required String? encodedFileName,
    required String? fileSize,
    required String? isFolder,
    required String? senderId,
    required String? requestId,
    required String? contentEncryption,
    required String? encryptionChunkSize,
  }) {
    final name = _decodeFileName(encodedFileName);
    final size = _readHeaderInt(fileSize, 'x-file-size');
    final folder = _readHeaderBool(isFolder, 'x-is-folder');
    final sender = _readHeaderText(senderId, 'x-sender-id');
    final request = _readHeaderText(requestId, 'x-request-id');
    final encryption = _readHeaderText(
      contentEncryption,
      'x-content-encryption',
    );
    if (encryption != noEncryption && encryption != fileEncryption) {
      throw const UnsupportedEncryption();
    }
    final chunkSize = _readHeaderInt(
      encryptionChunkSize,
      'x-encryption-chunk-size',
    );
    final expectedChunkSize = encryption == fileEncryption
        ? encryptionBlockSize
        : 0;
    if (chunkSize != expectedChunkSize) {
      throw const UnsupportedEncryption();
    }
    return UploadInfo(
      fileName: name,
      fileSize: size,
      isFolder: folder,
      senderId: sender,
      requestId: request,
      contentEncryption: encryption,
      encryptionChunkSize: chunkSize,
    );
  }

  static String _decodeFileName(String? value) {
    final raw = _readHeaderText(value, 'x-file-name');
    try {
      final decoded = Uri.decodeComponent(raw).trim();
      if (decoded.isEmpty) {
        throw const FormatException('Empty upload file name.');
      }
      return decoded.length > 220 ? decoded.substring(0, 220) : decoded;
    } catch (_) {
      throw const FormatException('Invalid upload file name.');
    }
  }

  static String _readHeaderText(String? value, String name) {
    if (value == null) {
      throw FormatException('Missing upload header: $name.');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw FormatException('Empty upload header: $name.');
    }
    return trimmed;
  }

  static int _readHeaderInt(String? value, String name) {
    final text = _readHeaderText(value, name);
    final result = int.tryParse(text);
    if (result == null || result < 0) {
      throw FormatException('Invalid upload header: $name.');
    }
    return result;
  }

  static bool _readHeaderBool(String? value, String name) {
    final text = _readHeaderText(value, name);
    if (text == 'true') return true;
    if (text == 'false') return false;
    throw FormatException('Invalid upload header: $name.');
  }
}

class UnsupportedEncryption implements Exception {
  const UnsupportedEncryption();

  @override
  String toString() => 'These encryption settings are not supported.';
}
