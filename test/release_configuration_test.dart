import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickdrop/models/device.dart';
import 'package:quickdrop/ui/device_display.dart';

void main() {
  test('Android 10 minimum and release signing guard are configured', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('minSdk = 29'));
    expect(gradle, contains('versionCode = flutter.versionCode'));
    expect(gradle, contains('signingConfigs.getByName("release")'));
    expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
    expect(gradle, contains('QuickDrop release signing is not configured'));
  });

  test('profile identity is excluded from every Android backup path', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final legacy = File(
      'android/app/src/main/res/xml/backup_rules.xml',
    ).readAsStringSync();
    final modern = File(
      'android/app/src/main/res/xml/data_extraction_rules.xml',
    ).readAsStringSync();

    expect(manifest, contains('@xml/backup_rules'));
    expect(manifest, contains('@xml/data_extraction_rules'));
    expect(legacy, contains('app_flutter/quickdrop_profile.json'));
    expect(modern, contains('<cloud-backup>'));
    expect(modern, contains('<device-transfer>'));
    expect('app_flutter/quickdrop_profile.json'.allMatches(modern).length, 2);
  });

  test('Android transfers use a foreground service while backgrounded', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final service = File(
      'android/app/src/main/kotlin/com/karnyadavdev/quickdrop/TransferService.kt',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/karnyadavdev/quickdrop/MainActivity.kt',
    ).readAsStringSync();
    final controller = File(
      'lib/network/network_controller.dart',
    ).readAsStringSync();
    final packages = File('pubspec.yaml').readAsStringSync();

    expect(manifest, contains('FOREGROUND_SERVICE_DATA_SYNC'));
    expect(manifest, contains('android:foregroundServiceType="dataSync"'));
    expect(manifest, contains('android.permission.WAKE_LOCK'));
    expect(service, contains('PowerManager.PARTIAL_WAKE_LOCK'));
    expect(service, contains('START_NOT_STICKY'));
    expect(service, contains('override fun onTimeout'));
    expect(activity, contains('"startTransferService"'));
    expect(activity, contains('"updateTransferService"'));
    expect(activity, contains('"stopTransferService"'));
    expect(controller, contains("'startTransferService'"));
    expect(controller, contains("'updateTransferService'"));
    expect(controller, contains("'stopTransferService'"));
    expect(packages, isNot(contains('wakelock_plus')));
  });

  test('Linux devices and the Debian installer are configured', () {
    final cmake = File('linux/CMakeLists.txt').readAsStringSync();
    final packageScript = File(
      'linux/packaging/build_deb.sh',
    ).readAsStringSync();
    final desktopFile = File(
      'linux/packaging/quickdrop.desktop',
    ).readAsStringSync();
    final workflow = File(
      '.github/workflows/linux-package.yml',
    ).readAsStringSync();

    expect(cmake, contains('com.karnyadavdev.quickdrop'));
    expect(packageScript, contains('flutter build linux --release'));
    expect(packageScript, contains('libgtk-3-0 | libgtk-3-0t64'));
    expect(packageScript, contains('zenity | kdialog | qarma'));
    expect(
      packageScript,
      contains(r'version="${version_with_build_number%%+*}"'),
    );
    expect(packageScript, contains(r'QuickDrop-$version-$package_arch.deb'));
    expect(desktopFile, contains('Exec=quickdrop'));
    expect(desktopFile, contains('Icon=com.karnyadavdev.quickdrop'));
    expect(workflow, contains('runs-on: ubuntu-22.04'));
    expect(workflow, contains('bash linux/packaging/build_deb.sh'));
    expect(workflow, contains('for ubuntu_version in 22.04 24.04'));

    final device = NetworkDevice.fromJson({
      'id': 'ubuntu-pc',
      'name': 'Ubuntu PC',
      'deviceType': 'linux',
      'port': 50005,
      'status': 'free',
    }, '192.168.1.20');
    expect(device.deviceType, 'linux');
    expect(deviceTypeName(device.deviceType), 'Linux');
  });

  test('desktop installer names hide the Android build number', () {
    final installerScript = File(
      'windows/installer/inject_firewall_rule.ps1',
    ).readAsStringSync();
    final buildScript = File(
      'windows/installer/build_windows_installer.ps1',
    ).readAsStringSync();
    expect(
      installerScript,
      contains(r"$version = $versionWithBuildNumber.Split('+')[0]"),
    );
    expect(buildScript, contains('flutter build windows --release'));
    expect(buildScript, contains('Expected Windows app was not created'));
  });
}
