#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
set -euo pipefail

# -------- Configuration / defaults --------
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$(realpath "$SCRIPT_DIR/patches")"
KERNEL_PATCHES="$(realpath "$PATCHES/kernel_patches")"
DEFAULT_KERNEL_DIR="$(find . -maxdepth 1 -type d -name "kernel-*" | head -n1)"
DEFAULT_DEFCONFIG="arch/arm64/configs/a15_00_defconfig"
OTHER_DEFCONFIG="arch/arm64/configs/a15_defconfig"
DEFAULT_OUT="../out/target/product/a15/obj/KERNEL_OBJ"
MIN_VERSION="5.16"

pushd "$DEFAULT_KERNEL_DIR" > /dev/null
KERNELVERSION="$(make -s kernelversion)"
android_version=$(grep -m1 '^BRANCH=' ./build.config.common | awk -F= '{print $2}' | awk -F- '{print $1}')
popd > /dev/null

kernel_version=$(echo "$KERNELVERSION" | cut -d. -f1,2)

# -------- Colors & logging --------
RED="\e[1;31m"; GREEN="\e[1;32m"; YELLOW="\e[1;33m"; RESET="\e[0m"
print_msg() { local color="$1"; shift; printf "%b%s%b\n" "${color}" "$*" "${RESET}"; }
_log_handler() {
    local color="$1" level="$2"; shift 2
    local nl=""; [[ "$1" == "-n" ]] && { nl="\n"; shift; }
    printf "${nl}%b[%s] %s%b\n" "${color}" "${level}" "$*" "${RESET}"
}
info() { _log_handler "${GREEN}"  "INFO"  "$@"; }
warn() { _log_handler "${YELLOW}" "WARN"  "$@"; }
err()  { _log_handler "${RED}"    "ERROR" "$@"; }

print_msg "$GREEN" " - Build script for Samsung kernel image - "
print_msg "$RED" "       by poqdavid "

_ts() { date +%s; }

# -------- CLI parsing --------
KERNEL_DIR="$DEFAULT_KERNEL_DIR"
OUT_DIR="$DEFAULT_OUT"
NO_CLEAN=0; NO_PATCH=0; BUILD_ONLY=0; CLEAN_ONLY=0; JOBS=""; VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel-dir) KERNEL_DIR="$2"; shift 2;;
        --out-dir) OUT_DIR="$2"; shift 2;;
        --no-clean) NO_CLEAN=1; shift;;
        --no-patch) NO_PATCH=1; shift;;
        --build-only) BUILD_ONLY=1; shift;;
        --clean) CLEAN_ONLY=1; shift;;
        -j*) JOBS="${1#-j}"; [[ -z "$JOBS" ]] && { JOBS="$2"; shift; }; shift;;
        --verbose) VERBOSE=1; shift;;
        --help|-h) echo "Usage: $0 [-j N]"; exit 0;;
        *) err "Unknown arg: $1"; exit 2;;
    esac
done

if [[ $VERBOSE -eq 1 ]]; then set -x; fi

export LTO=thin ARCH=arm64 PLATFORM_VERSION=12
export CROSS_COMPILE="aarch64-linux-gnu-"
export CROSS_COMPILE_COMPAT="arm-linux-gnueabi-"
export OUT_DIR="$OUT_DIR" DIST_DIR="$OUT_DIR" BUILD_CONFIG="$OUT_DIR/build.config"
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm
if [[ -n "$JOBS" ]]; then export MAKEFLAGS="-j$JOBS"; fi

# -------- Preconditions --------
CMDMISSING=0
require_cmds=(bash sed awk find git patch curl printf)
for c in "${require_cmds[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then err "Required command '$c' not found."; CMDMISSING=1; fi
done
if [ $CMDMISSING -eq 1 ]; then echo "Please install missing packages."; exit 2; fi

