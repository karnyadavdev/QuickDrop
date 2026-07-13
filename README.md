<p align="center">
  <img src="assets/images/logo.png" width="180" alt="QuickDrop logo">
</p>

# QuickDrop

<p align="center">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=flat-square&logo=windows11&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Android-3DDC84?style=flat-square&logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/Linux-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Linux">
</p>

QuickDrop is a file sharing app for Windows, Android and Linux. It finds other
devices running QuickDrop on the local network and sends files directly to
them. Nothing is uploaded to the cloud and no account is needed.

## Download

The installers are available on the Releases page:

- `QuickDrop-1.0.0-Windows-Installer.exe`
- `QuickDrop-1.0.0-Android.apk` - Android 10 or newer
- `QuickDrop-1.0.0-amd64.deb` - Ubuntu or Debian

## Encryption and speed

QuickDrop sends files directly over the local network. Speed mostly depends on
the Wi-Fi connection and the storage speed of both devices.

Encryption is off by default. To use it, open Settings and turn on
**Encrypt files I send**. It protects files while sending. Encryption can be a
little slower, so keep it off if you only want maximum speed.

## Building

QuickDrop is built with Flutter. Get the packages first:

```bash
flutter pub get
```

Build for the platform you are using:

```bash
flutter build apk --release
flutter build windows --release
flutter build linux --release
```

## License

QuickDrop is released under the MIT License.
