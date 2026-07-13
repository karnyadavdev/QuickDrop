import 'package:flutter/material.dart';

String deviceTypeName(String type) {
  if (type == 'mobile') return 'Android';
  if (type == 'linux') return 'Linux';
  return 'Windows';
}

IconData deviceTypeIcon(String type) {
  if (type == 'mobile') return Icons.phone_android_rounded;
  if (type == 'linux') return Icons.computer_rounded;
  return Icons.laptop_windows_rounded;
}