# -------- Generic ld symlink --------
ensure_generic_ld() {
    local build_root clang_bin bin_dir lld_path
    build_root="$(realpath "$KERNEL_DIR/../kernel")"
    clang_bin="$(grep -m1 '^CLANG_PREBUILT_BIN=' "$KERNEL_DIR/build.config.common" 2>/dev/null | cut -d= -f2- || true)"
    bin_dir="$build_root/$clang_bin"
    if [[ -z "$clang_bin" || ! -e "$bin_dir/ld.lld" ]]; then
        lld_path="$(find -L "$build_root/prebuilts-master" -name 'ld.lld' -print -quit 2>/dev/null || true)"
        if [[ -z "$lld_path" ]]; then return 0; fi
        bin_dir="$(dirname "$lld_path")"
    fi
    if [[ -e "$bin_dir/ld" && ! -L "$bin_dir/ld" ]]; then info -n "Real ld exists."
    elif [[ "$(readlink "$bin_dir/ld" 2>/dev/null)" == "ld.lld" ]]; then info -n "ld -> ld.lld present."
    else
        ln -sfn ld.lld "$bin_dir/ld"
        info -n "Symlinked ld -> ld.lld."
    fi
}
ensure_generic_ld

# -------- Clean Step --------
if [[ $NO_CLEAN -eq 0 ]]; then
    info -n "Cleaning up..."
    git restore kernel-5.10/ 2>/dev/null || true
    git clean -fd kernel-5.10/ 2>/dev/null || true
    rm -rf kernel-5.10/NoMount out
    info "Clean done."
    if [[ $CLEAN_ONLY -eq 1 ]]; then exit 0; fi
fi

info -n "Applying Python3 support patch..."
patch -p1 --forward < ./patches/enable-python3-support.patch || true

gen_metadata(){
    info -n "Configuring Kernel metadata..."
    pushd "$KERNEL_DIR" > /dev/null
    sed -i '$s|echo "\$res"|echo "-android12-9-31117096"|' ./scripts/setlocalversion
    perl -pi -e 's{UTS_VERSION="\$\(echo \$UTS_VERSION \$CONFIG_FLAGS \$TIMESTAMP \| cut -b -\$UTS_LEN\)"}{UTS_VERSION="#1 SMP PREEMPT Thu Jul 31 08:40:06 UTC 2025"}' ./scripts/mkcompile_h
    sed -i 's/-dirty//' ./scripts/setlocalversion
    info -n "Generating build configs..."
    python3 scripts/gen_build_config.py --kernel-defconfig a15_00_defconfig --kernel-defconfig-overlays entry_level.config -m user -o $OUT_DIR/build.config
    if [[ $BUILD_ONLY -eq 0 ]]; then
        patch -p1 --forward < $PATCHES/fake_config.patch || true
    fi
    popd > /dev/null
}

