import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models/local_identity.dart';
import 'ui/app_theme.dart';
import 'ui/dashboard.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var deviceId = '';
  var deviceName = '';
  var deviceType = Platform.isAndroid
      ? 'mobile'
      : Platform.isLinux
      ? 'linux'
      : 'desktop';
  var encryptOutgoing = false;
  try {
    final documents = await getApplicationDocumentsDirectory();
    final file = File(path.join(documents.path, 'quickdrop_profile.json'));
    if (await file.exists()) {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      deviceId = data['deviceId'] is String ? data['deviceId'] as String : '';
      deviceName = data['name'] is String ? data['name'] as String : '';
      deviceType = data['deviceType'] is String
          ? data['deviceType'] as String
          : deviceType;
      encryptOutgoing = data['encryptOutgoing'] == true;
    }
  } catch (_) {}

  if (deviceId.isEmpty || deviceName.isEmpty) {
    final identity = LocalIdentity.random();
    deviceId = deviceId.isEmpty ? identity.id : deviceId;
    deviceName = deviceName.isEmpty ? identity.name : deviceName;
    try {
      final documents = await getApplicationDocumentsDirectory();
      final file = File(path.join(documents.path, 'quickdrop_profile.json'));
      await file.writeAsString(
        jsonEncode({
          'deviceId': deviceId,
          'name': deviceName,
          'deviceType': deviceType,
          'encryptOutgoing': encryptOutgoing,
        }),
      );
    } catch (_) {}
  }

  runApp(
    QuickDropApp(
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      encryptOutgoing: encryptOutgoing,
    ),
  );
}

class QuickDropApp extends StatelessWidget {
  final String? deviceId;
  final String? deviceName;
  final String? deviceType;
  final bool encryptOutgoing;

  const QuickDropApp({
    super.key,
    this.deviceId,
    this.deviceName,
    this.deviceType,
    this.encryptOutgoing = false,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QuickDrop',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: buildAppTheme(),
      home: Dashboard(
        deviceId: deviceId,
        deviceName: deviceName,
        deviceType: deviceType,
        encryptOutgoing: encryptOutgoing,
      ),
    );
  }
}
