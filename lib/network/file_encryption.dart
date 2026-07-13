import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const String noEncryption = 'none';
const String fileEncryption = 'chacha20-poly1305-chunked';
const int encryptionBlockSize = 1024 * 1024;
const int encryptionTagSize = 16;

class TransferDetails {
  final Uint8List senderPublicKey;
  final Uint8List receiverPublicKey;
  final String senderId;
  final String senderName;
  final String senderDeviceType;
  final String requestId;
  final String fileName;
  final int fileSize;
  final bool isFolder;
  final String contentEncryption;
  final int encryptionChunkSize;

  const TransferDetails({
    required this.senderPublicKey,
    required this.receiverPublicKey,
    required this.senderId,
    required this.senderName,
    required this.senderDeviceType,
    required this.requestId,
    required this.fileName,
    required this.fileSize,
    required this.isFolder,
    required this.contentEncryption,
    required this.encryptionChunkSize,
  });

  bool get encrypted => contentEncryption == fileEncryption;

  void validate() {
    if (senderPublicKey.length != 32 || receiverPublicKey.length != 32) {
      throw const FormatException('Invalid transfer public key.');
    }
    if (fileSize < 0 || fileSize > 0x7FFFFFFFFFFFFFFF) {
      throw const FormatException('Invalid transfer file size.');
    }
    if (contentEncryption == noEncryption) {
      if (encryptionChunkSize != 0) {
        throw const FormatException('Invalid plaintext chunk size.');
      }
      return;
    }
    if (contentEncryption != fileEncryption ||
        encryptionChunkSize != encryptionBlockSize) {
      throw const FormatException('Unsupported content encryption.');
    }
    encryptedBlockCount(fileSize);
  }

  Uint8List makeBytes() {
    validate();
    final output = BytesBuilder(copy: false);
    _writeText(output, 'quickdrop-transfer');
    _writeBytes(output, senderPublicKey);
    _writeBytes(output, receiverPublicKey);
    _writeText(output, senderId);
    _writeText(output, senderName);
    _writeText(output, senderDeviceType);
    _writeText(output, requestId);
    _writeText(output, fileName);
    _writeUint64(output, fileSize);
    output.addByte(isFolder ? 1 : 0);
    _writeText(output, contentEncryption);
    _writeUint32(output, encryptionChunkSize);
    return output.takeBytes();
  }
}

class TransferKeys {
  final Uint8List transferHash;
  final String uploadToken;
  final String code;
  final SecretKey fileKey;
  final Uint8List nonceStart;

  const TransferKeys({
    required this.transferHash,
    required this.uploadToken,
    required this.code,
    required this.fileKey,
    required this.nonceStart,
  });

  static Future<TransferKeys> create({
    required SecretKey sharedKey,
    required TransferDetails details,
  }) async {
    final transferBytes = details.makeBytes();
    final transferHash = Uint8List.fromList(
      (await Sha256().hash(transferBytes)).bytes,
    );
    final uploadBytes = await _makeKeyBytes(
      sharedKey,
      transferHash,
      'upload-token',
      32,
    );
    final codeBytes = await _makeKeyBytes(
      sharedKey,
      transferHash,
      'comparison-code',
      32,
    );
    final fileKeyBytes = await _makeKeyBytes(
      sharedKey,
      transferHash,
      'payload-key',
      32,
    );
    final nonceStart = await _makeKeyBytes(
      sharedKey,
      transferHash,
      'payload-nonce-prefix',
      8,
    );
    final number =
        ByteData.sublistView(codeBytes).getUint32(0, Endian.big) % 1000000;
    return TransferKeys(
      transferHash: transferHash,
      uploadToken: base64Encode(uploadBytes),
      code: number.toString().padLeft(6, '0'),
      fileKey: SecretKey(fileKeyBytes),
      nonceStart: nonceStart,
    );
  }

  static Future<Uint8List> _makeKeyBytes(
    SecretKey sharedKey,
    Uint8List transferHash,
    String name,
    int length,
  ) async {
    final info = BytesBuilder(copy: false)
      ..add(utf8.encode(name))
      ..addByte(0)
      ..add(transferHash);
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: length).deriveKey(
      secretKey: sharedKey,
      nonce: utf8.encode('quickdrop-transfer'),
      info: info.takeBytes(),
    );
    return Uint8List.fromList(await key.extractBytes());
  }
}

class FileEncryption {
  final TransferDetails details;
  final TransferKeys keys;
  final Chacha20 _cipher;

  FileEncryption({required this.details, required this.keys, Chacha20? cipher})
    : _cipher = cipher ?? Chacha20.poly1305Aead() {
    if (!details.encrypted) {
      throw ArgumentError('File encryption needs encrypted transfer details.');
    }
    details.validate();
  }

  int get size => encryptedSize(details.fileSize);

  Stream<List<int>> encrypt(
    Stream<List<int>> source, {
    void Function(int bytes)? onPlaintext,
    void Function()? checkCancelled,
  }) async* {
    final reader = _ChunkReader(source);
    final blockCount = encryptedBlockCount(details.fileSize);
    var remaining = details.fileSize;
    for (var index = 0; index < blockCount; index++) {
      checkCancelled?.call();
      final plainLength = _blockSize(remaining);
      final clearText = await reader.read(plainLength);
      final box = await _cipher.encrypt(
        clearText,
        secretKey: keys.fileKey,
        nonce: _nonce(index),
        aad: _checkData(index, plainLength),
      );
      checkCancelled?.call();
      final output = Uint8List(plainLength + encryptionTagSize)
        ..setRange(0, plainLength, box.cipherText)
        ..setRange(plainLength, plainLength + encryptionTagSize, box.mac.bytes);
      onPlaintext?.call(plainLength);
      yield output;
      remaining -= plainLength;
    }
    await reader.checkFinished();
  }

