import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickdrop/network/network_controller.dart';
import 'package:quickdrop/ui/app_theme.dart';
import 'package:quickdrop/ui/dashboard.dart';
import 'package:quickdrop/ui/widgets/active_transfer.dart';
import 'package:quickdrop/ui/widgets/settings_dialog.dart';

void main() {
  testWidgets('settings saves the outgoing encryption preference', (
    tester,
  ) async {
    String? savedName;
    bool? savedEncryption;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsDialog(
            initialName: 'Sender',
            initialEncryptOutgoing: false,
            onSave: (name, encryptOutgoing) {
              savedName = name;
              savedEncryption = encryptOutgoing;
            },
          ),
        ),
      ),
    );

    expect(find.text('Encrypt files I send'), findsOneWidget);
    expect(find.text('Protects file contents while sending.'), findsOneWidget);
    expect(find.text('karnyadav'), findsOneWidget);
    expect(find.byType(FaIcon), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(savedName, 'Sender');
    expect(savedEncryption, isTrue);
  });

  testWidgets('settings fits a short landscape screen', (tester) async {
    tester.view.physicalSize = const Size(740, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsDialog(
          initialName: 'Sender',
          initialEncryptOutgoing: false,
          onSave: (_, _) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('karnyadav'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  const screenSizes = {
    'small landscape': Size(740, 360),
    'Android landscape': Size(844, 390),
    'Android portrait': Size(390, 844),
  };

  for (final screen in screenSizes.entries) {
    testWidgets('${screen.key} keeps the Wi-Fi hint visible', (tester) async {
      tester.view.physicalSize = screen.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final network = _TestNetworkController();

      await tester.pumpWidget(MaterialApp(home: Dashboard(network: network)));
      await tester.pump();

      final hint = find.text('Keep devices connected to Wi-Fi');
      expect(hint, findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      final connectedText = tester.widget<Text>(find.text('Connected'));
      expect(connectedText.style?.fontSize, 10.5);
      expect(find.text('My device'), findsNothing);
      final dot = tester.widget<Container>(
        find.byKey(const ValueKey('connection-dot')),
      );
      expect((dot.decoration as BoxDecoration).color, AppColors.green);
      expect(
        tester.getBottomLeft(hint).dy,
        lessThanOrEqualTo(screen.value.height),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('top status turns red when the local network is gone', (
    tester,
  ) async {
    final network = _TestNetworkController(connected: false);
    await tester.pumpWidget(MaterialApp(home: Dashboard(network: network)));
    await tester.pump();

    expect(find.text('Not connected'), findsOneWidget);
    final dot = tester.widget<Container>(
      find.byKey(const ValueKey('connection-dot')),
    );
    expect((dot.decoration as BoxDecoration).color, AppColors.red);
  });

  testWidgets('encrypted code check fits a short landscape screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(740, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: ActiveTransfer(network: _ConfirmingNetworkController()),
      ),
    );
    await tester.pump();

    expect(find.text('Do the codes match?'), findsOneWidget);
    expect(find.text('Encrypted'), findsOneWidget);
    expect(find.text('MATCH THIS CODE'), findsOneWidget);
    for (final digit in '123456'.split('')) {
      expect(find.text(digit), findsOneWidget);
    }
    expect(find.text('Codes match - Send'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _TestNetworkController extends NetworkController {
  final bool connected;

  _TestNetworkController({this.connected = true})
    : super(
        deviceId: 'test-device',
        deviceName: 'Test Device',
        deviceType: 'desktop',
      );

  @override
  Future<void> start() async {}

  @override
  bool get hasLocalNetwork => connected;
}

class _ConfirmingNetworkController extends _TestNetworkController {
  @override
  String get transferType => 'send_confirming';

  @override
  String get transferSpeed => 'Check the code';

  @override
  String get transferCode => '123456';

  @override
  String get transferPeerName => 'Pixel phone';

  @override
  bool get isEncrypted => true;
}
