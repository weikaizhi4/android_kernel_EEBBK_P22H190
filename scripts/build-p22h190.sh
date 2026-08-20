#!/usr/bin/env bash
set -euo pipefail

# Targets:
#   kernel  build Image and modules only
#   recovery build Image, patch socko, and generate one recovery upgrade zip
#   socko/all aliases for recovery (kept for backwards compatibility)
# Profiles are selected with P22H190_PROFILE and P22H190_DEFCONFIG. The
# default profile remains the original P22H190 build; Droidspaces uses:
#   P22H190_PROFILE=droidspaces
#   P22H190_DEFCONFIG=ums512-p22h190_droidspaces_defconfig
TARGET="${1:-all}"
if [[ "$TARGET" == --target=* ]]; then
    TARGET="${TARGET#--target=}"
fi
case "$TARGET" in
    kernel|recovery|socko|all)
        ;;
    -h|--help|help)
        printf 'usage: %s [kernel|recovery|socko|all]\n' "$0"
        printf '\n'
        printf '  kernel  build Image/modules and publish kernel-output\n'
        printf '  recovery build and package one recovery upgrade zip\n'
        printf '  socko/all aliases for recovery (default)\n'
        printf '\n'
        printf '  Droidspaces profile:\n'
        printf '    P22H190_PROFILE=droidspaces \\\n'
        printf '    P22H190_DEFCONFIG=ums512-p22h190_droidspaces_defconfig \\\n'
        printf '    %s all\n' "$0"
        exit 0
        ;;
    *)
        printf 'error: unknown target: %s\n' "$TARGET" >&2
        printf 'usage: %s [kernel|recovery|socko|all]\n' "$0" >&2
        exit 2
        ;;
esac

SRC_DIR="${P22H190_SOURCE_DIR:-$(cd "$(dirname "$0")/.." && pwd -P)}"
PROFILE="${P22H190_PROFILE:-p22h190}"
DEFCONFIG="${P22H190_DEFCONFIG:-${DEFCONFIG:-ums512-p22h190_defconfig}}"
if [[ "$PROFILE" == "p22h190" ]]; then
    PROFILE_SUFFIX=""
else
    PROFILE_SUFFIX="-$PROFILE"
fi
OUT_DIR="${P22H190_BUILD_DIR:-$SRC_DIR/out/ums512-p22h190${PROFILE_SUFFIX}}"
DEST_DIR="${P22H190_OUTPUT_DIR:-$SRC_DIR/out/release${PROFILE_SUFFIX}}"
TC_DIR="${ANDROID_CLANG_DIR:-$SRC_DIR/out/toolchains/clang-r383902/bin}"
KPM_PATCHER="${KPM_PATCHER:-$SRC_DIR/out/tools/patch_linux}"
MODULE_METADATA_PATCHER="${MODULE_METADATA_PATCHER:-$SRC_DIR/tools/patch-module-metadata.pl}"
SOCKO_TEMPLATE="${SOCKO_TEMPLATE:-$SRC_DIR/prebuilts/p22h190/socko.factory.img}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-$SRC_DIR/out/AnyKernel3}"
RECOVERY_SCRIPT_TEMPLATE="${RECOVERY_SCRIPT_TEMPLATE:-$SRC_DIR/scripts/p22h190-recovery-anykernel.sh.in}"
ENABLE_KPM="${ENABLE_KPM:-1}"
FUSERMOUNT="${FUSERMOUNT:-$(command -v fusermount || command -v fusermount3 || true)}"

if [[ ! -f "$SRC_DIR/arch/arm64/configs/$DEFCONFIG" ]]; then
    printf 'error: defconfig not found: %s\n' "$SRC_DIR/arch/arm64/configs/$DEFCONFIG" >&2
    exit 1
fi

if [[ ! -x "$TC_DIR/clang" || ! -x "$TC_DIR/ld.lld" ]]; then
    printf 'error: Android clang toolchain not found in %s\n' "$TC_DIR" >&2
    exit 1
fi

if ! command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
    printf 'error: aarch64-linux-gnu binutils are not in PATH\n' >&2
    exit 1
fi

if [[ "$TARGET" != "kernel" ]]; then
    for command_name in aarch64-linux-gnu-objcopy modinfo modprobe fuse2fs e2fsck zip; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            printf 'error: required command not found: %s\n' "$command_name" >&2
            exit 1
        fi
    done

    if [[ -z "$FUSERMOUNT" ]]; then
        printf 'error: fusermount or fusermount3 is required\n' >&2
        exit 1
    fi

    if [[ ! -f "$SOCKO_TEMPLATE" ]]; then
        printf 'error: socko template not found: %s\n' "$SOCKO_TEMPLATE" >&2
        exit 1
    fi

    if [[ ! -f "$MODULE_METADATA_PATCHER" ]]; then
        printf 'error: module metadata patcher not found: %s\n' "$MODULE_METADATA_PATCHER" >&2
        exit 1
    fi

    if [[ ! -f "$RECOVERY_SCRIPT_TEMPLATE" ]]; then
        printf 'error: recovery installer template not found: %s\n' "$RECOVERY_SCRIPT_TEMPLATE" >&2
        exit 1
    fi