# -------- Config Modifications --------
if [[ $BUILD_ONLY -eq 0 ]]; then
    info -n "Modifying configs..."
    CONFIG_TOOL="./${KERNEL_DIR}/scripts/config"
    DEFAULTDEFCONFIG="./${KERNEL_DIR}/${DEFAULT_DEFCONFIG}"
    OTHERDEFCONFIG="./${KERNEL_DIR}/${OTHER_DEFCONFIG}"
    
    for DEFCONFIG in "$DEFAULTDEFCONFIG" "$OTHERDEFCONFIG"; do
        info -n "$DEFCONFIG"
        
        info -n "Samsung security disables..."
        $CONFIG_TOOL --file $DEFCONFIG \
        --set-val UH n --set-val RKP n --set-val KDP n --set-val SECURITY_DEFEX n \
        --set-val INTEGRITY n --set-val FIVE n --set-val TRIM_UNUSED_KSYMS n \
        --set-val PROCA n --set-val PROCA_GKI_10 n --set-val PROCA_S_OS n \
        --set-val PROCA_CERTIFICATES_XATTR n --set-val PROCA_CERT_ENG n --set-val PROCA_CERT_USER n \
        --set-val GAF_V6 n --set-val FIVE_CERT_USER n --set-val FIVE_DEFAULT_HASH n \
        --set-val UH_RKP n --set-val UH_LKMAUTH n --set-val UH_LKM_BLOCK n \
        --set-val RKP_CFP_JOPP n --set-val RKP_CFP n --set-val KDP_CRED n \
        --set-val KDP_NS n --set-val KDP_TEST n --set-val RKP_CRED n \
        --set-val MODULES y --set-val MODULE_FORCE_LOAD y --set-val MODULE_UNLOAD y \
        --set-val MODULE_FORCE_UNLOAD y --set-val MODVERSIONS y \
        --set-val MODULE_SRCVERSION_ALL n --set-val MODULE_SIG n --set-val MODULE_COMPRESS n
        
        info -n "BBG support..."
        $CONFIG_TOOL --file $DEFCONFIG --set-val BBG y
        
        info -n "BBRv3 support..."
        $CONFIG_TOOL --file $DEFCONFIG \
        --set-val TCP_CONG_ADVANCED y --set-val TCP_CONG_BBR3 y --set-val DEFAULT_BBR3 y \
        --set-str DEFAULT_TCP_CONG "bbr" --set-val NET_SCH_FQ y --set-val NET_SCH_FQ_CODEL y \
        --set-val TCP_CONG_CUBIC y --set-val TCP_CONG_BIC n --set-val TCP_CONG_WESTWOOD n \
        --set-val TCP_CONG_HTCP n --set-val NET_SCH_CAKE y --set-val NET_SCH_PIE y \
        --set-val NET_SCH_FQ_PIE y --set-val DEFAULT_RENO n --set-val DEFAULT_CUBIC n
        
        info -n "IP SET & IPv6 NAT..."
        $CONFIG_TOOL --file $DEFCONFIG \
        --set-val IP_SET y --set-val IP_SET_MAX 65534 \
        --set-val IP_SET_BITMAP_IP y --set-val IP_SET_BITMAP_IPMAC y --set-val IP_SET_BITMAP_PORT y \
        --set-val IP_SET_HASH_IP y --set-val IP_SET_HASH_IPMARK y --set-val IP_SET_HASH_IPPORT y \
        --set-val IP_SET_HASH_IPPORTIP y --set-val IP_SET_HASH_IPPORTNET y --set-val IP_SET_HASH_IPMAC y \
        --set-val IP_SET_HASH_MAC y --set-val IP_SET_HASH_NETPORTNET y --set-val IP_SET_HASH_NET y \
        --set-val IP_SET_HASH_NETNET y --set-val IP_SET_HASH_NETPORT y --set-val IP_SET_HASH_NETIFACE y \
        --set-val IP_SET_LIST_SET y --set-val NETFILTER_XT_MATCH_ADDRTYPE y --set-val NETFILTER_XT_SET y \
        --set-val IP_NF_TARGET_TTL y --set-val IP6_NF_TARGET_HL y --set-val IP6_NF_MATCH_HL y \
        --set-val IP6_NF_NAT y --set-val NF_NAT_IPV6 y --set-val IP6_NF_TARGET_MASQUERADE y
        
        info -n "CRYPTO_LZO support..."
        $CONFIG_TOOL --file $DEFCONFIG --set-val CRYPTO_LZO y
        
        # No KernelSU configs — vanilla kernel
        info -n "Skipping KernelSU configs (vanilla kernel)..."
        
        if grep -q '^CONFIG_LSM=' "$DEFCONFIG"; then
            info -n "Adding baseband_guard to CONFIG_LSM..."
            sed -i '/^CONFIG_LSM=/ s/"$/,baseband_guard"/' "$DEFCONFIG"
        fi
    done
    
    gen_metadata
fi

