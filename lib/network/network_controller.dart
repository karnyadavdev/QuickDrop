import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/device.dart';
import 'file_encryption.dart';
import 'folder_packer.dart';
import 'request_body.dart';
import 'safe_file_name.dart';
import 'transfer_request.dart';

const _nativeChannel = MethodChannel('com.karnyadavdev.quickdrop/native');

class AndroidFolder {
  final String uri;
  final String name;

  const AndroidFolder(this.uri, this.name);
}

class AndroidFile {
  final String uri;
  final String name;
  final int size;

  const AndroidFile({
    required this.uri,
    required this.name,
    required this.size,
  });
}

class PackResult {
  final int files;
  final int directories;
  final int bytes;

  const PackResult({
    required this.files,
    required this.directories,
    required this.bytes,
  });

  factory PackResult.fromMap(Map<dynamic, dynamic>? map) {
    final files = map?['files'];
    final directories = map?['directories'];
    final bytes = map?['bytes'];
    if (files is! int || directories is! int || bytes is! int) {
      throw const FormatException('The package result was incomplete.');
    }
    if (files < 0 || directories < 0 || bytes < 0) {
      throw const FormatException('The package result was invalid.');
    }
    return PackResult(files: files, directories: directories, bytes: bytes);
  }
}

class _FileToSend {
  final String name;
  final int size;
  final Stream<List<int>> Function() openRead;
  final File? tempFile;

  const _FileToSend({
    required this.name,
    required this.size,
    required this.openRead,
    this.tempFile,
  });
}

class NetworkController extends ChangeNotifier {
  final String deviceId;
  String deviceName;
  String deviceType;
  bool encryptOutgoing;

  final List<NetworkDevice> _devices = [];
  List<NetworkDevice> get devices => List.unmodifiable(_devices);

  double _transferProgress = 0.0;
  double get transferProgress => _transferProgress;

  String _transferSpeed = '0 KB/s';
  String get transferSpeed => _transferSpeed;

  String _transferFileName = '';
  String get transferFileName => _transferFileName;

  int _transferFileSize = 0;
  int get transferFileSize => _transferFileSize;

  String _transferType = 'none';
  String get transferType => _transferType;
  bool get _showingFinishedTransfer =>
      _transferType == 'send_finished' || _transferType == 'receive_finished';

  bool _transferIsFolder = false;
  bool get transferIsFolder => _transferIsFolder;

  bool _isEncrypted = false;
  bool get isEncrypted => _isEncrypted;

  String _transferSenderName = '';
  String get transferSenderName => _transferSenderName;

  String _transferSenderDeviceType = 'desktop';
  String get transferSenderDeviceType => _transferSenderDeviceType;

  String _transferCode = '';
  String get transferCode => _transferCode;

  NetworkDevice? get pendingSendDevice => _pendingSendDevice;
  String get transferPeerName => (_transferType.startsWith('send'))
      ? _pendingSendDevice?.name ?? ''
      : _transferSenderName;
  String get transferPeerDeviceType => (_transferType.startsWith('send'))
      ? _pendingSendDevice?.deviceType ?? 'desktop'
      : _transferSenderDeviceType;

  bool get canDismiss => _canDismiss;

  bool _hasLocalNetwork = false;
  bool get hasLocalNetwork => _hasLocalNetwork;

  String _requestAnswer = 'pending';
  bool _canDismiss = false;

  SimpleKeyPair? _senderKeyPair;
  SimpleKeyPair? _receiverKeyPair;
  String? _uploadToken;
  TransferDetails? _transferDetails;
  TransferKeys? _transferKeys;

  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;
  Timer? _broadcastTimer;
  Timer? _pruneTimer;
  Timer? _receiveWaitTimer;
  Timer? _ipRefreshTimer;
  Timer? _samePcScanTimer;
  HttpClient? _activeUploadClient;
  HttpClient? _requestClient;
  HttpRequest? _incomingUpload;
  Process? _activePackProcess;
  File? _activePackFile;
  Future<PackResult>? _activePackFuture;
  bool _cancelingPack = false;
  int? _openFileId;
  int? _packCancelVersion;
  int _localHttpPort = 50005;
  int _activeConnectionCount = 0;
  int _udpRetryCount = 0;
  bool _transferServiceRunning = false;

  static const int udpPort = 55555;
  static const int _maxDiscoverablePeers = 64;
  static const int _maxRequestBytes = 16 * 1024;
  static const Duration _statusEvery = Duration(seconds: 1);
  static const Duration _cleanupEvery = Duration(seconds: 1);
  static const Duration _deviceTimeout = Duration(seconds: 4);
  static const Duration _receiveTimeout = Duration(minutes: 3);
  static const Duration _sendTimeout = Duration(seconds: 30);
  static const Duration _stallTimeout = Duration(seconds: 15);
  static const Duration _answerTimeout = Duration(minutes: 2);
  static const bool allowSamePcDiscovery = kDebugMode;
  bool _isDisposed = false;
  bool _readingRequest = false;

  Completer<bool>? _answerWaiter;
  Completer<void>? _codeCheck;
  Timer? _codeTimer;
  NetworkDevice? _pendingSendDevice;
  _FileToSend? _fileToSend;
  String? _expectedFileName;
  int? _expectedFileSize;
  bool? _expectedFolder;
  String? _expectedSenderId;
  String? _expectedSenderIp;
  String? _activeRequestId;
  String? _expectedRequestId;
  String? _expectedEncryption;
  int? _expectedChunkSize;
  String? _pendingRequestId;

  final List<String> _localIps = [];
  int _transferStateVersion = 0;

  NetworkController({
    required this.deviceId,
    required this.deviceName,
    this.deviceType = 'desktop',
    this.encryptOutgoing = false,
  }) {
    if (Platform.isAndroid) {
      _nativeChannel.setMethodCallHandler(_handleNativeCall);
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'cancelTransfer') {
      cancelActiveTransfer();
    }
  }

  Future<void> start() async {
    await _loadStoredProfile();
    if (_isDisposed) return;
    await _cleanOldPackages();
    if (_isDisposed) return;
    await _resolveLocalIps();
    if (_isDisposed) return;
    await _enableAndroidMulticastReception();
    if (_isDisposed) return;
    await _startHttpServer();
    if (_isDisposed) return;
    await _startUdpDiscovery();
    if (_isDisposed) return;
    _startTimers();
  }

  Future<void> _enableAndroidMulticastReception() async {
    if (!Platform.isAndroid) return;
    try {
      await _nativeChannel.invokeMethod<void>('acquireMulticastLock');
    } catch (_) {
      // Discovery can still work without this on some phones.
    }
  }

  Future<AndroidFolder?> pickAndroidFolder() async {
    if (!Platform.isAndroid) return null;
    final value = await _nativeChannel.invokeMapMethod<String, dynamic>(
      'pickFolder',
    );
    final uri = value?['uri'];
    final name = value?['name'];
    if (uri is! String || uri.isEmpty) return null;
    return AndroidFolder(
      uri,
      name is String && name.isNotEmpty ? name : 'Folder',
    );
  }

  Future<List<AndroidFile>?> pickAndroidFiles() async {
    if (!Platform.isAndroid) return null;
    final raw = await _nativeChannel.invokeListMethod<dynamic>('pickFiles');
    if (raw == null) return null;
    final files = <AndroidFile>[];
    for (final item in raw) {
      if (item is! Map) {
        throw const FormatException(
          'The Android picker returned invalid data.',
        );
      }
      final uri = item['uri'];
      final name = item['name'];
      final size = item['size'];
      if (uri is! String ||
          uri.isEmpty ||
          name is! String ||
          name.isEmpty ||
          size is! int ||
          size < 0) {
        throw const FormatException(
          'The Android picker returned invalid metadata.',
        );
      }
      files.add(AndroidFile(uri: uri, name: name, size: size));
    }
    return files;
  }

  Future<void> _loadStoredProfile() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final file = File(p.join(docDir.path, 'quickdrop_profile.json'));
      if (await file.exists()) {
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final storedDeviceId = data['deviceId'];
        if (storedDeviceId is String && storedDeviceId != deviceId) return;
        final storedName = data['name'];
        if (storedName is String) {
          deviceName = _sanitizeDeviceName(storedName);
        }
        final storedDeviceType = data['deviceType'];
        if (storedDeviceType is String) {
          deviceType = storedDeviceType;
        }
        encryptOutgoing = data['encryptOutgoing'] == true;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> updateProfile({
    required String name,
    required String deviceType,
    required bool encryptOutgoing,
  }) async {
    deviceName = _sanitizeDeviceName(name);
    this.deviceType = deviceType;
    this.encryptOutgoing = encryptOutgoing;
    notifyListeners();
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final file = File(p.join(docDir.path, 'quickdrop_profile.json'));
      await file.writeAsString(
        jsonEncode({
          'deviceId': deviceId,
          'name': deviceName,
          'deviceType': this.deviceType,
          'encryptOutgoing': this.encryptOutgoing,
        }),
      );
    } catch (_) {}
  }

  final Map<String, int> _ipPrefixes = {};
  final Map<String, String> _ipBroadcasts = {};

