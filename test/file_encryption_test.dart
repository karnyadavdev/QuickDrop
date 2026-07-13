import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickdrop/network/file_encryption.dart';
import 'package:quickdrop/network/transfer_request.dart';

void main() {
  group('transfer keys', () {
    test('matches the fixed first-release vector', () async {
      final details = _details(fileSize: 15);
      final keys = await _keys(details);
      final encrypted = await FileEncryption(
        details: details,
        keys: keys,
      ).encrypt(Stream.value(utf8.encode('hello quickdrop'))).single;

      expect(
        _hex(details.makeBytes()),
        '00000012717569636b64726f702d7472616e7366657200000020000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f00000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f0000000973656e6465722d69640000000653656e646572000000076465736b746f700000000a726571756573742d69640000000968656c6c6f2e747874000000000000000f000000001963686163686132302d706f6c79313330352d6368756e6b656400100000',
      );
      expect(
        _hex(keys.transferHash),
        '6ebdb6f764088e6efe7243b972bfa1ae0312b5be41a669665306a3078eccda7f',
      );
      expect(keys.uploadToken, '22aSjUBKP9Or0O7BWtA+kBGJFVUnxvtfcCUZ3kuZVC8=');
      expect(keys.code, '019439');
      expect(
        _hex(await keys.fileKey.extractBytes()),
        '344f28ce6ba2b4dbeb8835b8f957d8172bb7b31f3962bc31efbc1811a5c4d9c2',
      );
      expect(_hex(keys.nonceStart), 'a8af9a8a23527632');
      expect(
        _hex(encrypted),
        '100f55ff3aeec8fdb49d6a1724538fc6b1baffc88ad8519ebb8ac4e556fed9',
      );
    });

    test('encryption setting changes the code and token', () async {
      final encrypted = _details(fileSize: 15);
      final plain = _details(
        fileSize: 15,
        contentEncryption: noEncryption,
        chunkSize: 0,
      );
      final encryptedKeys = await _keys(encrypted);
      final plainKeys = await _keys(plain);

      expect(plainKeys.code, isNot(encryptedKeys.code));
      expect(plainKeys.uploadToken, isNot(encryptedKeys.uploadToken));
    });
  });

  group('chunked ChaCha20-Poly1305', () {
    test('round trips arbitrary source and network boundaries', () async {
      final clearText = Uint8List.fromList(
        List.generate(encryptionBlockSize * 2 + 17, (index) => index & 0xff),
      );
      final details = _details(fileSize: clearText.length);
      final keys = await _keys(details);
      final encryption = FileEncryption(details: details, keys: keys);

      final wire = await _collect(
        encryption.encrypt(_split(clearText, const [1, 7, 65537, 3, 900000])),
      );
      expect(wire.length, encryptedSize(clearText.length));

      final restored = await _collect(
        encryption.decrypt(_split(wire, const [3, 1000, 17, 131071, 2])),
      );
      expect(restored, clearText);
    });

    test('authenticates a zero-byte file with one tag', () async {
      final details = _details(fileSize: 0);
      final keys = await _keys(details);
      final encryption = FileEncryption(details: details, keys: keys);
      final wire = await _collect(encryption.encrypt(const Stream.empty()));

      expect(wire.length, encryptionTagSize);
      expect(await _collect(encryption.decrypt(Stream.value(wire))), isEmpty);
    });

    test('rejects modified, truncated, and trailing ciphertext', () async {
      final clearText = Uint8List.fromList(utf8.encode('hello quickdrop'));
      final details = _details(fileSize: clearText.length);
      final keys = await _keys(details);
      final encryption = FileEncryption(details: details, keys: keys);
      final wire = await _collect(encryption.encrypt(Stream.value(clearText)));

      final modified = Uint8List.fromList(wire)..[0] ^= 1;
      await expectLater(
        encryption.decrypt(Stream.value(modified)).drain<void>(),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      await expectLater(
        encryption
            .decrypt(Stream.value(wire.sublist(0, wire.length - 1)))
            .drain<void>(),
        throwsA(isA<FileStreamException>()),
      );
      await expectLater(
        encryption.decrypt(Stream.value([...wire, 0])).drain<void>(),
        throwsA(isA<FileStreamException>()),
      );
    });

    test('size math covers frame boundaries without allocating files', () {
      expect(encryptedBlockCount(0), 1);
      expect(encryptedBlockCount(encryptionBlockSize - 1), 1);
      expect(encryptedBlockCount(encryptionBlockSize), 1);
      expect(encryptedBlockCount(encryptionBlockSize + 1), 2);
      expect(
        encryptedSize(3 * 1024 * 1024 * 1024),
        3 * 1024 * 1024 * 1024 + 3072 * encryptionTagSize,
      );
    });
  });

  group('request parsing', () {
    test('requires supported encryption fields', () {
      final request = TransferRequest.fromJson(_requestJson());
      expect(request.contentEncryption, fileEncryption);

      final unknownSuite = _requestJson()..['contentEncryption'] = 'unknown';
      expect(
        () => TransferRequest.fromJson(unknownSuite),
        throwsA(isA<UnsupportedEncryption>()),
      );
    });

    test('accepts a Linux sender', () {
      final linuxRequest = _requestJson()..['deviceType'] = 'linux';
      final request = TransferRequest.fromJson(linuxRequest);
      expect(request.senderDeviceType, 'linux');
    });

    test('upload repeats the encryption settings', () {
      final upload = UploadInfo.fromHeaders(
        encodedFileName: Uri.encodeComponent('hello.txt'),
        fileSize: '15',
        isFolder: 'false',
        senderId: 'sender-id',
        requestId: 'request-id',
        contentEncryption: fileEncryption,
        encryptionChunkSize: '$encryptionBlockSize',
      );
      expect(upload.contentEncryption, fileEncryption);
      expect(
        () => UploadInfo.fromHeaders(
          encodedFileName: Uri.encodeComponent('hello.txt'),
          fileSize: '15',
          isFolder: 'false',
          senderId: 'sender-id',
          requestId: 'request-id',
          contentEncryption: noEncryption,
          encryptionChunkSize: '$encryptionBlockSize',
        ),
        throwsA(isA<UnsupportedEncryption>()),
      );
    });
  });
}

TransferDetails _details({
  required int fileSize,
  String contentEncryption = fileEncryption,
  int chunkSize = encryptionBlockSize,
}) {
  return TransferDetails(
    senderPublicKey: Uint8List.fromList(List.generate(32, (i) => i)),
    receiverPublicKey: Uint8List.fromList(List.generate(32, (i) => i + 32)),
    senderId: 'sender-id',
    senderName: 'Sender',
    senderDeviceType: 'desktop',
    requestId: 'request-id',
    fileName: 'hello.txt',
    fileSize: fileSize,
    isFolder: false,
    contentEncryption: contentEncryption,
    encryptionChunkSize: chunkSize,
  );
}

Future<TransferKeys> _keys(TransferDetails details) {
  return TransferKeys.create(
    sharedKey: SecretKey(List.generate(32, (i) => 255 - i)),
    details: details,
  );
}

Map<String, dynamic> _requestJson() => {
  'id': 'sender-id',
  'requestId': 'request-id',
  'name': 'Sender',
  'deviceType': 'desktop',
  'fileName': 'hello.txt',
  'fileSize': 15,
  'isFolder': false,
  'publicKey': base64Encode(List.generate(32, (i) => i)),
  'contentEncryption': fileEncryption,
  'encryptionChunkSize': encryptionBlockSize,
};

Stream<List<int>> _split(Uint8List bytes, List<int> sizes) async* {
  var offset = 0;
  var index = 0;
  while (offset < bytes.length) {
    final size = sizes[index % sizes.length];
    final end = offset + size < bytes.length ? offset + size : bytes.length;
    yield bytes.sublist(offset, end);
    offset = end;
    index++;
  }
}

Future<Uint8List> _collect(Stream<List<int>> stream) async {
  final output = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    output.add(chunk);
  }
  return output.takeBytes();
}

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
