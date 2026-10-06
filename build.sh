#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
set -euo pipefail

# -------- KernelSU variant selection (must run before logging/config setup) --------
# Default to no KernelSU variant if none of --ksu / --ksun / --resukisu is passed.
KSU_VARIANT="none"
KSU_FLAG_COUNT=0
for _arg in "$@"; do
    case "$_arg" in
        --ksu)      KSU_VARIANT="ksu";      KSU_FLAG_COUNT=$((KSU_FLAG_COUNT + 1));;
        --ksun)     KSU_VARIANT="ksun";     KSU_FLAG_COUNT=$((KSU_FLAG_COUNT + 1));;
        --resukisu) KSU_VARIANT="resukisu"; KSU_FLAG_COUNT=$((KSU_FLAG_COUNT + 1));;
    esac
done
if [[ $KSU_FLAG_COUNT -gt 1 ]]; then
    echo "Error: --ksu, --ksun and --resukisu are mutually exclusive; pass only one." >&2
    exit 2
fi

if [[ "$KSU_VARIANT" == "ksun" ]]; then
    KERNELSU_SETUP_URL="https://raw.githubusercontent.com/poqdavid/KernelSU-Next/dev/kernel/setup.sh"
    KERNELSU_SETUP_BRANCH="dev"
    BASE_KSU_VERSION=30000
    KSU_DIR="KernelSU-Next"
    KSU_LABEL="KernelSU Next"
    KSU_DISCORD_LABEL="KernelSUNext"
    SUSFS_KSU_INTERNAL_PATCH_DESC=""
    SUSFS_BUILTIN=0
    elif [[ "$KSU_VARIANT" == "ksu" ]]; then
    KERNELSU_SETUP_URL="https://raw.githubusercontent.com/poqdavid/KernelSU/main/kernel/setup.sh"
    KERNELSU_SETUP_BRANCH="main"
    BASE_KSU_VERSION=20000
    KSU_DIR="KernelSU"
    KSU_LABEL="KernelSU"
    KSU_DISCORD_LABEL="KernelSU"
    SUSFS_KSU_INTERNAL_PATCH_DESC=""
    SUSFS_BUILTIN=0
    elif [[ "$KSU_VARIANT" == "resukisu" ]]; then
    KERNELSU_SETUP_URL="https://raw.githubusercontent.com/poqdavid/ReSukiSU/main/kernel/setup.sh"
    KERNELSU_SETUP_BRANCH="main"
    KSU_DIR="KernelSU"
    KSU_LABEL="ReSukiSU"
    KSU_DISCORD_LABEL="ReSukiSU"
    SUSFS_KSU_INTERNAL_PATCH_DESC=""
    SUSFS_BUILTIN=0
else
    KSU_DIR=""
    KSU_LABEL="None"
    KSU_DISCORD_LABEL="Variant"
    NO_SUSFS=1
    SUSFS_BUILTIN=0
fi

# -------- Discord Webhook Configuration --------
WEBHOOK_FILE="$(pwd)/.discord_webhook"
if [[ -f "$WEBHOOK_FILE" ]]; then
    DISCORD_WEBHOOK_URL=$(cat "$WEBHOOK_FILE" | tr -d '\n' | tr -d '\r')
else
    DISCORD_WEBHOOK_URL=""
fi

# -------- Discord USER ID Configuration --------
USERID_FILE="$(pwd)/.discord_userid"
if [[ -f "$USERID_FILE" ]]; then
    DISCORD_USER_ID=$(cat "$USERID_FILE" | tr -d '\n' | tr -d '\r')
else
    DISCORD_USER_ID=""
fi

LOGFILE="$(pwd)/logs/build_${KSU_VARIANT}_$(date +%Y%m%d_%H%M%S).log"

if [[ ! -d "$(pwd)/logs" ]]; then
    mkdir -p "$(pwd)/logs"
fi

exec > >(trap '' INT TERM HUP; exec tee >(sed "s/$(printf '\033')\\[[0-9;]*m//g" >> "$LOGFILE")) 2>&1

_calc_runtime() {
    local start=${1:-0} end=${2:-0}
    if [[ -z "$start" || "$start" -eq 0 ]]; then
        echo "N/A"
    else
        if [[ -z "$end" || "$end" -eq 0 ]]; then
            end=$(date +%s)
        fi
        if [[ "$end" -lt "$start" ]]; then
            echo "N/A"
        else
            local runtime=$((end - start))
            printf "%02d:%02d:%02d" $((runtime / 3600)) $(((runtime % 3600) / 60)) $((runtime % 60))
        fi
    fi
}