  Future<void> _updatePrefixesAndBroadcasts() async {
    try {
      _ipPrefixes.clear();
      _ipBroadcasts.clear();
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          'Get-NetIPAddress -AddressFamily IPv4 | Format-List IPAddress,PrefixLength',
        ]);
        if (result.exitCode == 0) {
          final lines = result.stdout.toString().split('\n');
          String? currentIp;
          for (var line in lines) {
            line = line.trim();
            final lowerLine = line.toLowerCase();
            if (lowerLine.startsWith('ipaddress')) {
              final colonIndex = line.indexOf(':');
              if (colonIndex != -1) {
                currentIp = line.substring(colonIndex + 1).trim();
              }
            } else if (lowerLine.startsWith('prefixlength') &&
                currentIp != null) {
              final colonIndex = line.indexOf(':');
              if (colonIndex != -1) {
                final prefixStr = line.substring(colonIndex + 1).trim();
                final prefix = int.tryParse(prefixStr);
                if (prefix != null) {
                  _ipPrefixes[currentIp] = prefix;
                }
              }
              currentIp = null;
            }
          }
        }
      } else if (Platform.isAndroid) {
        final raw = await _nativeChannel.invokeMethod<dynamic>(
          'getNetworkPrefixes',
        );
        if (raw is Map) {
          raw.forEach((key, value) {
            if (key is String && value is int && value >= 0 && value <= 32) {
              _ipPrefixes[key] = value;
            }
          });
        }
      } else if (Platform.isLinux || Platform.isMacOS) {
        try {
          final result = await Process.run('ip', ['-o', '-4', 'addr', 'show']);
          if (result.exitCode == 0) {
            final lines = result.stdout.toString().split('\n');
            for (var line in lines) {
              final parts = line.trim().split(RegExp(r'\s+'));
              final inetIndex = parts.indexOf('inet');
              if (inetIndex != -1 && inetIndex + 1 < parts.length) {
                final ipSlashPrefix = parts[inetIndex + 1];
                final ipParts = ipSlashPrefix.split('/');
                if (ipParts.length == 2) {
                  final ip = ipParts[0];
                  final prefix = int.tryParse(ipParts[1]);
                  if (prefix != null) {
                    _ipPrefixes[ip] = prefix;
                  }
                }
              }
            }
          }
        } catch (_) {}

        try {
          final result = await Process.run('ifconfig', []);
          if (result.exitCode == 0) {
            final lines = result.stdout.toString().split('\n');
            for (var line in lines) {
              final parts = line.trim().split(RegExp(r'\s+'));
              final inetIndex = parts.indexOf('inet');
              final broadcastIndex = parts.indexOf('broadcast');
              if (inetIndex != -1 &&
                  inetIndex + 1 < parts.length &&
                  broadcastIndex != -1 &&
                  broadcastIndex + 1 < parts.length) {
                final ip = parts[inetIndex + 1];
                final broadcast = parts[broadcastIndex + 1];
                _ipBroadcasts[ip] = broadcast;
              }
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  String? _getBroadcastIp(String ipStr, int prefixLength) {
    try {
      final parts = ipStr.split('.');
      if (parts.length != 4) return null;
      final ipBytes = parts.map(int.parse).toList();
      if (prefixLength < 0 || prefixLength > 32) return null;
      int ipInt =
          (ipBytes[0] << 24) |
          (ipBytes[1] << 16) |
          (ipBytes[2] << 8) |
          ipBytes[3];
      int mask = prefixLength == 0 ? 0 : (~0 << (32 - prefixLength));
      int wildcard = ~mask;
      int broadcastInt = ipInt | wildcard;
      int b1 = (broadcastInt >> 24) & 0xFF;
      int b2 = (broadcastInt >> 16) & 0xFF;
      int b3 = (broadcastInt >> 8) & 0xFF;
      int b4 = broadcastInt & 0xFF;
      return '$b1.$b2.$b3.$b4';
    } catch (_) {
      return null;
    }
  }

  String? _computeBroadcastIp(String ip) {
    if (_ipBroadcasts.containsKey(ip)) {
      return _ipBroadcasts[ip]!;
    }
    if (_ipPrefixes.containsKey(ip)) {
      final prefix = _ipPrefixes[ip]!;
      final calculated = _getBroadcastIp(ip, prefix);
      if (calculated != null) {
        return calculated;
      }
    }
    // Global broadcast is enough if the network mask is unknown.
    return null;
  }

  Future<void> _resolveLocalIps() async {
    try {
      _localIps.clear();
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              !addr.isLoopback &&
              !addr.isLinkLocal) {
            _localIps.add(addr.address);
          }
        }
      }
      await _updatePrefixesAndBroadcasts();
      final connected = Platform.isAndroid
          ? _ipPrefixes.isNotEmpty
          : _localIps.any(_isPrivateOrLocalIp);
      if (_hasLocalNetwork != connected) {
        _hasLocalNetwork = connected;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> _startHttpServer() async {
    int portAttempt = 50005;
    while (_httpServer == null && portAttempt <= 50050) {
      try {
        _httpServer = await HttpServer.bind(
          InternetAddress.anyIPv6,
          portAttempt,
          v6Only: false,
        );
        _localHttpPort = portAttempt;
      } catch (_) {
        try {
          _httpServer = await HttpServer.bind(
            InternetAddress.anyIPv4,
            portAttempt,
          );
          _localHttpPort = portAttempt;
        } catch (_) {
          portAttempt++;
        }
      }
    }

    if (_httpServer == null) {
      throw Exception('Could not bind HTTP server to any port in range.');
    }

    if (_isDisposed) {
      await _httpServer!.close(force: true);
      _httpServer = null;
      return;
    }

    _httpServer!.idleTimeout = const Duration(seconds: 30);
    _httpServer!.listen(
      _handleHttpRequest,
      onError: (e) {
        if (kDebugMode) debugPrint('HTTP Server error: $e');
      },
    );
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    if (_activeConnectionCount >= 10) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    _activeConnectionCount++;
    try {
      await _handleHttpRequestInner(request);
    } finally {
      _activeConnectionCount--;
    }
  }

  Future<void> _handleHttpRequestInner(HttpRequest request) async {
    final response = request.response;

    if (request.method == 'GET' && request.uri.path == '/ping') {
      await _sendJson(response, HttpStatus.ok, _presenceJson());
      return;
    }

    if (request.method == 'GET' && request.uri.path == '/request_status') {
      final requestId = request.uri.queryParameters['requestId'];
      final remoteIp = request.connectionInfo?.remoteAddress.address;
      if (_activeRequestId != requestId ||
          (_expectedSenderIp != null && remoteIp != _expectedSenderIp)) {
        await _sendJson(response, HttpStatus.notFound, {'status': 'not_found'});
        return;
      }
      await _sendJson(response, HttpStatus.ok, {'status': _requestAnswer});
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/cancel_request') {
      Object? decoded;
      try {
        decoded = jsonDecode(
          await RequestBody.readUtf8(request, maxBytes: 1024),
        );
      } on RequestTooLarge {
        await _sendJson(response, HttpStatus.requestEntityTooLarge, {
          'status': 'too_large',
        });
        return;
      } catch (_) {
        await _sendJson(response, HttpStatus.badRequest, {
          'status': 'invalid_request',
        });
        return;
      }
      if (decoded is! Map<String, dynamic>) {
        await _sendJson(response, HttpStatus.badRequest, {
          'status': 'invalid_request',
        });
        return;
      }
      final requestId = decoded['requestId'];
      if (requestId is! String || requestId.trim().isEmpty) {
        await _sendJson(response, HttpStatus.badRequest, {
          'status': 'invalid_request',
        });
        return;
      }
      final remoteIp = request.connectionInfo?.remoteAddress.address;
      final matches =
          requestId == _activeRequestId &&
          (_expectedSenderIp == null || remoteIp == _expectedSenderIp);
      if (!matches) {
        await _sendJson(response, HttpStatus.notFound, {'status': 'not_found'});
        return;
      }
      _resetTransferState();
      _sendStatus();
      await _sendJson(response, HttpStatus.ok, {'status': 'cancelled'});
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/request') {
      // A finished screen can stay visible, but this device is ready again.
      if (_showingFinishedTransfer) {
        _resetTransferState();
      }
      if (_transferType != 'none' || _readingRequest) {
        await _sendJson(response, HttpStatus.serviceUnavailable, {
          'status': 'busy',
        });
        return;
      }

      _readingRequest = true;

      try {
        if (request.contentLength > _maxRequestBytes) {
          _readingRequest = false;
          await _sendJson(response, HttpStatus.requestEntityTooLarge, {
            'status': 'too_large',
          });
          return;
        }

        final bodyStr = await RequestBody.readUtf8(
          request,
          maxBytes: _maxRequestBytes,
        );
        final decoded = jsonDecode(bodyStr);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Transfer request must be an object.');
        }
        final json = decoded;
        final transferRequest = TransferRequest.fromJson(json);
        final senderIp = request.connectionInfo?.remoteAddress.address;

        final fileName = SafeFileName.clean(
          transferRequest.fileName,
          isFolder: transferRequest.isFolder,
        );

        final algorithm = X25519();
        _receiverKeyPair = await algorithm.newKeyPair();
        final receiverKey = await _receiverKeyPair!.extractPublicKey();
        final receiverKeyText = base64Encode(receiverKey.bytes);
        final senderKey = SimplePublicKey(
          transferRequest.publicKeyBytes,
          type: KeyPairType.x25519,
        );
        final sharedKey = await algorithm.sharedSecretKey(
          keyPair: _receiverKeyPair!,
          remotePublicKey: senderKey,
        );
        final details = TransferDetails(
          senderPublicKey: transferRequest.publicKeyBytes,
          receiverPublicKey: Uint8List.fromList(receiverKey.bytes),
          senderId: transferRequest.senderId,
          senderName: transferRequest.senderName,
          senderDeviceType: transferRequest.senderDeviceType,
          requestId: transferRequest.requestId,
          fileName: fileName,
          fileSize: transferRequest.fileSize,
          isFolder: transferRequest.isFolder,
          contentEncryption: transferRequest.contentEncryption,
          encryptionChunkSize: transferRequest.encryptionChunkSize,
        );
        final keys = await TransferKeys.create(
          sharedKey: sharedKey,
          details: details,
        );
        _transferDetails = details;
        _transferKeys = keys;
        _uploadToken = keys.uploadToken;
        _transferCode = keys.code;
        if (_isDisposed) return;

        _beginTransferState();
        _transferType = 'incoming_request';
        _transferFileName = fileName;
        _transferFileSize = transferRequest.fileSize;
        _transferIsFolder = transferRequest.isFolder;
        _isEncrypted = details.encrypted;
        _transferSenderName = transferRequest.senderName;
        _transferSenderDeviceType = transferRequest.senderDeviceType;
        _expectedFileName = fileName;
        _expectedFileSize = transferRequest.fileSize;
        _expectedFolder = transferRequest.isFolder;
        _expectedSenderId = transferRequest.senderId;
        _expectedSenderIp = senderIp;
        _expectedRequestId = transferRequest.requestId;
        _expectedEncryption = transferRequest.contentEncryption;
        _expectedChunkSize = transferRequest.encryptionChunkSize;
        _activeRequestId = transferRequest.requestId;
        _transferProgress = 0.0;
        _transferSpeed = 'Waiting...';
        _answerWaiter = Completer<bool>();
        _requestAnswer = 'pending';
        _readingRequest = false;
        notifyListeners();

        await _sendJson(response, HttpStatus.accepted, {
          'status': 'pending',
          'publicKey': receiverKeyText,
          'contentEncryption': transferRequest.contentEncryption,
          'encryptionChunkSize': transferRequest.encryptionChunkSize,
        });

        final requestVersion = _transferStateVersion;
        _waitForAnswer(_answerTimeout).then((accepted) {
          if (_isDisposed ||
              _transferStateVersion != requestVersion ||
              _transferType != 'incoming_request') {
            return;
          }
          _requestAnswer = accepted ? 'accepted' : 'rejected';
          if (accepted) {
            _transferType = 'receive';
            _transferSpeed = 'Connecting...';
            _startReceiveUploadTimeout();
            notifyListeners();
          } else {
            _resetTransferState();
          }
        });
      } on RequestTooLarge {
        _readingRequest = false;
        await _sendJson(response, HttpStatus.requestEntityTooLarge, {
          'status': 'too_large',
        });
      } on UnsupportedEncryption {
        _readingRequest = false;
        await _sendJson(response, HttpStatus.unprocessableEntity, {
          'status': 'unsupported_encryption',
        });
      } on FormatException catch (error) {
        _readingRequest = false;
        await _sendJson(response, HttpStatus.badRequest, {
          'status': 'invalid_request',
          'error': error.message,
        });
      } catch (e) {
        _readingRequest = false;
        if (_isDisposed) {
          return;
        }
        if (kDebugMode) debugPrint('Transfer request error: $e');
        await _sendJson(response, HttpStatus.internalServerError, {
          'error': e.toString(),
        });
        _resetTransferState();
      }
      return;
    }

    if (request.method == 'POST' && request.uri.path == '/upload') {
      final token = request.headers.value('x-transfer-token') ?? '';
      if (_transferType != 'receive' ||
          _uploadToken == null ||
          !secureTextMatch(token, _uploadToken!)) {
        await _sendJson(response, HttpStatus.unauthorized, {
          'status': 'unauthorized',
          'error': 'Transfer was not accepted',
        });
        return;
      }
      _uploadToken = null;
      _incomingUpload = request;

      if (_expectedFileName == null ||
          _expectedFileSize == null ||
          _expectedFolder == null ||
          _expectedSenderId == null ||
          _expectedRequestId == null ||
          _expectedEncryption == null ||
          _expectedChunkSize == null ||
          _transferDetails == null ||
          _transferKeys == null) {
        await _sendJson(response, HttpStatus.badRequest, {
          'status': 'invalid_request',
          'error': 'No transfer is waiting',
        });
        _resetTransferState();
        return;
      }

      _cancelReceiveUploadTimeout();

      File? receivedFile;
      Directory? extractionDir;
      var receiveSucceeded = false;

      try {
        final expectedFileName = _expectedFileName!;
        final expectedFileLength = _expectedFileSize!;
        final expectedIsFolder = _expectedFolder!;
        final expectedSenderId = _expectedSenderId!;
        final expectedSenderIp = _expectedSenderIp;
        final upload = UploadInfo.fromHeaders(
          encodedFileName: request.headers.value('x-file-name'),
          fileSize: request.headers.value('x-file-size'),
          isFolder: request.headers.value('x-is-folder'),
          senderId: request.headers.value('x-sender-id'),
          requestId: request.headers.value('x-request-id'),
          contentEncryption: request.headers.value('x-content-encryption'),
          encryptionChunkSize: request.headers.value('x-encryption-chunk-size'),
        );
        final remoteIp = request.connectionInfo?.remoteAddress.address;
        if (upload.fileName != expectedFileName) {
          throw Exception('Upload file name mismatch from accepted request.');
        }
        if (upload.fileSize != expectedFileLength) {
          throw Exception('Upload file size mismatch from accepted request.');
        }
        if (upload.isFolder != expectedIsFolder) {
          throw Exception('Upload folder flag mismatch from accepted request.');
        }
        if (upload.senderId != expectedSenderId) {
          throw Exception('Upload sender mismatch from accepted request.');
        }
        if (upload.requestId != _expectedRequestId) {
          throw Exception('Upload request identifier mismatch.');
        }
        if (upload.contentEncryption != _expectedEncryption ||
            upload.encryptionChunkSize != _expectedChunkSize) {
          throw Exception('Upload encryption metadata mismatch.');
        }
        if (expectedSenderIp != null && remoteIp != expectedSenderIp) {
          throw Exception('Upload came from a different device.');
        }

        final fileName = expectedFileName;
        final fileLength = expectedFileLength;
        final isFolder = expectedIsFolder;
        final encrypted = upload.contentEncryption == fileEncryption;
        final expectedWireLength = encrypted
            ? encryptedSize(fileLength)
            : fileLength;
        if (request.contentLength != expectedWireLength) {
          throw Exception('Upload content length does not match the request.');
        }
        _showTransferNotification('Receiving file', progress: 0);

        final Directory downloadDir;
        if (Platform.isAndroid) {
          final documents = await getApplicationDocumentsDirectory();
          downloadDir = Directory(p.join(documents.path, 'QuickDrop Received'));
        } else {
          downloadDir =
              await getDownloadsDirectory() ??
              await getApplicationDocumentsDirectory();
        }
        await downloadDir.create(recursive: true);
        final downloadPath = p.canonicalize(downloadDir.absolute.path);

        String baseName = p.basenameWithoutExtension(fileName);
        String extension = p.extension(fileName);
        String finalName = fileName;

        if (isFolder && extension.isEmpty) {
          extension = '.tar';
          finalName = '$baseName$extension';
        }

        String targetPath = p.join(downloadDir.path, finalName);
        int counter = 1;
        while (await File(targetPath).exists() ||
            (isFolder &&
                await Directory(p.join(downloadDir.path, baseName)).exists())) {
          if (isFolder) {
            baseName = '${p.basenameWithoutExtension(fileName)} ($counter)';
            finalName = baseName + extension;
          } else {
            finalName =
                '${p.basenameWithoutExtension(fileName)} ($counter)$extension';
          }
          targetPath = p.join(downloadDir.path, finalName);
          counter++;
        }
        final savePath = p.canonicalize(File(targetPath).absolute.path);
        if (savePath != downloadPath && !p.isWithin(downloadPath, savePath)) {
          throw Exception('Refusing to write outside Downloads directory.');
        }

        final file = File(targetPath);
        receivedFile = file;
        final ioSink = file.openWrite();

        int bytesReceived = 0;
        int lastBytesReceived = 0;
        double shownSpeed = 0;
        final stopwatch = Stopwatch()..start();

        Timer? speedTimer = Timer.periodic(const Duration(milliseconds: 500), (
          timer,
        ) {
          if (_isDisposed) {
            timer.cancel();
            return;
          }
          shownSpeed = _updateShownSpeed(
            shownSpeed: shownSpeed,
            byteDelta: bytesReceived - lastBytesReceived,
            stopwatch: stopwatch,
          );
          lastBytesReceived = bytesReceived;
          _transferSpeed = _formatSpeed(shownSpeed);
          _showTransferNotification(
            'Receiving file',
            progress: (_transferProgress * 100).round(),
          );
          notifyListeners();
        });

        final currentVersion = _transferStateVersion;
        try {
          void checkCancelled() {
            if (_transferStateVersion != currentVersion) {
              throw Exception('Transfer cancelled');
            }
          }

          void countPlaintext(int count) {
            bytesReceived += count;
            if (bytesReceived > fileLength) {
              throw Exception('Upload stream exceeded announced file size.');
            }
            if (fileLength > 0) {
              _transferProgress = (bytesReceived / fileLength)
                  .clamp(0.0, 1.0)
                  .toDouble();
            }
          }

          final Stream<List<int>> stream;
          if (encrypted) {
            stream =
                FileEncryption(
                  details: _transferDetails!,
                  keys: _transferKeys!,
                ).decrypt(
                  request,
                  onPlaintext: countPlaintext,
                  checkCancelled: checkCancelled,
                );
          } else {
            stream = request.map((chunk) {
              checkCancelled();
              countPlaintext(chunk.length);
              return chunk;
            });
          }

          await ioSink.addStream(stream);

          if (bytesReceived != fileLength) {
            throw Exception(
              'Upload stream ended early. Expected $fileLength bytes, received $bytesReceived bytes.',
            );
          }
        } finally {
          speedTimer.cancel();
          stopwatch.stop();
          try {
            await ioSink.flush();
            await ioSink.close();
          } catch (_) {}
        }

        // The sender only needs to know the full file arrived safely.
        await _sendJson(response, HttpStatus.ok, {'status': 'success'});
        receiveSucceeded = true;

        try {
          if (isFolder) {
            _transferSpeed = 'Extracting...';
            _transferProgress = 0.99;
            _showTransferNotification('Extracting folder');
            notifyListeners();

            final destPath = p.join(downloadDir.path, baseName);
            extractionDir = Directory(destPath);
            await extractionDir.create(recursive: true);

            await compute(extractFolder, {
              'archivePath': file.path,
              'destPath': destPath,
            });
            await file.delete();

            if (_transferStateVersion != currentVersion) {
              throw Exception('Transfer cancelled during extraction');
            }
          }

          if (Platform.isAndroid) {
            _transferSpeed = 'Saving to Downloads...';
            _showTransferNotification(
              isFolder ? 'Saving folder' : 'Saving file',
            );
            notifyListeners();
            final exportedPath = isFolder ? extractionDir?.path : file.path;
            if (exportedPath == null) {
              throw Exception('Received folder was unavailable for export.');
            }
            await _nativeChannel.invokeMethod<void>('exportToDownloads', {
              'path': exportedPath,
              'isFolder': isFolder,
            });
            if (isFolder) {
              if (extractionDir != null && await extractionDir.exists()) {
                await extractionDir.delete(recursive: true);
              }
            } else if (await file.exists()) {
              await file.delete();
            }
          }

          _transferProgress = 1.0;
          _transferSpeed = 'Finished';
          _transferType = 'receive_finished';
          _sendStatus();
          notifyListeners();
        } catch (e) {
          if (kDebugMode) debugPrint('Local file handling error: $e');
          try {
            if (extractionDir != null && await extractionDir.exists()) {
              await extractionDir.delete(recursive: true);
            }
          } catch (_) {}
          _transferProgress = 1.0;
          _transferSpeed = 'Failed';
          _transferType = 'receive_finished';
          _sendStatus();
          notifyListeners();
        }
      } catch (e) {
        if (kDebugMode) debugPrint('Upload handling error: $e');
        if (!_isDisposed) {
          try {
            await _sendJson(response, HttpStatus.unprocessableEntity, {
              'status': 'invalid_upload',
              'error': 'The transfer payload was invalid.',
            });
          } catch (_) {}
        }
        if (!receiveSucceeded) {
          try {
            if (receivedFile != null && await receivedFile.exists()) {
              await receivedFile.delete();
            }
            if (extractionDir != null && await extractionDir.exists()) {
              await extractionDir.delete(recursive: true);
            }
          } catch (_) {}
        }
        if (!_isDisposed) {
          _transferSpeed = 'Failed';
          notifyListeners();
        }
      } finally {
        if (identical(_incomingUpload, request)) {
          _incomingUpload = null;
        }
        _resetTransferStateAfterDelay(force: true);
      }
      return;
    }

    response.statusCode = HttpStatus.notFound;
    await response.close();
  }

  Future<void> _sendJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> body,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  void acceptTransfer() {
    final waiter = _answerWaiter;
    if (waiter != null && !waiter.isCompleted) {
      _showTransferNotification('Waiting for sender');
      waiter.complete(true);
    }
  }

  void declineTransfer() {
    if (!(_answerWaiter?.isCompleted ?? true)) {
      _answerWaiter?.complete(false);
    }
    _resetTransferState();
  }

  void dismissTransfer() {
    _resetTransferState();
  }

  void cancelActiveTransfer() {
    final device = _pendingSendDevice;
    final requestId = _pendingRequestId;
    if (device != null && requestId != null) {
      unawaited(_cancelPendingRequest(device, requestId));
    }

    final packFile = _activePackFile;
    if (packFile != null) {
      _cancelingPack = true;
      _transferStateVersion++;
      _packCancelVersion = _transferStateVersion;
      _transferSpeed = 'Cancelling...';
      notifyListeners();

      final process = _activePackProcess;
      process?.kill();
      if (Platform.isAndroid) {
        unawaited(
          _nativeChannel
              .invokeMethod<void>('cancelFolderPack')
              .catchError((_) {}),
        );
      }
      unawaited(_finishPackCancel(process, packFile, _packCancelVersion!));
      return;
    }
    _resetTransferState();
  }

  Future<void> _finishPackCancel(
    Process? process,
    File packFile,
    int cancelVersion,
  ) async {
    if (process != null) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        process.kill(ProcessSignal.sigkill);
      }
    } else {
      try {
        await _activePackFuture;
      } catch (_) {}
    }
    await _deleteFileIfExists(packFile);
    if (identical(_activePackFile, packFile)) {
      _activePackFile = null;
    }
    _activePackProcess = null;
    _activePackFuture = null;
    _cancelingPack = false;
    if (_packCancelVersion != cancelVersion ||
        _transferStateVersion != cancelVersion) {
      return;
    }
    _packCancelVersion = null;
    _resetTransferState();
    _sendStatus();
  }

  Future<void> _cancelPendingRequest(
    NetworkDevice device,
    String requestId,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      for (final ip in device.ips.where(_isPrivateOrLocalIp)) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 2);
        try {
          final statusCode =
              await (() async {
                final request = await client.postUrl(
                  Uri(
                    scheme: 'http',
                    host: ip,
                    port: device.port,
                    path: '/cancel_request',
                  ),
                );
                request.headers.contentType = ContentType.json;
                request.write(jsonEncode({'requestId': requestId}));
                final response = await request.close();
                final status = response.statusCode;
                await response.drain<void>();
                return status;
              })().timeout(
                const Duration(seconds: 2),
                onTimeout: () {
                  client.close(force: true);
                  throw TimeoutException('Cancellation timed out.');
                },
              );
          if (statusCode == HttpStatus.ok ||
              statusCode == HttpStatus.notFound) {
            return;
          }
        } catch (_) {
          // Try another address if this device has one.
        } finally {
          client.close(force: true);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<bool> _waitForAnswer(Duration timeout) async {
    final waiter = _answerWaiter;
    if (waiter == null) return false;
    final accepted = await Future.any<bool>([
      waiter.future,
      Future<bool>.delayed(timeout, () => false),
    ]);
    if (!accepted && !waiter.isCompleted) {
      waiter.complete(false);
    }
    return accepted;
  }

  bool _isCurrentTransfer(int version, [String? expectedType]) {
    return !_isDisposed &&
        _transferStateVersion == version &&
        (expectedType == null || _transferType == expectedType);
  }

  String _newRequestId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  bool _isRestartingUdp = false;

  void _handleUdpFailure() {
    if (_isDisposed || _isRestartingUdp) return;
    _isRestartingUdp = true;
    _udpSocket?.close();
    _udpSocket = null;

    _udpRetryCount++;
    if (_udpRetryCount > 5) {
      if (kDebugMode) {
        debugPrint('UDP Socket retry limit (5) exceeded. Stopping.');
      }
      _isRestartingUdp = false;
      return;
    }

    final backoffSecs = _udpRetryCount * 2;
    Future.delayed(Duration(seconds: backoffSecs), () {
      _isRestartingUdp = false;
      _startUdpDiscovery();
    });
  }

  Future<void> _startUdpDiscovery() async {
    if (_isDisposed) return;
    if (_udpRetryCount >= 5) {
      if (kDebugMode) {
        debugPrint('UDP socket maximum retry attempts (5) reached.');
      }
      return;
    }
    try {
      _udpSocket?.close();
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpPort,
        reuseAddress: true,
      );
      _udpSocket!.broadcastEnabled = true;
      _udpRetryCount = 0;

      _udpSocket!.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.closed) {
            _handleUdpFailure();
            return;
          }
          if (event == RawSocketEvent.read) {
            try {
              final datagram = _udpSocket!.receive();
              if (datagram != null) {
                _parseDiscoveryPacket(datagram.data, datagram.address.address);
              }
            } catch (e) {
              _handleUdpFailure();
            }
          }
        },
        onError: (e) {
          _handleUdpFailure();
        },
        onDone: () {
          _handleUdpFailure();
        },
      );
    } catch (e) {
      if (kDebugMode) debugPrint('UDP Socket error: $e');
      _handleUdpFailure();
    }
  }

  void _parseDiscoveryPacket(Uint8List data, String senderIp) {
    if (data.length > 4096) return;
    try {
      final message = utf8.decode(data);
      final json = jsonDecode(message) as Map<String, dynamic>;
      final device = NetworkDevice.fromJson(json, senderIp);

      if (device.id == deviceId) return;

      if (!allowSamePcDiscovery && _isLocalDiscoveryAddress(senderIp)) {
        return;
      }

      final index = _devices.indexWhere((d) => d.id == device.id);
      if (index == -1) {
        if (_devices.length >= _maxDiscoverablePeers) return;
        _devices.add(device);
        notifyListeners();
      } else {
        final previous = _devices[index];
        _devices[index] = device;
        if (previous.name != device.name ||
            previous.deviceType != device.deviceType ||
            previous.port != device.port ||
            previous.status != device.status ||
            previous.ips.join(',') != device.ips.join(',')) {
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  void _startTimers() {
    if (_isDisposed) return;
    _sendStatus();
    _broadcastTimer = Timer.periodic(_statusEvery, (_) => _sendStatus());
    _pruneTimer = Timer.periodic(_cleanupEvery, (_) => _removeOldDevices());

    _ipRefreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _resolveLocalIps(),
    );

    _startSamePcScanner();
  }

  void _startSamePcScanner() {
    if (!Platform.isWindows || !allowSamePcDiscovery) return;
    _scanSamePcPorts();
    _samePcScanTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _scanSamePcPorts();
    });
  }

  Future<void> _scanSamePcPorts() async {
    if (_isDisposed) return;
    final futures = <Future<void>>[];
    for (int port = 50005; port <= 50050; port++) {
      if (port == _localHttpPort) continue;
      futures.add(() async {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        try {
          final device = await (() async {
            final uri = Uri.parse('http://127.0.0.1:$port/ping');
            final request = await client.getUrl(uri);
            final response = await request.close();
            if (response.statusCode != HttpStatus.ok) {
              await response.drain<void>();
              return null;
            }
            final bodyStr = await RequestBody.readUtf8(
              response,
              maxBytes: _maxRequestBytes,
            );
            final json = jsonDecode(bodyStr) as Map<String, dynamic>;
            return NetworkDevice.fromJson(json, '127.0.0.1');
          })().timeout(const Duration(seconds: 1));

          if (device != null && !_isDisposed) {
            if (device.id != deviceId) {
              final index = _devices.indexWhere((d) => d.id == device.id);
              if (index == -1) {
                _devices.add(device);
              } else {
                _devices[index] = device.copyWith(ips: ['127.0.0.1']);
              }
              notifyListeners();
            }
          }
        } catch (_) {
        } finally {
          client.close(force: true);
        }
      }());
    }
    await Future.wait(futures);
  }

  void _sendStatus() {
    if (_udpSocket == null) return;
    try {
      final packet = jsonEncode(_presenceJson());
      final bytes = utf8.encode(packet);

      // Try the main Wi-Fi broadcast address too.
      try {
        _udpSocket!.send(bytes, InternetAddress('255.255.255.255'), udpPort);
      } catch (e) {
        if (kDebugMode) debugPrint('Global broadcast error: $e');
      }

      // Also tell devices already on the list.
      for (final d in _devices) {
        for (final peerIp in d.ips) {
          try {
            _udpSocket!.send(bytes, InternetAddress(peerIp), udpPort);
          } catch (_) {}
        }
      }

      // Common mobile hotspot addresses.
      for (final ip in ['192.168.43.1', '192.168.49.1', '192.168.137.1']) {
        try {
          _udpSocket!.send(bytes, InternetAddress(ip), udpPort);
        } catch (_) {}
      }

      for (final ip in _localIps) {
        final parts = ip.split('.');
        if (parts.length == 4) {
          final subnetBroadcast = _computeBroadcastIp(ip);
          if (subnetBroadcast != null) {
            try {
              _udpSocket!.send(
                bytes,
                InternetAddress(subnetBroadcast),
                udpPort,
              );
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Map<String, dynamic> _presenceJson() => {
    'id': deviceId,
    'name': deviceName,
    'deviceType': deviceType,
    'port': _localHttpPort,
    'status': (_transferType == 'none' || _showingFinishedTransfer)
        ? 'free'
        : 'busy',
  };

  void _removeOldDevices() {
    // Remove devices that have gone offline.
    final now = DateTime.now();
    final beforePruneCount = _devices.length;
    _devices.removeWhere((device) => device.isStale(now, _deviceTimeout));
    if (_devices.length != beforePruneCount) {
      notifyListeners();
    }
  }

  bool _isLocalDiscoveryAddress(String senderIp) {
    return senderIp == '127.0.0.1' ||
        senderIp == 'localhost' ||
        _localIps.contains(senderIp);
  }

  Future<void> sendFolder(
    NetworkDevice device,
    String folderPath, {
    String? folderName,
  }) async {
    // Folders are sent as one .tar file.
    final displayName = SafeFileName.clean(
      folderName ?? p.basename(folderPath),
      isFolder: true,
    );
    await _packAndSend(
      device: device,
      displayName: displayName,
      tempFileName: 'QuickDrop_${DateTime.now().millisecondsSinceEpoch}.tar',
      pack: (archivePath) => Platform.isAndroid
          ? _packAndroidFolder(folderPath, archivePath)
          : _packDesktopFolder(folderPath, archivePath),
    );
  }

  Future<PackResult> _packAndroidFolder(
    String folderUri,
    String archivePath,
  ) async {
    final result = await _nativeChannel.invokeMapMethod<dynamic, dynamic>(
      'packFolder',
      {'uri': folderUri, 'outputPath': archivePath},
    );
    return PackResult.fromMap(result);
  }

  Future<void> sendMultipleFiles(
    NetworkDevice device,
    List<String> filePaths,
  ) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch
        .toString()
        .substring(8);
    final archiveName = 'QuickDrop_Shared_Files_$timestamp.tar';
    await _packAndSend(
      device: device,
      displayName: 'Shared Files',
      tempFileName: archiveName,
      pack: (archivePath) async {
        await compute(packFiles, {
          'filePaths': filePaths,
          'archivePath': archivePath,
        });
        var bytes = 0;
        for (final path in filePaths) {
          bytes += await File(path).length();
        }
        return PackResult(
          files: filePaths.length,
          directories: 0,
          bytes: bytes,
        );
      },
    );
  }

  void confirmTransferCode() {
    final waiter = _codeCheck;
    if (_transferType == 'send_confirming' &&
        waiter != null &&
        !waiter.isCompleted) {
      waiter.complete();
    }
  }

  Future<bool> _waitForCodeCheck() async {
    final waiter = _codeCheck;
    if (waiter == null) return false;
    final result = Completer<bool>();
    _codeTimer?.cancel();
    _codeTimer = Timer(_answerTimeout, () {
      if (!result.isCompleted) result.complete(false);
    });
    waiter.future.then((_) {
      if (!result.isCompleted) result.complete(true);
    });
    final confirmed = await result.future;
    _codeTimer?.cancel();
    _codeTimer = null;
    if (identical(_codeCheck, waiter)) {
      _codeCheck = null;
    }
    return confirmed;
  }

  Future<void> sendAndroidFiles(
    NetworkDevice device,
    List<AndroidFile> files,
  ) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch
        .toString()
        .substring(8);
    await _packAndSend(
      device: device,
      displayName: 'Shared Files',
      tempFileName: 'QuickDrop_Shared_Files_$timestamp.tar',
      pack: (archivePath) async {
        final result = await _nativeChannel.invokeMapMethod<dynamic, dynamic>(
          'packFiles',
          {
            'files': files
                .map(
                  (file) => {
                    'uri': file.uri,
                    'name': file.name,
                    'size': file.size,
                  },
                )
                .toList(),
            'outputPath': archivePath,
          },
        );
        return PackResult.fromMap(result);
      },
    );
  }

  Future<void> _packAndSend({
    required NetworkDevice device,
    required String displayName,
    required String tempFileName,
    required Future<PackResult> Function(String archivePath) pack,
  }) async {
    if (_showingFinishedTransfer) {
      _resetTransferState();
    }
    if (_transferType != 'none') return;

    File? archiveFile;
    try {
      _beginTransferState();
      _transferFileName = displayName;
      _transferProgress = 0.0;
      _transferSpeed = 'Packaging...';
      _transferType = 'send_requesting';
      _transferIsFolder = true;
      _isEncrypted = encryptOutgoing;
      _showTransferNotification('Preparing files');
      notifyListeners();

      final tempDir = await getTemporaryDirectory();
      final archivePath = p.join(tempDir.path, tempFileName);
      archiveFile = File(archivePath);
      _activePackFile = archiveFile;
      _cancelingPack = false;

      final currentVersion = _transferStateVersion;
      final packFuture = pack(archivePath);
      _activePackFuture = packFuture;
      final stats = await packFuture;
      if (identical(_activePackFuture, packFuture)) {
        _activePackFuture = null;
      }

      _activePackFuture = null;

      if (_transferType != 'send_requesting' ||
          _transferStateVersion != currentVersion) {
        await _deleteFileIfExists(archiveFile);
        return;
      }

      if (!await archiveFile.exists()) {
        throw Exception('Packaging failed to generate archive.');
      }
      if (stats.files == 0) {
        throw Exception('The selected folder has no files to send.');
      }

      final size = await archiveFile.length();
      if (_transferType != 'send_requesting' ||
          _transferStateVersion != currentVersion) {
        await _deleteFileIfExists(archiveFile);
        return;
      }
      final fileToSend = _FileToSend(
        name: displayName,
        size: size,
        openRead: archiveFile.openRead,
        tempFile: archiveFile,
      );
      _fileToSend = fileToSend;
      if (identical(_activePackFile, archiveFile)) {
        _activePackFile = null;
      }
      await _requestSend(device, fileToSend, isFolder: true);
    } catch (e) {
      if (identical(_activePackFile, archiveFile)) {
        _activePackFile = null;
      }
      if (_cancelingPack || _transferType == 'none') return;
      if (kDebugMode) debugPrint('Archive error: $e');
      if (archiveFile != null) {
        await _deleteFileIfExists(archiveFile);
      }
      final message =
          (e is PlatformException ? e.message ?? e.code : e.toString())
              .replaceFirst('Exception: ', '');
      if (message.contains('has no files to send')) {
        _transferSpeed = 'The selected folder has no files to send.';
      } else if (message.contains('did not report the size')) {
        _transferSpeed = message;
      } else {
        _transferSpeed = 'Error packing';
      }
      _resetTransferStateAfterDelay();
    }
  }

  Future<PackResult> _packDesktopFolder(
    String folderPath,
    String archivePath,
  ) async {
    if (_cancelingPack || _transferType != 'send_requesting') {
      throw Exception('Folder packaging cancelled.');
    }

    final tar = Platform.isWindows ? 'tar.exe' : 'tar';
    final process = await Process.start(tar, [
      '-cf',
      archivePath,
      '-C',
      folderPath,
      '.',
    ]);
    _activePackProcess = process;
    unawaited(process.stdout.drain<void>());
    final errorText = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    final error = await errorText;
    if (identical(_activePackProcess, process)) {
      _activePackProcess = null;
    }
    if (_cancelingPack || _transferType != 'send_requesting') {
      throw Exception('Folder packaging cancelled.');
    }
    if (exitCode != 0 || !await File(archivePath).exists()) {
      throw Exception(
        error.trim().isEmpty ? 'Could not prepare the folder.' : error.trim(),
      );
    }
    var files = 0;
    var directories = 0;
    var bytes = 0;
    await for (final item in Directory(
      folderPath,
    ).list(recursive: true, followLinks: false)) {
      if (item is File) {
        files++;
        bytes += await item.length();
      } else if (item is Directory) {
        directories++;
      }
    }
    return PackResult(files: files, directories: directories, bytes: bytes);
  }

  Future<void> sendFile(NetworkDevice device, File file) async {
    if (_showingFinishedTransfer) {
      _resetTransferState();
    }
    if (_transferType != 'none') return;
    _transferIsFolder = false;
    _isEncrypted = encryptOutgoing;
    await _requestSend(
      device,
      _FileToSend(
        name: p.basename(file.path),
        size: await file.length(),
        openRead: file.openRead,
      ),
      isFolder: false,
    );
  }

  Future<void> sendAndroidFile(NetworkDevice device, AndroidFile file) async {
    if (_showingFinishedTransfer) _resetTransferState();
    if (_transferType != 'none') return;
    _isEncrypted = encryptOutgoing;
    await _requestSend(
      device,
      _FileToSend(
        name: file.name,
        size: file.size,
        openRead: () => _readAndroidFile(file),
      ),
      isFolder: false,
    );
  }

  Stream<List<int>> _readAndroidFile(AndroidFile file) async* {
    final fileId = await _nativeChannel.invokeMethod<int>('openFile', {
      'uri': file.uri,
    });
    if (fileId == null) {
      throw Exception('Android did not open the selected file.');
    }
    _openFileId = fileId;
    var bytesRead = 0;
    try {
      while (bytesRead < file.size) {
        final remaining = file.size - bytesRead;
        final bytes = await _nativeChannel
            .invokeMethod<Uint8List>('readFileChunk', {
              'fileId': fileId,
              'maxBytes': math.min(
                _isEncrypted ? encryptionBlockSize : 4 * 1024 * 1024,
                remaining,
              ),
            });
        if (bytes == null || bytes.isEmpty) {
          throw Exception(
            'The selected file ended early. Expected ${file.size} bytes, read $bytesRead.',
          );
        }
        bytesRead += bytes.length;
        if (bytesRead > file.size) {
          throw Exception('The selected file grew while it was being sent.');
        }
        yield bytes;
      }
      final trailing = await _nativeChannel.invokeMethod<Uint8List>(
        'readFileChunk',
        {'fileId': fileId, 'maxBytes': 1},
      );
      if (trailing != null && trailing.isNotEmpty) {
        throw Exception('The selected file grew while it was being sent.');
      }
    } finally {
      if (_openFileId == fileId) {
        _openFileId = null;
      }
      await _nativeChannel
          .invokeMethod<void>('closeFile', {'fileId': fileId})
          .catchError((_) {});
    }
  }

  bool _isPrivateOrLocalIp(String ip) {
    try {
      final addr = InternetAddress(ip);
      if (addr.isLoopback) {
        return allowSamePcDiscovery;
      }
      if (addr.type != InternetAddressType.IPv4 || addr.isLinkLocal) {
        return false;
      }
      final candidate = _ipv4AsInt(addr.address);
      if (candidate == null) return false;

      for (final localIp in _localIps) {
        final prefix = _ipPrefixes[localIp];
        final local = _ipv4AsInt(localIp);
        if (local == null) continue;
        if (prefix != null) {
          final mask = prefix == 0 ? 0 : (~0 << (32 - prefix));
          if ((candidate & mask) == (local & mask)) {
            return true;
          }
        } else {
          // Most home networks use /24 when the mask is not available.
          if ((candidate & 0xFFFFFF00) == (local & 0xFFFFFF00)) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  int? _ipv4AsInt(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final bytes = parts.map(int.tryParse).toList();
    if (bytes.any((byte) => byte == null || byte < 0 || byte > 255)) {
      return null;
    }
    return (bytes[0]! << 24) | (bytes[1]! << 16) | (bytes[2]! << 8) | bytes[3]!;
  }

  String _formatIpForUrl(String ip) {
    if (ip.contains(':')) {
      if (ip.startsWith('[') && ip.endsWith(']')) {
        return ip;
      }
      return '[$ip]';
    }
    return ip;
  }

  Duration _timeLeft(DateTime deadline) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      throw TimeoutException('Network operation timed out.');
    }
    return remaining;
  }

  Future<void> _requestSend(
    NetworkDevice device,
    _FileToSend file, {
    required bool isFolder,
  }) async {
    int? requestVersion;
    try {
      final fileName = SafeFileName.clean(
        isFolder ? _transferFileName : file.name,
        isFolder: isFolder,
      );
      final fileSize = file.size;
      NetworkDevice? liveDevice;
      for (final item in _devices) {
        if (item.id == device.id) {
          liveDevice = item;
          break;
        }
      }
      if (liveDevice == null || liveDevice.status == 'busy') {
        throw Exception('The selected device is offline or busy.');
      }
      device = liveDevice;

      _beginTransferState();
      requestVersion = _transferStateVersion;
      _transferFileName = fileName;
      _transferFileSize = fileSize;
      _transferIsFolder = isFolder;
      _transferProgress = 0.0;
      _transferSpeed = 'Requesting...';
      _transferType = 'send_requesting';
      _pendingSendDevice = device;
      _fileToSend = file;
      _showTransferNotification('Waiting for receiver');
      notifyListeners();

      final requestId = _newRequestId();
      _pendingRequestId = requestId;
      final contentEncryption = _isEncrypted ? fileEncryption : noEncryption;
      final encryptionChunkSize = _isEncrypted ? encryptionBlockSize : 0;
      final algorithm = X25519();
      _senderKeyPair = await algorithm.newKeyPair();
      final senderKey = await _senderKeyPair!.extractPublicKey();
      final senderKeyText = base64Encode(senderKey.bytes);
      if (!_isCurrentTransfer(requestVersion, 'send_requesting')) return;

      final validIps = device.ips.where(_isPrivateOrLocalIp).toList();
      if (validIps.isEmpty) {
        throw Exception('No valid local/private IP addresses to connect to.');
      }

      TransferReply? reply;
      NetworkDevice? workingDevice;
      for (final ip in validIps) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8);
        _requestClient = client;
        try {
          final requestDeadline = DateTime.now().add(
            const Duration(seconds: 8),
          );
          final response =
              await (() async {
                final uri = Uri(
                  scheme: 'http',
                  host: ip,
                  port: device.port,
                  path: '/request',
                );
                final req = await client.postUrl(uri);
                req.headers.contentType = ContentType.json;
                req.write(
                  jsonEncode({
                    'id': deviceId,
                    'requestId': requestId,
                    'name': deviceName,
                    'deviceType': deviceType,
                    'fileName': fileName,
                    'fileSize': fileSize,
                    'isFolder': isFolder,
                    'publicKey': senderKeyText,
                    'contentEncryption': contentEncryption,
                    'encryptionChunkSize': encryptionChunkSize,
                  }),
                );
                return req.close();
              })().timeout(
                _timeLeft(requestDeadline),
                onTimeout: () {
                  client.close(force: true);
                  throw TimeoutException('Transfer request timed out.');
                },
              );
          if (!_isCurrentTransfer(requestVersion, 'send_requesting')) return;

          if (response.statusCode == HttpStatus.serviceUnavailable) {
            await response.drain<void>().timeout(_timeLeft(requestDeadline));
            _transferSpeed = 'Busy';
            _resetTransferStateAfterDelay();
            return;
          }
          if (response.statusCode == HttpStatus.unprocessableEntity) {
            await response.drain<void>().timeout(_timeLeft(requestDeadline));
            _transferSpeed = 'Unsupported encryption';
            _resetTransferStateAfterDelay();
            return;
          }
          if (response.statusCode == HttpStatus.forbidden) {
            await response.drain<void>().timeout(_timeLeft(requestDeadline));
            _transferSpeed = 'Ignored';
            _resetTransferStateAfterDelay();
            return;
          }
          if (response.statusCode != HttpStatus.ok &&
              response.statusCode != HttpStatus.accepted) {
            await response.drain<void>().timeout(_timeLeft(requestDeadline));
            continue;
          }

          final bodyStr =
              await RequestBody.readUtf8(
                response,
                maxBytes: _maxRequestBytes,
              ).timeout(
                _timeLeft(requestDeadline),
                onTimeout: () {
                  client.close(force: true);
                  throw TimeoutException('Transfer response timed out.');
                },
              );
          if (!_isCurrentTransfer(requestVersion, 'send_requesting')) return;
          reply = TransferReply.fromJson(
            jsonDecode(bodyStr) as Map<String, dynamic>,
          );
          if (reply.contentEncryption != contentEncryption ||
              reply.encryptionChunkSize != encryptionChunkSize) {
            throw const UnsupportedEncryption();
          }
          workingDevice = device.copyWith(ips: [ip]);
          break;
        } on UnsupportedEncryption {
          rethrow;
        } catch (_) {
          // Try the next address if there is one.
        } finally {
          if (identical(_requestClient, client)) {
            _requestClient = null;
          }
          client.close(force: true);
        }
      }

      if (reply == null || workingDevice == null) {
        throw Exception('Could not connect to the selected peer.');
      }
      device = workingDevice;

      if (reply.status == 'accepted' || reply.status == 'pending') {
        final receiverKey = SimplePublicKey(
          reply.publicKeyBytes!,
          type: KeyPairType.x25519,
        );
        final sharedKey = await algorithm.sharedSecretKey(
          keyPair: _senderKeyPair!,
          remotePublicKey: receiverKey,
        );
        final details = TransferDetails(
          senderPublicKey: Uint8List.fromList(senderKey.bytes),
          receiverPublicKey: Uint8List.fromList(reply.publicKeyBytes!),
          senderId: deviceId,
          senderName: deviceName,
          senderDeviceType: deviceType,
          requestId: requestId,
          fileName: fileName,
          fileSize: fileSize,
          isFolder: isFolder,
          contentEncryption: contentEncryption,
          encryptionChunkSize: encryptionChunkSize,
        );
        final keys = await TransferKeys.create(
          sharedKey: sharedKey,
          details: details,
        );
        _transferDetails = details;
        _transferKeys = keys;
        _uploadToken = keys.uploadToken;
        _transferCode = keys.code;
        if (!_isCurrentTransfer(requestVersion, 'send_requesting')) return;

        _pendingSendDevice = device;
        notifyListeners();

        var currentStatus = reply.status;
        var consecutiveFailures = 0;
        final approvalDeadline = DateTime.now().add(
          _answerTimeout + const Duration(seconds: 5),
        );
        while (currentStatus == 'pending') {
          await Future.delayed(const Duration(seconds: 1));
          if (!_isCurrentTransfer(requestVersion, 'send_requesting')) return;
          if (!DateTime.now().isBefore(approvalDeadline)) {
            currentStatus = 'failed';
            _transferSpeed = 'Timeout waiting for approval';
            break;
          }
          final statusClient = HttpClient()
            ..connectionTimeout = const Duration(seconds: 3);
          _requestClient = statusClient;
          try {
            final statusDeadline = DateTime.now().add(
              const Duration(seconds: 3),
            );
            final statusRes =
                await (() async {
                  final uri = Uri.parse(
                    'http://${_formatIpForUrl(device.ips.first)}:${device.port}/request_status?requestId=$requestId',
                  );
                  final statusReq = await statusClient.getUrl(uri);
                  return statusReq.close();
                })().timeout(
                  _timeLeft(statusDeadline),
                  onTimeout: () {
                    statusClient.close(force: true);
                    throw TimeoutException('Status request timed out.');
                  },
                );
            if (statusRes.statusCode == HttpStatus.ok) {
              final statusBody = jsonDecode(
                await RequestBody.readUtf8(statusRes, maxBytes: 1024).timeout(
                  _timeLeft(statusDeadline),
                  onTimeout: () {
                    statusClient.close(force: true);
                    throw TimeoutException('Status response timed out.');
                  },
                ),
              );
              if (!_isCurrentTransfer(requestVersion, 'send_requesting')) {
                return;
              }
              if (statusBody is! Map<String, dynamic>) {
                throw const FormatException('Invalid transfer status.');
              }
              final value = statusBody['status'];
              if (value != 'pending' &&
                  value != 'accepted' &&
                  value != 'rejected') {
                throw const FormatException('Invalid transfer status.');
              }
              currentStatus = value as String;
              consecutiveFailures = 0;
            } else if (statusRes.statusCode == HttpStatus.notFound) {
              currentStatus = 'declined';
            } else if (statusRes.statusCode >= 500) {
              throw const HttpException('Temporary status failure.');
            } else {
              currentStatus = 'failed';
            }
          } catch (e) {
            if (kDebugMode) debugPrint('Polling connection failed: $e');
            consecutiveFailures++;
            if (consecutiveFailures >= 3) {
              currentStatus = 'failed';
              break;
            }
          } finally {
            if (identical(_requestClient, statusClient)) {
              _requestClient = null;
            }
            statusClient.close(force: true);
          }
          if (!_isCurrentTransfer(requestVersion, 'send_requesting')) {
            return;
          }
        }

        if (currentStatus == 'accepted') {
          if (!_isCurrentTransfer(requestVersion, 'send_requesting')) return;
          _transferType = 'send_confirming';
          _transferSpeed = 'Check the code';
          _codeCheck = Completer<void>();
          _showTransferNotification('Check the transfer code');
          notifyListeners();
          final confirmed = await _waitForCodeCheck();
          if (!_isCurrentTransfer(requestVersion, 'send_confirming')) return;
          if (confirmed) {
            await _startUpload();
          } else {
            _transferSpeed = 'Confirmation timed out';
            unawaited(_cancelPendingRequest(device, requestId));
            _resetTransferStateAfterDelay();
          }
        } else if (currentStatus == 'declined') {
          _transferSpeed = 'Declined';
          _resetTransferStateAfterDelay();
        } else {
          unawaited(_cancelPendingRequest(device, requestId));
          if (_transferSpeed != 'Timeout waiting for approval') {
            _transferSpeed = 'Failed';
          }
          _resetTransferStateAfterDelay();
        }
      } else {
        _transferSpeed = 'Declined';
        _resetTransferStateAfterDelay();
      }
    } catch (e) {
      if (_isDisposed) {
        return;
      }
      if (requestVersion != null && _transferStateVersion != requestVersion) {
        return;
      }
      final pendingDevice = _pendingSendDevice;
      final pendingRequestId = _pendingRequestId;
      if (pendingDevice != null && pendingRequestId != null) {
        unawaited(_cancelPendingRequest(pendingDevice, pendingRequestId));
      }
      if (kDebugMode) debugPrint('Send request failed: $e');
      _transferSpeed = e is UnsupportedEncryption
          ? 'Unsupported encryption'
          : 'Failed';
      _resetTransferStateAfterDelay();
    }
  }

  Future<void> _startUpload() async {
    if (_pendingSendDevice == null ||
        _fileToSend == null ||
        _uploadToken == null ||
        _pendingRequestId == null ||
        _transferDetails == null ||
        _transferKeys == null) {
      return;
    }

    final device = _pendingSendDevice!;
    final file = _fileToSend!;
    final details = _transferDetails!;
    final keys = _transferKeys!;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    _activeUploadClient = client;

    try {
      _beginTransferState();
      _transferType = 'send';
      _transferSpeed = 'Connecting...';
      _showTransferNotification('Sending file', progress: 0);
      notifyListeners();

      final uri = Uri.parse(
        'http://${_formatIpForUrl(device.ips.first)}:${device.port}/upload',
      );
      final request = await client.postUrl(uri);

      request.headers.set(
        'x-file-name',
        Uri.encodeComponent(_transferFileName),
      );
      request.headers.set('x-file-size', _transferFileSize.toString());
      request.headers.set('x-is-folder', _transferIsFolder.toString());
      request.headers.set('x-sender-id', deviceId);
      request.headers.set('x-request-id', _pendingRequestId!);
      request.headers.set('x-transfer-token', _uploadToken!);
      request.headers.set('x-content-encryption', details.contentEncryption);
      request.headers.set(
        'x-encryption-chunk-size',
        details.encryptionChunkSize.toString(),
      );
      request.headers.contentType = ContentType.binary;
      request.persistentConnection = false;
      request.contentLength = details.encrypted
          ? encryptedSize(_transferFileSize)
          : _transferFileSize;

      int bytesSent = 0;
      int lastBytesSent = 0;
      double shownSpeed = 0;

      final stopwatch = Stopwatch()..start();
      Timer? stallTimer;
      void resetStallTimer() {
        stallTimer?.cancel();
        stallTimer = Timer(_stallTimeout, () {
          client.close(force: true);
        });
      }

      Timer? speedTimer = Timer.periodic(const Duration(milliseconds: 500), (
        timer,
      ) {
        if (_isDisposed) {
          timer.cancel();
          return;
        }
        shownSpeed = _updateShownSpeed(
          shownSpeed: shownSpeed,
          byteDelta: bytesSent - lastBytesSent,
          stopwatch: stopwatch,
        );
        lastBytesSent = bytesSent;
        _transferSpeed = _formatSpeed(shownSpeed);
        _showTransferNotification(
          'Sending file',
          progress: (_transferProgress * 100).round(),
        );
        notifyListeners();
      });

      try {
        final currentVersion = _transferStateVersion;
        resetStallTimer();

        void checkCancelled() {
          if (_transferStateVersion != currentVersion) {
            throw Exception('Cancelled');
          }
        }

        void countPlaintext(int count) {
          bytesSent += count;
          resetStallTimer();
          if (_transferFileSize > 0) {
            _transferProgress = (bytesSent / _transferFileSize)
                .clamp(0.0, 0.99)
                .toDouble();
          }
        }

        final rawStream = file.openRead();
        final Stream<List<int>> stream;
        if (details.encrypted) {
          stream = FileEncryption(details: details, keys: keys).encrypt(
            rawStream,
            onPlaintext: countPlaintext,
            checkCancelled: checkCancelled,
          );
        } else {
          stream = rawStream.map((chunk) {
            checkCancelled();
            countPlaintext(chunk.length);
            if (bytesSent > _transferFileSize) {
              throw Exception(
                'The selected file grew while it was being sent.',
              );
            }
            return chunk;
          });
        }

        await request.addStream(stream);
        if (bytesSent != _transferFileSize) {
          throw Exception(
            'The selected file size changed during the transfer.',
          );
        }

        speedTimer.cancel();
        _transferSpeed = 'Finishing...';
        _showTransferNotification('Finishing transfer');
        notifyListeners();

        final response = await request.close().timeout(_sendTimeout);
        final bodyStr = await RequestBody.readUtf8(
          response.timeout(_sendTimeout),
          maxBytes: _maxRequestBytes,
        );
        var uploadSucceeded = false;
        if (response.statusCode == HttpStatus.ok) {
          UploadReply.fromJson(jsonDecode(bodyStr) as Map<String, dynamic>);
          uploadSucceeded = true;
        } else {
          try {
            final errorJson = jsonDecode(bodyStr);
            _transferSpeed = 'Err: ${errorJson['error']}';
          } catch (_) {
            _transferSpeed = 'Fail: ${response.statusCode}';
          }
        }

        if (uploadSucceeded) {
          _transferProgress = 1.0;
          _transferSpeed = 'Finished';
          _transferType = 'send_finished';
          _sendStatus();
          notifyListeners();
        } else {
          _transferProgress = 0.0;
          notifyListeners();
        }
      } finally {
        speedTimer.cancel();
        stallTimer?.cancel();
        stopwatch.stop();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('Client streaming failed: $e');
      _transferSpeed = 'Failed';
    } finally {
      client.close(force: true);
      if (identical(_activeUploadClient, client)) {
        _activeUploadClient = null;
      }

      _resetTransferStateAfterDelay();
    }
  }

  Future<void> _deleteFileIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _cleanOldPackages() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final oldestAllowed = DateTime.now().subtract(const Duration(hours: 12));
      await for (final item in tempDir.list()) {
        if (item is! File) continue;
        final name = p.basename(item.path);
        if (!name.startsWith('QuickDrop_') || !name.endsWith('.tar')) continue;
        if ((await item.lastModified()).isBefore(oldestAllowed)) {
          await _deleteFileIfExists(item);
        }
      }
    } catch (_) {}
  }

  void _beginTransferState() {
    _transferStateVersion++;
  }

  void _showTransferNotification(String title, {int progress = -1}) {
    if (!Platform.isAndroid || _transferType == 'none' || _canDismiss) return;
    final method = _transferServiceRunning
        ? 'updateTransferService'
        : 'startTransferService';
    _transferServiceRunning = true;
    final update = _nativeChannel.invokeMethod<void>(method, {
      'title': title,
      'fileName': _transferFileName.isEmpty ? 'File' : _transferFileName,
      'progress': progress.clamp(-1, 100),
    });
    unawaited(
      update.catchError((error) {
        _transferServiceRunning = false;
        if (kDebugMode) debugPrint('Transfer notification failed: $error');
      }),
    );
  }

  void _closeTransferNotification() {
    if (!Platform.isAndroid || !_transferServiceRunning) return;
    _transferServiceRunning = false;
    final stop = _nativeChannel.invokeMethod<void>('stopTransferService');
    unawaited(
      stop.catchError((error) {
        if (kDebugMode) debugPrint('Could not stop transfer service: $error');
      }),
    );
  }

  void _startReceiveUploadTimeout() {
    _cancelReceiveUploadTimeout();
    final version = _transferStateVersion;
    _receiveWaitTimer = Timer(_receiveTimeout, () {
      if (_isDisposed ||
          version != _transferStateVersion ||
          _transferType != 'receive') {
        return;
      }
      _transferSpeed = 'Failed';
      notifyListeners();
      _resetTransferStateAfterDelay(force: true);
    });
  }

  void _cancelReceiveUploadTimeout() {
    _receiveWaitTimer?.cancel();
    _receiveWaitTimer = null;
  }

  void _resetTransferState() {
    if (_isDisposed) {
      return;
    }
    _closeTransferNotification();
    if (_transferType == 'none') {
      return;
    }
    _transferStateVersion++;
    _cancelReceiveUploadTimeout();
    _canDismiss = false;
    _transferType = 'none';
    _transferProgress = 0.0;
    _transferSpeed = '0 KB/s';
    _transferFileName = '';
    _transferFileSize = 0;
    _transferIsFolder = false;
    _isEncrypted = false;
    _transferSenderName = '';
    _transferSenderDeviceType = 'desktop';
    _transferCode = '';
    final answerWaiter = _answerWaiter;
    if (answerWaiter != null && !answerWaiter.isCompleted) {
      answerWaiter.complete(false);
    }
    _answerWaiter = null;
    final codeCheck = _codeCheck;
    if (codeCheck != null && !codeCheck.isCompleted) {
      codeCheck.complete();
    }
    _codeCheck = null;
    _codeTimer?.cancel();
    _codeTimer = null;
    _activeUploadClient?.close(force: true);
    _activeUploadClient = null;
    _requestClient?.close(force: true);
    _requestClient = null;
    final incomingUpload = _incomingUpload;
    _incomingUpload = null;
    if (incomingUpload != null) {
      incomingUpload.response.persistentConnection = false;
      unawaited(incomingUpload.response.close().catchError((_) {}));
    }
    final openFileId = _openFileId;
    _openFileId = null;
    if (openFileId != null) {
      unawaited(
        _nativeChannel
            .invokeMethod<void>('closeFile', {'fileId': openFileId})
            .catchError((_) {}),
      );
    }
    _activePackProcess?.kill();
    if (Platform.isAndroid && _activePackFile != null) {
      unawaited(
        _nativeChannel
            .invokeMethod<void>('cancelFolderPack')
            .catchError((_) {}),
      );
    }
    _activePackProcess = null;
    _activePackFuture = null;
    final activePackFile = _activePackFile;
    _activePackFile = null;
    _cancelingPack = false;
    _packCancelVersion = null;
    if (activePackFile != null) {
      unawaited(_deleteFileIfExists(activePackFile));
    }

    final tempFile = _fileToSend?.tempFile;
    if (tempFile != null) {
      unawaited(_deleteFileIfExists(tempFile));
    }

    _pendingSendDevice = null;
    _fileToSend = null;
    _senderKeyPair = null;
    _receiverKeyPair = null;
    _uploadToken = null;
    _transferDetails = null;
    _transferKeys = null;
    _expectedFileName = null;
    _expectedFileSize = null;
    _expectedFolder = null;
    _expectedSenderId = null;
    _expectedSenderIp = null;
    _activeRequestId = null;
    _expectedRequestId = null;
    _expectedEncryption = null;
    _expectedChunkSize = null;
    _pendingRequestId = null;
    notifyListeners();
    _sendStatus();
  }

  void _resetTransferStateAfterDelay({bool force = false}) {
    if (_isDisposed) {
      return;
    }
    _closeTransferNotification();
    final version = _transferStateVersion;
    _canDismiss = true;
    notifyListeners();

    Future.delayed(const Duration(seconds: 5), () {
      if (!_isDisposed &&
          version == _transferStateVersion &&
          (force ||
              _transferType.startsWith('send') ||
              _showingFinishedTransfer ||
              _transferSpeed == 'Failed' ||
              _transferSpeed == 'Declined' ||
              _transferSpeed == 'Ignored' ||
              _transferSpeed == 'Busy' ||
              _transferSpeed == 'Finished')) {
        _resetTransferState();
      }
    });
  }

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    } else if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    } else {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    }
  }

  double _updateShownSpeed({
    required double shownSpeed,
    required int byteDelta,
    required Stopwatch stopwatch,
  }) {
    final seconds = stopwatch.elapsedMilliseconds / 1000.0;
    stopwatch.reset();
    stopwatch.start();
    if (seconds <= 0 || byteDelta <= 0) return shownSpeed;

    final latestSpeed = byteDelta / seconds;
    if (shownSpeed == 0) return latestSpeed;

    // A short average keeps normal Wi-Fi rate changes from jumping around.
    return shownSpeed * 0.7 + latestSpeed * 0.3;
  }

  String _sanitizeDeviceName(String rawName) {
    final normalized = rawName.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return 'Windows PC';
    return normalized.length > 15 ? normalized.substring(0, 15) : normalized;
  }

  @override
  void dispose() {
    _closeTransferNotification();
    _isDisposed = true;
    _broadcastTimer?.cancel();
    _pruneTimer?.cancel();
    _ipRefreshTimer?.cancel();
    _samePcScanTimer?.cancel();
    _cancelReceiveUploadTimeout();
    _activeUploadClient?.close(force: true);
    _requestClient?.close(force: true);
    final incomingUpload = _incomingUpload;
    if (incomingUpload != null) {
      incomingUpload.response.persistentConnection = false;
      unawaited(incomingUpload.response.close().catchError((_) {}));
    }
    _codeTimer?.cancel();
    _activePackProcess?.kill();
    final activePackFile = _activePackFile;
    if (activePackFile != null) unawaited(_deleteFileIfExists(activePackFile));
    if (Platform.isAndroid && activePackFile != null) {
      unawaited(
        _nativeChannel
            .invokeMethod<void>('cancelFolderPack')
            .catchError((_) {}),
      );
    }
    final tempFile = _fileToSend?.tempFile;
    if (tempFile != null) unawaited(_deleteFileIfExists(tempFile));
    final openFileId = _openFileId;
    if (openFileId != null) {
      unawaited(
        _nativeChannel
            .invokeMethod<void>('closeFile', {'fileId': openFileId})
            .catchError((_) {}),
      );
    }
    _udpSocket?.close();
    _httpServer?.close(force: true);
    if (Platform.isAndroid) {
      _nativeChannel.setMethodCallHandler(null);
      _nativeChannel
          .invokeMethod<void>('releaseMulticastLock')
          .catchError((_) {});
    }
    super.dispose();
  }
}
