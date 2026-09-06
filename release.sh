#!/bin/bash
set -euo pipefail
DEVICE_TARGET="iphone:clang:16.5:14.0"
MODE="${1:-}"
PKG_NAME="Ai液态玻璃"

rename_debs() {
    local pkg_dir
    for pkg_dir in packages .theos/packages; do
        if [[ -d "$pkg_dir" ]]; then
            for f in "$pkg_dir"/*.deb; do
                [[ -f "$f" ]] || continue
                local base="${f##*/}"
                local ver="${base#*_}"
                ver="${ver%%_*}"
                local new_name="${pkg_dir}/${PKG_NAME}_${ver}.deb"
                if [[ "$f" != "$new_name" ]]; then
                    mv "$f" "$new_name"
                    echo "  → ${new_name##*/}"
                fi
            done
        fi
    done
}

if [[ "$MODE" == "rootless" || -z "$MODE" ]]; then
    make clean
    make package -j8 ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
    rename_debs
fi
if [[ "$MODE" == "rootful" || -z "$MODE" ]]; then
    make clean
    make package -j8 ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1
    rename_debs
fi
# this only works if you got the roothide theos fork: https://github.com/roothide/theos
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
if [[ "$MODE" == "roothide" || -z "$MODE" ]]; then
    make clean
    make package -j8 ARCHS="arm64 arm64e" TARGET="$DEVICE_TARGET" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
    rename_debs
fi

if [[ "$MODE" == "sim" ]]; then
    make clean
    make -j8 ARCHS=x86_64 TARGET="simulator:clang:latest:14.0"
    cp .theos/obj/iphone_simulator/debug/*.dylib /opt/simject/
    cp -r .theos/obj/iphone_simulator/debug/LiquidAssPrefs.bundle /opt/simject/PreferenceBundles/
    cp LiquidAssPrefs/layout/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist /opt/simject/PreferenceLoader/Preferences/
    resim
fi