send_discord_file() {
    local status="$1"
    local message="$2"
    local color="$3"
    
    if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
        return 0
    fi
    
    local config_time=$(_calc_runtime "${CONFIG_START:-0}" "${CONFIG_END:-0}")
    local patch_time=$(_calc_runtime "${PATCH_START:-0}" "${PATCH_END:-0}")
    local build_time=$(_calc_runtime "${BUILD_START:-0}" "${BUILD_END:-0}")
    
    local status_emoji="✅"
    if [[ "$status" == *"FAILED"* ]]; then
        status_emoji="❌"
    fi
    
    local content_str=""
    if [[ -n "$DISCORD_USER_ID" ]]; then
        content_str="\"content\":\"<@$DISCORD_USER_ID>\", "
    fi
    
    curl -s \
    -F "payload_json={
        $content_str
        \"embeds\":[{
          \"title\":\"${status_emoji} Kernel Build $status\",
          \"description\":\"$message\",
          \"color\":$color,
          \"fields\": [
            { \"name\": \"🐧 Kernel Version\", \"value\": \"${kernel_version:-N/A}\", \"inline\": true },
            { \"name\": \"📱 Android Version\", \"value\": \"${android_version:-N/A}\", \"inline\": true },
            { \"name\": \"🐧 ${KSU_DISCORD_LABEL} Version\", \"value\": \"${KSU_VERSION:-Vanilla}\", \"inline\": true },
            { \"name\": \"⏱️ Config Time\", \"value\": \"${config_time}\", \"inline\": true },
            { \"name\": \"⏱️ Patch Time\", \"value\": \"${patch_time}\", \"inline\": true },
            { \"name\": \"⏱️ Build Time\", \"value\": \"${build_time}\", \"inline\": true }
          ]
    }]}" \
    -F "file1=@$LOGFILE" \
    "$DISCORD_WEBHOOK_URL" >/dev/null
}

on_error() {
    send_discord_file "FAILED" "Kernel build failed at line $1 ⚠️" 16711680
}

trap 'on_error $LINENO' ERR


# -------- Configuration / defaults --------
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$(realpath "$SCRIPT_DIR/patches")"
KERNEL_PATCHES="$(realpath "$PATCHES/kernel_patches")"
ZEROMOUNT_PATCHES="$(realpath "$PATCHES/zeromount")"
DEFAULT_KERNEL_DIR="$(find . -maxdepth 1 -type d -name "kernel-*" | head -n1)"
DEFAULT_DEFCONFIG="arch/arm64/configs/a24_defconfig"
OTHER_DEFCONFIG="arch/arm64/configs/a24_defconfig"
DEFAULT_OUT="../out/target/product/a24/obj/KERNEL_OBJ"
KSU_VERSION="N/A"
MIN_VERSION="5.16"

pushd "$DEFAULT_KERNEL_DIR" > /dev/null
KERNELVERSION="$(make -s kernelversion)"
android_version=$(grep -m1 '^BRANCH=' ./build.config.common | awk -F= '{print $2}' | awk -F- '{print $1}')
popd > /dev/null

kernel_version=$(echo "$KERNELVERSION" | cut -d. -f1,2)

RED="\e[1;31m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
RESET="\e[0m"

print_msg() {
    local color="$1"; shift
    printf "%b%s%b\n" "${color}" "$*" "${RESET}"
}

_log_handler() {
    local color="$1"
    local level="$2"
    shift 2
    
    local nl=""
    [[ "$1" == "-n" ]] && { nl="\n"; shift; }
    
    printf "${nl}%b[%s] %s%b\n" "${color}" "${level}" "$*" "${RESET}"
}

info() { _log_handler "${GREEN}"  "INFO"  "$@"; }
warn() { _log_handler "${YELLOW}" "WARN"  "$@"; }
err()  { _log_handler "${RED}"    "ERROR" "$@"; }

print_msg "$GREEN" " - Build script for Samsung kernel image - "
print_msg "$RED" "       by poqdavid "

_ts() { date +%s; }
_print_runtime() {
    local label=$1 start=$2 end=$3
    local runtime_str=$(_calc_runtime "$start" "$end")
    if [[ "$runtime_str" == "N/A" ]]; then
        printf "%b%s: skipped%b\n" "${YELLOW}" "$label" "${RESET}"
    else
        printf "%b%s: %s%b\n" "${GREEN}" "$label" "$runtime_str" "${RESET}"
    fi
}

KERNEL_DIR="$DEFAULT_KERNEL_DIR"
OUT_DIR="$DEFAULT_OUT"
NO_CLEAN=0
NO_PATCH=0
NO_SUSFS=0
BUILD_ONLY=0
CLEAN_ONLY=0
JOBS=""
VERBOSE=0

info -n "Using kernel source: $KERNEL_DIR"
info -n "Using output directory: $OUT_DIR"

if [[ "$KSU_VARIANT" != "none" ]]; then
    info -n "Using KernelSU variant: $KSU_LABEL (./$KSU_DIR)"
else
    info -n "KernelSU variant: None (Vanilla kernel with optimizations)"
fi

info -n "Kernel version: $kernel_version"
info -n "Android version: $android_version"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-dir) KERNEL_DIR="$2"; shift 2;;
        --out-dir) OUT_DIR="$2"; shift 2;;
        --ksu) shift;;
        --ksun) shift;;
        --resukisu) shift;;
        --no-clean) NO_CLEAN=1; shift;;
        --no-patch) NO_PATCH=1; shift;;
        --no-susfs) NO_SUSFS=1; shift;;
        --build-only) BUILD_ONLY=1; shift;;
        --clean) CLEAN_ONLY=1; shift;;
        -j*) JOBS="${1#-j}"; [[ -z "$JOBS" ]] && { JOBS="$2"; shift; }; shift;;
        --verbose) VERBOSE=1; shift;;
        --help|-h)
      cat <<EOF