# -------- Patching / Setup --------
if [[ $NO_PATCH -eq 0 && $BUILD_ONLY -eq 0 ]]; then
    pushd "$KERNEL_DIR" > /dev/null
    
    # NoMount setup
    info -n "Setting up NoMount (dev branch)..."
    curl -LSs "https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh" | bash -s dev
    info -n "NoMount setup complete."
    
    # Common kernel optimization patches
    info -n "Applying common kernel optimization patches..."
    patch -p1 --forward < "$KERNEL_PATCHES/common/optimized_mem_operations.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/file_struct_8bytes_align.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/reduce_cache_pressure.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/mem_opt_prefetch.patch" || true
    patch -p1 --forward < "$PATCHES/zram-kernel-fixes_android12_5.10.patch" || true
    patch -p1 --forward < "$PATCHES/optimise_noneon_memcmp_android12_5.10.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/minimise_wakeup_time.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/int_sqrt.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/force_tcp_nodelay.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/reduce_gc_thread_sleep_time.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/add_timeout_wakelocks_globally.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/f2fs_reduce_congestion.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/reduce_freeze_timeout.patch" || true
    
    info -n "Applying clear_page_16bytes_align patch..."
    if [ "$(printf '%s\n' "${kernel_version}" "$MIN_VERSION" | sort -V | head -n1)" = "${kernel_version}" ]; then
        patch -p1 --forward < "$KERNEL_PATCHES/common/clear_page_16bytes_align.patch" || true
    else
        cat "$KERNEL_PATCHES/common/clear_page_16bytes_align.patch" | sed -e 's/SYM_FUNC_START_PI(clear_page)/SYM_FUNC_START_PI(__pi_clear_page)/' | patch -p1 -F3 --forward || true
    fi
    
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/add_limitation_scaling_min_freq.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/re_write_limitation_scaling_min_freq.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/adjust_cpu_scan_order.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/avoid_extra_s2idle_wake_attempts.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/disable_cache_hot_buddy.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/f2fs_enlarge_min_fsync_blocks.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/increase_ext4_default_commit_age.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/increase_sk_mem_packets.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/reduce_pci_pme_wakeups.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/silence_irq_cpu_logspam.patch" || true
    patch -p1 -F3 --forward < "$KERNEL_PATCHES/common/silence_system_logspam.patch" || true
    patch -p1 --forward < "$KERNEL_PATCHES/common/use_unlikely_wrap_cpufreq.patch" || true
    
    # BBRv3 patches (3 of them)
    info -n "Applying BBRv3 patch..."
    patch -p1 < "$KERNEL_PATCHES/common/bbrv3/0001-net-tcp-backport-BBRv3-to-${android_version}-${kernel_version}.patch" || true
    
    if [ "${android_version}" = "android12" ] && [ "${kernel_version}" = "5.10" ]; then
        if ! grep -qF 'int proc_dou8vec_minmax(' ./include/linux/sysctl.h; then
            info -n "Applying BBRv3 sysctl helper patches..."
            patch -p1 < "$KERNEL_PATCHES/common/bbrv3/sysctl_add_proc_dou8vec_minmax.patch" || true
            patch -p1 < "$KERNEL_PATCHES/common/bbrv3/sysctl_fix_data-races_in_proc_dou8vec_minmax.patch" || true
        fi
    fi
    
    # BBG setup
    info -n "Setting up Baseband Guard..."
    curl -LSs https://github.com/poqdavid/Baseband-guard/raw/main/setup.sh | bash
    sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig
    
    # Unicode bypass fix
    if [[ "$kernel_version" == 6.* ]]; then
        patch -p1 < "$KERNEL_PATCHES/common/unicode_bypass_fix_6.1+.patch" || true
    else
        patch -p1 < "$KERNEL_PATCHES/common/unicode_bypass_fix_6.1-.patch" || true
    fi
    
    popd > /dev/null
fi

# -------- Build --------
info -n "Starting Kernel Build..."
pushd "$KERNEL_DIR" > /dev/null
cd ../kernel
./build/build.sh
popd > /dev/null
info -n "Build completed successfully."