fi

export PATH="$TC_DIR:$PATH"

GIT_HASH="$(git -C "$SRC_DIR" rev-parse --short=12 HEAD)"
KERNEL_LOCALVERSION="-twodays-custom-g$GIT_HASH"
if [[ "$PROFILE" != "p22h190" ]]; then
    KERNEL_LOCALVERSION="-twodays-$PROFILE-custom-g$GIT_HASH"
fi
KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-twodays}"
KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-P22H190-build}"
BUILD_TIME="${KBUILD_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%d %H:%M:%S UTC')}"
KERNEL_AUTHOR="$KBUILD_BUILD_USER"

MAKE_ARGS=(
    O="$OUT_DIR"
    ARCH=arm64
    CC=clang
    LD=ld.lld
    CROSS_COMPILE=aarch64-linux-gnu-
    CLANG_TRIPLE=aarch64-linux-gnu-
    LOCALVERSION="$KERNEL_LOCALVERSION"
    KBUILD_BUILD_USER="$KBUILD_BUILD_USER"
    KBUILD_BUILD_HOST="$KBUILD_BUILD_HOST"
    KBUILD_BUILD_TIMESTAMP="$BUILD_TIME"
)

JOBS="${JOBS:-$(nproc)}"
OBJCOPY="${OBJCOPY:-aarch64-linux-gnu-objcopy}"

SOCKO_MODULES=(
    drivers/gpu/arm/midgard/mali_gondul.ko
    drivers/input/misc/vl53L0/stmvl53l0.ko
    drivers/npu/vdsp/sprd_vdsp.ko
    drivers/wcn/bluetooth/driver/sprdbt_tty.ko
    drivers/wcn/fm/driver/sprd_fm.ko
    drivers/wcn/wlan/sprdwl_ng.ko
    drivers/camera/core/sprd_camera.ko
    drivers/camera/cpp/sprd_cpp.ko
    drivers/camera/fd/sprd_fd.ko
    drivers/camera/flash/flash_drv/sprd_flash_drv.ko
    drivers/camera/flash/ocp8137/flash_ic_ocp8137.ko
    drivers/camera/mmdvfs/mmdvfs.ko
    drivers/camera/sensor/sprd_sensor.ko
)

printf 'profile: %s\n' "$PROFILE"
printf 'defconfig: %s\n' "$DEFCONFIG"
printf 'target: %s\n' "$TARGET"
printf '%s\n' "[1/4] generating $DEFCONFIG"
make -C "$SRC_DIR" "${MAKE_ARGS[@]}" "$DEFCONFIG"

printf '%s\n' "[2/4] building Image and modules with -j$JOBS ($KERNEL_LOCALVERSION)"
make -C "$SRC_DIR" "${MAKE_ARGS[@]}" -j"$JOBS"

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
if [[ ! -f "$IMAGE" ]]; then
    printf 'error: build completed without %s\n' "$IMAGE" >&2
    exit 1
fi
KERNEL_RELEASE="$(make -C "$SRC_DIR" "${MAKE_ARGS[@]}" -s kernelrelease)"
if [[ ! -f "$OUT_DIR/Module.symvers" ]]; then
    printf 'error: build completed without %s\n' "$OUT_DIR/Module.symvers" >&2
    exit 1
fi