$SCRIPT_NAME - improved kernel build helper

Options:
  --kernel-dir DIR     Path to kernel source (default: ${DEFAULT_KERNEL_DIR})
  --out-dir DIR        Output directory for build artifacts (default: ${DEFAULT_OUT})
  --ksu                Build against upstream KernelSU (main branch)
  --ksun               Build against KernelSU-Next (dev branch)
  --resukisu           Build against ReSukiSU (main branch, built-in SUSFS hooks)
  --no-clean           Skip running clean_build.sh
  --no-patch           Skip patching steps / KernelSU setup
  --no-susfs           Skip SUSFS related config & patches
  --build-only         Skip config & patch steps; just run the build
  --clean              Only run the clean step
  --jobs N, -j N       Pass N to the build (if supported)
  --verbose            Print extra debug info
  --help, -h           Show this help
EOF
            exit 0
        ;;
        *)
            err "Unknown arg: $1"
            exit 2
        ;;
    esac
done

if [[ $VERBOSE -eq 1 ]]; then set -x; fi

export LTO=thin
export ARCH=arm64
export PLATFORM_VERSION=12
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-"
export OUT_DIR="$OUT_DIR"
export DIST_DIR="$OUT_DIR"
export BUILD_CONFIG="$OUT_DIR/build.config"
export LD=ld.lld
export HOSTLD=ld.lld
export AR=llvm-ar
export NM=llvm-nm

if [[ -n "$JOBS" ]]; then
    export MAKEFLAGS="-j$JOBS"
fi

CMDMISSING=0
require_cmds=(bash sed awk find git patch curl printf)

PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN=python3
else
    require_cmds+=(python3)
fi

for c in "${require_cmds[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
        err "Required command '$c' not found."
        CMDMISSING=1
    fi
done

if [ $CMDMISSING -eq 1 ]; then
    echo "--------------------------------------------------"
    echo "Please install the missing packages and try again."
    exit 2
fi

CONFIG_START=0; CONFIG_END=0
PATCH_START=0; PATCH_END=0
BUILD_START=0; BUILD_END=0

GENERIC_LD_LINK=""
GENERIC_LD_PREV=""

ensure_generic_ld() {
    local build_root clang_bin bin_dir lld_path
    build_root="$(realpath "$KERNEL_DIR/../kernel")"
    
    clang_bin="$(grep -m1 '^CLANG_PREBUILT_BIN=' "$KERNEL_DIR/build.config.common" 2>/dev/null | cut -d= -f2- || true)"
    bin_dir="$build_root/$clang_bin"
    
    if [[ -z "$clang_bin" || ! -e "$bin_dir/ld.lld" ]]; then
        lld_path="$(find -L "$build_root/prebuilts-master" -name 'ld.lld' -print -quit 2>/dev/null || true)"
        if [[ -z "$lld_path" ]]; then
            warn -n "No ld.lld found under $build_root/prebuilts-master; skipping generic ld symlink."
            return 0
        fi
        bin_dir="$(dirname "$lld_path")"
    fi
    
    if [[ -e "$bin_dir/ld" && ! -L "$bin_dir/ld" ]]; then
        info -n "A real 'ld' already exists in $bin_dir; leaving it alone."
        elif [[ "$(readlink "$bin_dir/ld" 2>/dev/null)" == "ld.lld" ]]; then
        info -n "ld -> ld.lld already present in $bin_dir"
        if ! git -C "$bin_dir" ls-files --error-unmatch ld >/dev/null 2>&1; then
            GENERIC_LD_LINK="$bin_dir/ld"
        fi
    else
        GENERIC_LD_PREV="$(readlink "$bin_dir/ld" 2>/dev/null || true)"
        ln -sfn ld.lld "$bin_dir/ld"
        GENERIC_LD_LINK="$bin_dir/ld"
        info -n "Symlinked ld -> ld.lld in $bin_dir"
    fi
}