  Stream<List<int>> decrypt(
    Stream<List<int>> source, {
    void Function(int bytes)? onPlaintext,
    void Function()? checkCancelled,
  }) async* {
    final reader = _ChunkReader(source);
    final blockCount = encryptedBlockCount(details.fileSize);
    var remaining = details.fileSize;
    for (var index = 0; index < blockCount; index++) {
      checkCancelled?.call();
      final plainLength = _blockSize(remaining);
      final block = await reader.read(plainLength + encryptionTagSize);
      final box = SecretBox(
        block.sublist(0, plainLength),
        nonce: _nonce(index),
        mac: Mac(block.sublist(plainLength)),
      );
      final clearText = await _cipher.decrypt(
        box,
        secretKey: keys.fileKey,
        aad: _checkData(index, plainLength),
      );
      if (clearText.length != plainLength) {
        throw const FileStreamException('Invalid decrypted block size.');
      }
      checkCancelled?.call();
      onPlaintext?.call(plainLength);
      yield clearText;
      remaining -= plainLength;
    }
    await reader.checkFinished();
  }

  Uint8List _nonce(int index) {
    if (index < 0 || index > 0xFFFFFFFF) {
      throw const FileStreamException('Too many encrypted blocks.');
    }
    final result = Uint8List(12)..setRange(0, 8, keys.nonceStart);
    ByteData.sublistView(result).setUint32(8, index, Endian.big);
    return result;
  }

  int _blockSize(int remaining) {
    if (details.fileSize == 0) return 0;
    if (remaining < encryptionBlockSize) return remaining;
    return encryptionBlockSize;
  }

  Uint8List _checkData(int index, int plainLength) {
    final result = Uint8List(keys.transferHash.length + 8)
      ..setRange(0, keys.transferHash.length, keys.transferHash);
    final data = ByteData.sublistView(result);
    data.setUint32(keys.transferHash.length, index, Endian.big);
    data.setUint32(keys.transferHash.length + 4, plainLength, Endian.big);
    return result;
  }
}

int encryptedBlockCount(int plainSize) {
  if (plainSize < 0) {
    throw const FormatException('Invalid transfer file size.');
  }
  final count = plainSize == 0
      ? 1
      : 1 + ((plainSize - 1) ~/ encryptionBlockSize);
  if (count > 0x100000000) {
    throw const FormatException('The file is too large to encrypt.');
  }
  return count;
}

int encryptedSize(int plainSize) {
  final count = encryptedBlockCount(plainSize);
  final result = plainSize + count * encryptionTagSize;
  if (result > 0x7FFFFFFFFFFFFFFF) {
    throw const FormatException('Encrypted transfer size is too large.');
  }
  return result;
}

bool secureTextMatch(String first, String second) {
  final length = first.length > second.length ? first.length : second.length;
  var difference = first.length ^ second.length;
  for (var index = 0; index < length; index++) {
    final left = index < first.length ? first.codeUnitAt(index) : 0;
    final right = index < second.length ? second.codeUnitAt(index) : 0;
    difference |= left ^ right;
  }
  return difference == 0;
}

class FileStreamException implements Exception {
  final String message;

  const FileStreamException(this.message);

  @override
  String toString() => message;
}

class _ChunkReader {
  final StreamIterator<List<int>> _iterator;
  Uint8List? _chunk;
  int _offset = 0;
  bool _done = false;

  _ChunkReader(Stream<List<int>> stream)
    : _iterator = StreamIterator<List<int>>(stream);

  Future<Uint8List> read(int length) async {
    if (length < 0) throw ArgumentError.value(length, 'length');
    if (length == 0) return Uint8List(0);
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      if (!await _loadChunk()) {
        throw const FileStreamException('File stream ended early.');
      }
      final chunk = _chunk!;
      final available = chunk.length - _offset;
      final take = available < length - written ? available : length - written;
      result.setRange(written, written + take, chunk, _offset);
      written += take;
      _offset += take;
    }
    return result;
  }

  Future<void> checkFinished() async {
    if (await _loadChunk()) {
      throw const FileStreamException('File stream has trailing data.');
    }
    await _iterator.cancel();
  }

  Future<bool> _loadChunk() async {
    while (!_done && (_chunk == null || _offset >= _chunk!.length)) {
      if (!await _iterator.moveNext()) {
        _done = true;
        _chunk = null;
        return false;
      }
      _chunk = Uint8List.fromList(_iterator.current);
      _offset = 0;
    }
    return !_done && _chunk != null && _offset < _chunk!.length;
  }
}

void _writeText(BytesBuilder output, String value) =>
    _writeBytes(output, utf8.encode(value));

void _writeBytes(BytesBuilder output, List<int> value) {
  _writeUint32(output, value.length);
  output.add(value);
}

void _writeUint32(BytesBuilder output, int value) {
  if (value < 0 || value > 0xFFFFFFFF) {
    throw const FormatException('Transfer value is outside uint32 range.');
  }
  final bytes = Uint8List(4);
  ByteData.sublistView(bytes).setUint32(0, value, Endian.big);
  output.add(bytes);
}

void _writeUint64(BytesBuilder output, int value) {
  if (value < 0 || value > 0x7FFFFFFFFFFFFFFF) {
    throw const FormatException('Transfer value is outside uint64 range.');
  }
  final bytes = Uint8List(8);
  ByteData.sublistView(bytes).setUint64(0, value, Endian.big);
  output.add(bytes);
}
