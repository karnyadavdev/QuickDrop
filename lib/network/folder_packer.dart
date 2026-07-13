import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

Future<void> packFolder(Map<String, String> args) async {
  final folderPath = args['folderPath']!;
  final archivePath = args['archivePath']!;

  if (Platform.isWindows) {
    try {
      final result = Process.runSync('tar.exe', [
        '-cf',
        archivePath,
        '-C',
        folderPath,
        '.',
      ]);
      if (File(archivePath).existsSync() &&
          File(archivePath).lengthSync() > 0) {
        return;
      }
      throw Exception(
        'tar.exe failed with exit code ${result.exitCode}. Error: ${result.stderr}',
      );
    } catch (e) {
      throw Exception('Failed to pack folder using tar.exe: $e');
    }
  }

  final encoder = TarFileEncoder();
  encoder.open(archivePath);
  try {
    // Keep empty folders but skip links.
    await encoder.addDirectory(
      Directory(folderPath),
      followLinks: false,
      includeDirName: false,
    );
  } finally {
    await encoder.close();
  }
}

void packFiles(Map<String, dynamic> args) {
  final filePaths = _filePathsOnly(List<String>.from(args['filePaths']!));
  final archivePath = args['archivePath'] as String;

  if (Platform.isWindows && filePaths.isNotEmpty) {
    try {
      final firstParent = p.normalize(
        Directory(p.dirname(filePaths.first)).absolute.path,
      );
      bool allInSameDir = true;
      final relativeNames = <String>[];
      final seenNames = <String>{};
      for (final path in filePaths) {
        final parent = p.normalize(Directory(p.dirname(path)).absolute.path);
        if (parent != firstParent) {
          allInSameDir = false;
          break;
        }
        final name = p.basename(path);
        relativeNames.add(name);
        seenNames.add(name.toLowerCase());
      }

      if (allInSameDir && seenNames.length == relativeNames.length) {
        final result = Process.runSync('tar.exe', [
          '-cf',
          archivePath,
          '-C',
          firstParent,
          ...relativeNames,
        ]);
        if (File(archivePath).existsSync() &&
            File(archivePath).lengthSync() > 0) {
          return;
        }
        throw Exception(
          'tar.exe failed with exit code ${result.exitCode}. Error: ${result.stderr}',
        );
      }
    } catch (e) {
      throw Exception('Failed to pack files using tar.exe: $e');
    }
  }

  final encoder = TarFileEncoder();
  encoder.open(archivePath);
  try {
    final archiveNames = _fileNamesForArchive(filePaths);
    for (var i = 0; i < filePaths.length; i++) {
      encoder.addFile(File(filePaths[i]), archiveNames[i]);
    }
  } finally {
    encoder.close();
  }
}

List<String> _filePathsOnly(List<String> filePaths) {
  final regularFiles = <String>[];

  for (final path in filePaths) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      regularFiles.add(path);
      continue;
    }
    if (type == FileSystemEntityType.link) {
      continue;
    }
    throw FileSystemException('Only regular files can be packed.', path);
  }

  if (regularFiles.isEmpty) {
    throw const FileSystemException('No regular files to pack.');
  }
  return regularFiles;
}

List<String> _fileNamesForArchive(List<String> filePaths) {
  final used = <String>{};
  final names = <String>[];

  for (final filePath in filePaths) {
    final originalName = p.basename(filePath);
    final extension = p.extension(originalName);
    final stem = p.basenameWithoutExtension(originalName).isEmpty
        ? 'file'
        : p.basenameWithoutExtension(originalName);
    var candidate = originalName.isEmpty ? 'file' : originalName;
    var suffix = 2;

    while (!used.add(candidate.toLowerCase())) {
      candidate = '${stem}_$suffix$extension';
      suffix++;
    }
    names.add(candidate);
  }

  return names;
}