remove_generic_ld() {
    local link="${GENERIC_LD_LINK:-}"
    [[ -n "$link" ]] || return 0
    GENERIC_LD_LINK=""
    
    if [[ -L "$link" && "$(readlink "$link" 2>/dev/null)" == "ld.lld" ]]; then
        rm -f "$link" || true
        if [[ -n "${GENERIC_LD_PREV:-}" ]]; then
            ln -s "$GENERIC_LD_PREV" "$link" || true
            info -n "Restored ld -> $GENERIC_LD_PREV in $(dirname "$link")" || true
        else
            info -n "Removed ld -> ld.lld symlink from $(dirname "$link")" || true
        fi
    fi
}

cleanup() {
    remove_generic_ld
    echo " "
    _print_runtime "Config runtime" "$CONFIG_START" "$CONFIG_END"
    _print_runtime "Patch runtime" "$PATCH_START" "$PATCH_END"
    _print_runtime "Build runtime" "$BUILD_START" "$BUILD_END"
}
trap cleanup EXIT

on_cancel() {
    trap - INT TERM HUP
    trap - ERR
    echo " "
    warn "Build canceled (SIG$1)."
    exit "$2"
}
trap 'on_cancel INT 130' INT
trap 'on_cancel TERM 143' TERM
trap 'on_cancel HUP 129' HUP

if [[ $NO_CLEAN -eq 0 ]]; then
    
    info -n "Started cleaning up..."
    
    git restore kernel-5.10/
    git clean -fd kernel-5.10/
    rm -rf kernel-5.10/KernelSU
    rm -rf kernel-5.10/KernelSU-Next
    rm -rf kernel-5.10/Baseband-guard
    rm -rf out
    
    info "Finsished cleaning up..."
    
    if [[ $CLEAN_ONLY -eq 1 ]]; then
        exit 0
    fi
fi

ensure_generic_ld

info -n "Applying Python3 support patch..."
patch -p1 --forward < ./patches/enable-python3-support.patch || true

gen_metadata(){
    
    info -n "Configuring Kernel metadata..."
    pushd "$KERNEL_DIR" > /dev/null
    sed -i '$s|echo "\$res"|echo "-android12-9-31117096"|' ./scripts/setlocalversion
    perl -pi -e 's{UTS_VERSION="\$\(echo \$UTS_VERSION \$CONFIG_FLAGS \$TIMESTAMP \| cut -b -\$UTS_LEN\)"}{UTS_VERSION="#1 SMP PREEMPT Thu Jul 31 08:40:06 UTC 2025"}' ./scripts/mkcompile_h
    sed -i 's/-dirty//' ./scripts/setlocalversion
    
    info -n "Generating build configs..."
    python3 scripts/gen_build_config.py --kernel-defconfig a24_defconfig --kernel-defconfig-overlays entry_level.config -m user -o $OUT_DIR/build.config
    if [[ $BUILD_ONLY -eq 0 ]]; then
        info -n "Applying fake_config.patch..."
        patch -p1 --forward < $PATCHES/fake_config.patch || true
    fi
    popd > /dev/null
    
}