STAGE="$(mktemp -d /tmp/p22h190-output.XXXXXX)"
SOCKO_MOUNT="$STAGE/socko-mount"
SOCKO_MOUNTED=0
cleanup() {
    if [[ "$SOCKO_MOUNTED" == "1" ]]; then
        "$FUSERMOUNT" -u "$SOCKO_MOUNT" 2>/dev/null || true
    fi
    rm -rf "$STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGE/modules"
mkdir -p "$STAGE/socko-modules"

if [[ "$ENABLE_KPM" == "1" ]]; then
    if [[ ! -x "$KPM_PATCHER" ]]; then
        printf 'error: KPM patcher not found or not executable: %s\n' "$KPM_PATCHER" >&2
        exit 1
    fi

    KPM_STAGE="$STAGE/kpm"
    mkdir -p "$KPM_STAGE"
    cp -f "$IMAGE" "$KPM_STAGE/Image"
    (
        cd "$KPM_STAGE"
        "$KPM_PATCHER"
    )
    if [[ ! -f "$KPM_STAGE/oImage" ]]; then
        printf 'error: KPM patcher completed without %s\n' "$KPM_STAGE/oImage" >&2
        exit 1
    fi
    cp -f "$KPM_STAGE/oImage" "$STAGE/Image"
else
    cp -f "$IMAGE" "$STAGE/Image"
fi
cp -f "$OUT_DIR/System.map" "$STAGE/System.map"
cp -f "$OUT_DIR/.config" "$STAGE/.config"

while IFS= read -r -d '' module; do
    relative="${module#"$OUT_DIR/"}"
    mkdir -p "$STAGE/modules/$(dirname "$relative")"
    cp -f "$module" "$STAGE/modules/$relative"
done < <(find "$OUT_DIR" -type f -name '*.ko' -print0)

if [[ "$TARGET" == "kernel" ]]; then
    {
        printf 'source=%s\n' "$SRC_DIR"
        printf 'output=%s\n' "$OUT_DIR"
        printf 'profile=%s\n' "$PROFILE"
        printf 'config=%s\n' "$DEFCONFIG"
        printf 'target=%s\n' "$TARGET"
        printf 'clang=%s\n' "$TC_DIR/clang"
        printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
        printf 'git_hash=%s\n' "$GIT_HASH"
        printf 'kpm=%s\n' "$ENABLE_KPM"
        if [[ "$ENABLE_KPM" == "1" ]]; then
            sha256sum "$KPM_PATCHER"
        fi
        printf 'built_at=%s\n' "$(date -Is)"
        sha256sum "$STAGE/Image"
    } > "$STAGE/build-info.txt"

    mkdir -p "$DEST_DIR"
    rm -rf "$DEST_DIR/modules.new"
    mv "$STAGE/modules" "$DEST_DIR/modules.new"
    cp -f "$STAGE/Image" "$DEST_DIR/Image"
    cp -f "$STAGE/System.map" "$DEST_DIR/System.map"
    cp -f "$STAGE/.config" "$DEST_DIR/.config"
    cp -f "$STAGE/build-info.txt" "$DEST_DIR/build-info.txt"
    rm -rf "$DEST_DIR/modules"
    mv "$DEST_DIR/modules.new" "$DEST_DIR/modules"

    printf '%s\n' '[3/4] kernel artifacts'
    stat -c '%n %s bytes' "$DEST_DIR/Image"
    printf 'modules: '
    find "$DEST_DIR/modules" -type f -name '*.ko' | wc -l
    sha256sum "$DEST_DIR/Image"
    printf 'output: %s\n' "$DEST_DIR"
    exit 0
fi

for relative in "${SOCKO_MODULES[@]}"; do
    module="$OUT_DIR/$relative"
    if [[ ! -f "$module" ]]; then
        printf 'error: required socko module not found: %s\n' "$module" >&2
        exit 1
    fi
    cp -f "$module" "$STAGE/socko-modules/$(basename "$relative")"
done

printf '%s\n' '[3/4] rebuilding socko image with compatible modules'
cp -f "$SOCKO_TEMPLATE" "$STAGE/socko.img"
mkdir -p "$SOCKO_MOUNT"
fuse2fs -o fakeroot "$STAGE/socko.img" "$SOCKO_MOUNT"
SOCKO_MOUNTED=1

declare -A BUILT_SOCKO_MODULES=()
for relative in "${SOCKO_MODULES[@]}"; do
    BUILT_SOCKO_MODULES["$(basename "$relative")"]="$OUT_DIR/$relative"
done

FACTORY_MODULES=()
while IFS= read -r -d '' module; do
    module_name="$(basename "$module")"
    if [[ -n "${BUILT_SOCKO_MODULES[$module_name]+present}" ]]; then
        continue
    fi
    cp -f "$module" "$STAGE/socko-modules/$module_name"
    FACTORY_MODULES+=("$STAGE/socko-modules/$module_name")
done < <(find "$SOCKO_MOUNT" -maxdepth 1 -type f -name '*.ko' -print0)

if ((${#FACTORY_MODULES[@]})); then
    perl "$MODULE_METADATA_PATCHER" \
        "$OUT_DIR/Module.symvers" "$KERNEL_RELEASE" "$OBJCOPY" \
        "${FACTORY_MODULES[@]}"
fi

for relative in "${SOCKO_MODULES[@]}"; do
    module_name="$(basename "$relative")"
    target="$SOCKO_MOUNT/$module_name"
    if [[ ! -f "$target" ]]; then
        printf 'error: socko template is missing module: %s\n' "$module_name" >&2
        exit 1
    fi
    cp -f "${BUILT_SOCKO_MODULES[$module_name]}" "$target"
done

for module in "${FACTORY_MODULES[@]}"; do
    cp -f "$module" "$SOCKO_MOUNT/$(basename "$module")"
done

"$FUSERMOUNT" -u "$SOCKO_MOUNT"
SOCKO_MOUNTED=0
e2fsck -fn "$STAGE/socko.img" >/dev/null
printf '%s\n' '[4/4] packaging recovery upgrade zip'
if [[ ! -f "$ANYKERNEL_DIR/anykernel.sh" ]]; then
    printf 'error: AnyKernel3 template not found: %s\n' "$ANYKERNEL_DIR" >&2
    exit 1
fi
AK_STAGE="$STAGE/AnyKernel3"
cp -a "$ANYKERNEL_DIR/." "$AK_STAGE/"
rm -rf "$AK_STAGE/.git" "$AK_STAGE/.github"
cp -f "$STAGE/Image" "$AK_STAGE/Image"
mkdir -p "$DEST_DIR"
cp -f "$STAGE/socko.img" "$AK_STAGE/socko.img"
cp -f "$RECOVERY_SCRIPT_TEMPLATE" "$AK_STAGE/anykernel.sh"

export AK_KERNEL_RELEASE="$KERNEL_RELEASE"
export AK_KERNEL_AUTHOR="$KERNEL_AUTHOR"
export AK_BUILD_TIME="$BUILD_TIME"
perl -0pi -e \
    's/\@KERNEL_RELEASE\@/$ENV{AK_KERNEL_RELEASE}/g; \
     s/\@KERNEL_AUTHOR\@/$ENV{AK_KERNEL_AUTHOR}/g; \
     s/\@BUILD_TIME\@/$ENV{AK_BUILD_TIME}/g' \
    "$AK_STAGE/anykernel.sh"
chmod 0755 "$AK_STAGE/anykernel.sh"

if [[ ! -f "$AK_STAGE/tools/ak3-core.sh" ]]; then
    printf 'error: AnyKernel3 boot unpack tool is missing: %s/tools/ak3-core.sh\n' "$AK_STAGE" >&2
    exit 1
fi

cat > "$AK_STAGE/build-info.txt" <<EOF
device=EEBBK P22H190
profile=$PROFILE
defconfig=$DEFCONFIG
kernel_release=$KERNEL_RELEASE
kernel_author=$KERNEL_AUTHOR
build_time=$BUILD_TIME
git_hash=$GIT_HASH
socko_target=/dev/block/by-name/socko
EOF

RECOVERY_OUTPUT="$DEST_DIR/P22H190-recovery${PROFILE_SUFFIX}-$KERNEL_RELEASE.zip"
rm -f "$DEST_DIR"/*.zip "$DEST_DIR"/*.img "$DEST_DIR"/Image \
      "$DEST_DIR"/System.map "$DEST_DIR"/.config "$DEST_DIR"/build-info.txt \
      "$DEST_DIR"/SHA256SUMS
rm -rf "$DEST_DIR/modules" "$DEST_DIR/socko-modules"
(
    cd "$AK_STAGE"
    zip -q -r -9 "$RECOVERY_OUTPUT" .
)

{
    printf 'source=%s\n' "$SRC_DIR"
    printf 'output=%s\n' "$OUT_DIR"
    printf 'profile=%s\n' "$PROFILE"
    printf 'config=%s\n' "$DEFCONFIG"
    printf 'target=%s\n' "$TARGET"
    printf 'clang=%s\n' "$TC_DIR/clang"
    printf 'kernel_release=%s\n' "$KERNEL_RELEASE"
    printf 'kernel_author=%s\n' "$KERNEL_AUTHOR"
    printf 'build_time=%s\n' "$BUILD_TIME"
    printf 'git_hash=%s\n' "$GIT_HASH"
    printf 'kpm=%s\n' "$ENABLE_KPM"
    if [[ "$ENABLE_KPM" == "1" ]]; then
        sha256sum "$KPM_PATCHER"
    fi
    printf 'socko_modules=%s\n' "${#SOCKO_MODULES[@]}"
    printf 'socko_factory_modules=%s\n' "${#FACTORY_MODULES[@]}"
    printf 'socko_template=%s\n' "$SOCKO_TEMPLATE"
    printf 'socko_target=/dev/block/by-name/socko\n'
    printf 'recovery_output=%s\n' "$RECOVERY_OUTPUT"
    sha256sum "$STAGE/Image"
    sha256sum "$STAGE/socko.img"
    sha256sum "$RECOVERY_OUTPUT"
} > "$STAGE/build-info.txt"

printf '%s\n' '[4/4] recovery artifact'
stat -c '%n %s bytes' "$RECOVERY_OUTPUT"
sha256sum "$RECOVERY_OUTPUT"
printf 'output: %s\n' "$DEST_DIR"
printf 'recovery: %s\n' "$RECOVERY_OUTPUT"