void extractFolder(Map<String, String> args) {
  final archivePath = args['archivePath']!;
  final destPath = args['destPath']!;

  _checkArchive(archivePath, destPath);

  if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
      _unpackWithTar(archivePath, destPath)) {
    return;
  }

  final inputStream = InputFileStream(archivePath);
  try {
    final archive = TarDecoder().decodeBuffer(inputStream);
    final destDir = Directory(destPath)..createSync(recursive: true);
    final safeFolder = p.canonicalize(destDir.absolute.path);

    for (final file in archive.files) {
      _checkPathParts(file.name);
      final normalizedName = p.normalize(file.name);
      if (p.isAbsolute(normalizedName)) {
        throw FormatException(
          'Refusing to extract absolute path: ${file.name}',
        );
      }
      if (file.isFile && (normalizedName.isEmpty || normalizedName == '.')) {
        throw FormatException(
          'Refusing to extract file without a safe name: ${file.name}',
        );
      }

      final targetPath = p.canonicalize(p.join(safeFolder, normalizedName));
      if (targetPath != safeFolder && !p.isWithin(safeFolder, targetPath)) {
        throw FormatException(
          'Refusing to extract path outside destination: ${file.name}',
        );
      }

      if (!file.isFile) {
        Directory(targetPath).createSync(recursive: true);
        continue;
      }

      final parentDir = Directory(p.dirname(targetPath));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }

      final output = OutputFileStream(targetPath);
      try {
        file.writeContent(output);
      } finally {
        output.closeSync();
      }
    }
  } finally {
    inputStream.close();
  }
}

bool _unpackWithTar(String archivePath, String destPath) {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      final String tarCmd = Platform.isWindows ? 'tar.exe' : 'tar';
      final extractResult = Process.runSync(tarCmd, [
        '-xf',
        archivePath,
        '-C',
        destPath,
      ]);
      return extractResult.exitCode == 0;
    } catch (_) {}
  }
  return false;
}

void _checkArchive(String archivePath, String destPath) {
  final inputStream = InputFileStream(archivePath);
  try {
    final decoder = TarDecoder();
    decoder.decodeBuffer(inputStream, storeData: false);
    final safeFolder = p.canonicalize(Directory(destPath).absolute.path);
    for (final entry in decoder.files) {
      // Only normal files and folders are allowed in an archive.
      final isRootDirectory =
          entry.typeFlag == TarFile.TYPE_DIRECTORY &&
          (entry.filename.isEmpty ||
              entry.filename == '.' ||
              entry.filename == './');
      if (!{
            '',
            TarFile.TYPE_NORMAL_FILE,
            TarFile.TYPE_DIRECTORY,
          }.contains(entry.typeFlag) ||
          (entry.nameOfLinkedFile?.isNotEmpty ?? false) ||
          (!isRootDirectory && !_isSafeEntry(entry.filename, safeFolder))) {
        throw FormatException(
          'Refusing unsafe archive entry: ${entry.filename}',
        );
      }
    }
  } finally {
    inputStream.close();
  }
}

bool _isSafeEntry(String name, String safeFolder) {
  try {
    _checkPathParts(name);
  } on FormatException {
    return false;
  }
  final normalizedName = p.normalize(name);
  if (p.isAbsolute(normalizedName)) return false;
  if (normalizedName.isEmpty || normalizedName == '.') return false;
  final targetPath = p.canonicalize(p.join(safeFolder, normalizedName));
  if (targetPath != safeFolder && !p.isWithin(safeFolder, targetPath)) {
    return false;
  }
  return true;
}

void _checkPathParts(String archiveName) {
  final parts = archiveName.replaceAll('\\', '/').split('/');
  if (parts.isEmpty) {
    throw FormatException(
      'Refusing to extract path without a safe name: $archiveName',
    );
  }

  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final isTrailingSlash = part.isEmpty && i == parts.length - 1;
    if (isTrailingSlash) {
      continue;
    }
    if (part == '.') {
      continue;
    }
    if (part.isEmpty || part == '..') {
      throw FormatException(
        'Refusing to extract unsafe path segment: $archiveName',
      );
    }

    final trimmed = _trimEnd(part);
    if (trimmed.isEmpty || _isWindowsReservedName(trimmed)) {
      throw FormatException(
        'Refusing to extract unsafe path segment: $archiveName',
      );
    }
  }
}

String _trimEnd(String value) {
  var result = value;
  while (result.endsWith('.') || result.endsWith(' ')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

bool _isWindowsReservedName(String value) {
  final stem = p.basenameWithoutExtension(value).toUpperCase();
  return stem == 'CON' ||
      stem == 'PRN' ||
      stem == 'AUX' ||
      stem == 'NUL' ||
      RegExp(r'^COM[1-9]$').hasMatch(stem) ||
      RegExp(r'^LPT[1-9]$').hasMatch(stem);
}