if [[ $BUILD_ONLY -eq 0 ]]; then
    CONFIG_START=$(_ts)
    info -n "Modifying configs..."
    CONFIG_TOOL="./${KERNEL_DIR}/scripts/config"
    DEFAULTDEFCONFIG="./${KERNEL_DIR}/${DEFAULT_DEFCONFIG}"
    OTHERDEFCONFIG="./${KERNEL_DIR}/${OTHER_DEFCONFIG}"
    
    for DEFCONFIG in "$DEFAULTDEFCONFIG" "$OTHERDEFCONFIG"; do
        info -n "$DEFCONFIG"
        
        info -n "Settings Samsung & Security configs..."
        $CONFIG_TOOL --file $DEFCONFIG \
        --set-val UH n \
        --set-val RKP n \
        --set-val KDP n \
        --set-val SECURITY_DEFEX n \
        --set-val INTEGRITY n \
        --set-val FIVE n \
        --set-val TRIM_UNUSED_KSYMS n \
        --set-val PROCA n \
        --set-val PROCA_GKI_10 n \
        --set-val PROCA_S_OS n \
        --set-val PROCA_CERTIFICATES_XATTR n \
        --set-val PROCA_CERT_ENG n \
        --set-val PROCA_CERT_USER n \
        --set-val GAF_V6 n \
        --set-val FIVE n \
        --set-val FIVE_CERT_USER n \
        --set-val FIVE_DEFAULT_HASH n \
        --set-val UH_RKP n \
        --set-val UH_LKMAUTH n \
        --set-val UH_LKM_BLOCK n \
        --set-val RKP_CFP_JOPP n \
        --set-val RKP_CFP n \
        --set-val KDP_CRED n \
        --set-val KDP_NS n \
        --set-val KDP_TEST n \
        --set-val RKP_CRED n \
        --set-val MODULES y \
        --set-val MODULE_FORCE_LOAD y \
        --set-val MODULE_UNLOAD y \
        --set-val MODULE_FORCE_UNLOAD y \
        --set-val MODVERSIONS y \
        --set-val MODULE_SRCVERSION_ALL n \
        --set-val MODULE_SIG n \
        --set-val MODULE_COMPRESS n
        
        info -n "Setting optimization configs..."
        
        info "Adding BBG support..."
        $CONFIG_TOOL --file $DEFCONFIG \
        --set-val BBG y
        
        info "Adding BBR3 Support Support..."
        $CONFIG_TOOL --file $DEFCONFIG \
        --set-val TCP_CONG_ADVANCED y \
        --set-val TCP_CONG_BBR y \
        --set-val NET_SCH_FQ y \
        --set-val NET_SCH_FQ_CODEL y \
        --set-val TCP_CONG_CUBIC y \
        --set-val TCP_CONG_BIC n \
        --set-val TCP_CONG_WESTWOOD n \
        --set-val TCP_CONG_HTCP n \
        --set-val NET_SCH_CAKE y \
        --set-val NET_SCH_PIE y \
        --set-val NET_SCH_FQ_PIE y \
        --set-val TCP_CONG_BBR3 y \
        --set-val DEFAULT_BBR3 y \
        --set-val DEFAULT_BIC n \
        --set-str DEFAULT_TCP_CONG "bbr" \
        --set-val DEFAULT_RENO n \
        --set-val DEFAULT_CUBIC n \
        
        info "Adding IP SET & IPv6_NAT Support..."
        $CONFIG_TOOL --file $DEFCONFIG \
        --set-val IP_SET y \
        --set-val IP_SET_MAX 65534 \
        --set-val IP_SET_BITMAP_IP y \
        --set-val IP_SET_BITMAP_IPMAC y \
        --set-val IP_SET_BITMAP_PORT y \
        --set-val IP_SET_HASH_IP y \
        --set-val IP_SET_HASH_IPMARK y \
        --set-val IP_SET_HASH_IPPORT y \
        --set-val IP_SET_HASH_IPPORTIP y \
        --set-val IP_SET_HASH_IPPORTNET y \
        --set-val IP_SET_HASH_IPMAC y \
        --set-val IP_SET_HASH_MAC y \
        --set-val IP_SET_HASH_NETPORTNET y \
        --set-val IP_SET_HASH_NET y \
        --set-val IP_SET_HASH_NETNET y \
        --set-val IP_SET_HASH_NETPORT y \
        --set-val IP_SET_HASH_NETIFACE y \
        --set-val IP_SET_LIST_SET y \
        --set-val NETFILTER_XT_MATCH_ADDRTYPE y \
        --set-val NETFILTER_XT_SET y \
        --set-val IP_NF_TARGET_TTL y \
        --set-val IP6_NF_TARGET_HL y \
        --set-val IP6_NF_MATCH_HL y \
        --set-val IP6_NF_NAT y \
        --set-val NF_NAT_IPV6 y
            done
fi


# ========================================
# GENERATE BUILD CONFIG + BUILD KERNEL
# ========================================

gen_metadata

info -n "Building kernel..."
BUILD_START=$(_ts)

pushd "$KERNEL_DIR" > /dev/null

# This is the actual kernel build command
make -j"$(nproc)" O="$OUT_DIR" ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    LLVM=1 LLVM_IAS=1 \
    a24_defconfig

make -j"$(nproc)" O="$OUT_DIR" ARCH=arm64 \
    CROSS_COMPILE=aarch64-linux-gnu- \
    LLVM=1 LLVM_IAS=1

popd > /dev/null

BUILD_END=$(_ts)

info -n "Kernel build finished."
