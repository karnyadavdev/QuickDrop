#!/usr/bin/env bash
set -euo pipefail

project_folder="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$project_folder"

for command_name in flutter dpkg dpkg-deb; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

version_with_build_number="$(awk '/^version:/ { print $2; exit }' pubspec.yaml)"
version="${version_with_build_number%%+*}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid app version in pubspec.yaml: $version_with_build_number" >&2
  exit 1
fi

package_arch="$(dpkg --print-architecture)"
case "$package_arch" in
  amd64) flutter_folder="x64" ;;
  arm64) flutter_folder="arm64" ;;
  *)
    echo "Unsupported Debian architecture: $package_arch" >&2
    exit 1
    ;;
esac

echo "==> Building QuickDrop $version for Linux $package_arch"
flutter build linux --release

linux_build="$project_folder/build/linux/$flutter_folder/release/bundle"
output_folder="$project_folder/build/linux/packages"
package_contents="$project_folder/build/linux/deb-stage"
installer="$output_folder/QuickDrop-$version-$package_arch.deb"

if [[ ! -x "$linux_build/quickdrop" || ! -d "$linux_build/lib" || ! -d "$linux_build/data" ]]; then
  echo "Flutter did not create the expected Linux release bundle: $linux_build" >&2
  exit 1
fi

case "$package_contents" in
  "$project_folder"/build/linux/*) ;;
  *)
    echo "Refusing to clean an unexpected package folder: $package_contents" >&2
    exit 1
    ;;
esac

rm -rf -- "$package_contents"
mkdir -p \
  "$package_contents/DEBIAN" \
  "$package_contents/opt/quickdrop" \
  "$package_contents/usr/bin" \
  "$package_contents/usr/share/applications" \
  "$package_contents/usr/share/icons/hicolor/256x256/apps" \
  "$package_contents/usr/share/metainfo" \
  "$package_contents/etc/ufw/applications.d" \
  "$output_folder"

cp -a "$linux_build/." "$package_contents/opt/quickdrop/"
ln -s /opt/quickdrop/quickdrop "$package_contents/usr/bin/quickdrop"
install -m 0644 linux/packaging/quickdrop.desktop \
  "$package_contents/usr/share/applications/com.karnyadavdev.quickdrop.desktop"
install -m 0644 assets/images/logo.png \
  "$package_contents/usr/share/icons/hicolor/256x256/apps/com.karnyadavdev.quickdrop.png"
sed "s/@VERSION@/$version/g" \
  linux/packaging/com.karnyadavdev.quickdrop.metainfo.xml \
  > "$package_contents/usr/share/metainfo/com.karnyadavdev.quickdrop.metainfo.xml"
install -m 0644 linux/packaging/quickdrop.ufw \
  "$package_contents/etc/ufw/applications.d/quickdrop"

installed_size_kb="$(du -sk "$package_contents/opt" "$package_contents/usr" | awk '{ total += $1 } END { print total }')"
cat > "$package_contents/DEBIAN/control" <<EOF
Package: quickdrop
Version: $version
Section: utils
Priority: optional
Architecture: $package_arch
Installed-Size: $installed_size_kb
Maintainer: karnyadavdev
Homepage: https://github.com/karnyadavdev
Depends: libgtk-3-0 | libgtk-3-0t64, libblkid1, liblzma5, libc6, libstdc++6, libgcc-s1, iproute2, tar, zenity | kdialog | qarma
Description: Fast and simple local file sharing
 QuickDrop sends files and folders directly between nearby devices over the
 same Wi-Fi, hotspot, or local Ethernet network.
EOF

chmod 0755 "$package_contents/opt/quickdrop/quickdrop"
rm -f -- "$installer"
dpkg-deb --root-owner-group --build "$package_contents" "$installer"

if [[ "$(dpkg-deb --field "$installer" Package)" != "quickdrop" ]]; then
  echo "The generated package has the wrong package name." >&2
  exit 1
fi
if [[ "$(dpkg-deb --field "$installer" Version)" != "$version" ]]; then
  echo "The generated package has the wrong version." >&2
  exit 1
fi

echo "==> Done: $installer"
