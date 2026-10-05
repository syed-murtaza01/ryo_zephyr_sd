#!/bin/bash
# =============================================================================
# Agilex 5 HPS Roll-Your-Own Zephyr Example Script
# =============================================================================
#
# PURPOSE:
# This script builds an SD card boot image for Altera Agilex 5 HPS systems.
# The SD card image produced from this script will demonstrate the HPS first boot flow
# and no configuration of FPGA core fabric will take place in ATF or Zephyr.
#
# USAGE:
#   ./build_zephyr.sh
#
# OUTPUT:
#   sdcard.img - Ready to write to SD card
#
# REQUIREMENTS:
# - Linux host system (Ubuntu 22.04+ recommended)
# - Internet connection for downloading sources
# - ~20GB free disk space
# - guestfs-tools for SD image creation
# - Zephyr dependencies as listed
#    on https://docs.zephyrproject.org/latest/develop/getting_started/installation_linux.html
#
# =============================================================================

set -e  # Exit on any error

# =============================================================================
# CONFIGURATION
# =============================================================================

echo "======================================================================"
echo "   Agilex 5 HPS SD Card Boot Flow Builder (Simplified)"
echo "======================================================================"

# Build configuration
OUTPUT_DIR="./build_output"
JOBS=$(nproc)

declare -r ZCFG_FILE="zcfg.sh"

# Component URLs and settings
# Using the musl compiler to make a tight, statically linked Linux environment
declare -r TOOLCHAIN_URL="https://github.com/cross-tools/musl-cross/releases/download/20250929/aarch64-unknown-linux-musl.tar.xz"
declare -r TOOLCHAIN_DIR="aarch64-unknown-linux-musl"

declare -r SZ_KB=1024
declare -r SZ_MB=$((${SZ_KB}*${SZ_KB}))
declare -r SZ_GB=$((${SZ_MB}*${SZ_KB}))

# SD image: MBR + A2 (raw FIP) + FAT. No ext4.
declare -r SDCARD_IMG_SIZE=$((64*${SZ_MB}))
declare -r SDCARD_A2_SIZE=$((16*${SZ_MB}))

# =============================================================================
# HELPERS AND FUNCTIONS
# =============================================================================
# download <url> <local file name>
function download() {

    local archive="${2}"
    local url="${1}"
    local err=0

    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate --progress=bar:force:noscroll -O "${archive}" "${url}"
	err=$?
    elif command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar -o "${archive}" "${url}"
	err=$?
    else
        echo "ERROR: Neither wget nor curl found. Please install one of them."
        return 1
    fi  

    return ${err}
}

# Install Zephyr SDK + aarch64-zephyr-elf toolchain.  Call from ${ZEPHYR_DIR}/zephyr
# (west workspace root).  west may install to sdk/ or sdk/zephyr-sdk-<ver>/.
ensure_zephyr_sdk() {
    local want_ver sdk_base sdk_dir host zephyr_tc gcc toolchain_tar url

    zephyr_tc=aarch64-zephyr-elf
    want_ver="$(cat zephyr/SDK_VERSION)"
    sdk_base="$(cd .. && pwd)/sdk"

    resolve_sdk_dir() {
        if [[ -f "${sdk_base}/zephyr-sdk-${want_ver}/setup.sh" ]]; then
            sdk_dir="${sdk_base}/zephyr-sdk-${want_ver}"
        elif [[ -f "${sdk_base}/setup.sh" ]]; then
            sdk_dir="${sdk_base}"
        else
            sdk_dir="${sdk_base}/zephyr-sdk-${want_ver}"
        fi
        gcc="${sdk_dir}/${zephyr_tc}/bin/${zephyr_tc}-gcc"
    }

    case "$(uname -m)" in
        x86_64)  host=linux-x86_64 ;;
        aarch64) host=linux-aarch64 ;;
        *)
            echo "ERROR: unsupported host arch $(uname -m) for Zephyr SDK" >&2
            exit 1
            ;;
    esac
    toolchain_tar="toolchain_${host}_${zephyr_tc}.tar.xz"
    url="https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v${want_ver}/${toolchain_tar}"

    resolve_sdk_dir
    if [[ -x "${gcc}" ]]; then
        echo "Zephyr SDK ${want_ver} already installed: ${sdk_dir}"
        export ZEPHYR_SDK_INSTALL_DIR="${sdk_dir}"
        return 0
    fi

    echo "[STEP] Installing Zephyr SDK ${want_ver}..."

    if [[ ! -f "${sdk_base}/setup.sh" && ! -f "${sdk_base}/zephyr-sdk-${want_ver}/setup.sh" ]]; then
        echo "Running west sdk install -> ${sdk_base}"
        if ! west sdk install -b "${sdk_base}" -d "${sdk_base}" -t "${zephyr_tc}"; then
            resolve_sdk_dir
            if [[ ! -f "${sdk_dir}/setup.sh" ]]; then
                echo "ERROR: west sdk install failed; no SDK under ${sdk_base}" >&2
                exit 1
            fi
            echo "west sdk install failed but SDK dir exists; finishing setup..."
        fi
    else
        resolve_sdk_dir
        echo "SDK shell already at ${sdk_dir}; skipping west extract"
    fi

    resolve_sdk_dir
    if [[ -x "${gcc}" ]]; then
        echo "Zephyr SDK ${want_ver} ready (west/setup already installed toolchain): ${sdk_dir}"
        export ZEPHYR_SDK_INSTALL_DIR="${sdk_dir}"
        return 0
    fi

    # west sdk install ignores --install-dir when this version is already
    # registered in ~/.cmake/packages/Zephyr-sdk and reuses that tree.
    local reg entry cmake_dir root ver
    reg="${HOME}/.cmake/packages/Zephyr-sdk"
    if [[ -d "${reg}" ]]; then
        for entry in "${reg}"/*; do
            [[ -f "${entry}" ]] || continue
            cmake_dir="$(tr -d '\r' < "${entry}")"
            root="$(dirname "${cmake_dir}")"
            [[ -f "${root}/sdk_version" ]] || continue
            ver="$(tr -d '\r\n' < "${root}/sdk_version")"
            if [[ "${ver}" == "${want_ver}" ]]; then
                sdk_dir="${root}"
                gcc="${sdk_dir}/${zephyr_tc}/bin/${zephyr_tc}-gcc"
                echo "Using registered Zephyr SDK ${want_ver}: ${sdk_dir}"
                break
            fi
        done
    fi

    if [[ -x "${gcc}" ]]; then
        export ZEPHYR_SDK_INSTALL_DIR="${sdk_dir}"
        echo "Zephyr SDK ${want_ver} ready: ${ZEPHYR_SDK_INSTALL_DIR}"
        return 0
    fi

    if [[ ! -f "${sdk_dir}/setup.sh" ]]; then
        echo "ERROR: no setup.sh under ${sdk_base} or ${sdk_base}/zephyr-sdk-${want_ver}" >&2
        exit 1
    fi

    echo "Running setup.sh -t ${zephyr_tc} -h -c in ${sdk_dir}"
    if ! ( cd "${sdk_dir}" && ./setup.sh -t "${zephyr_tc}" -h -c ); then
        echo "setup.sh failed; downloading ${toolchain_tar} into ${sdk_dir}..."
        if [[ ! -f "${sdk_dir}/${toolchain_tar}" ]]; then
            if ! download "${url}" "${sdk_dir}/${toolchain_tar}"; then
                echo "ERROR: failed to download ${toolchain_tar}" >&2
                exit 1
            fi
        fi
        ( cd "${sdk_dir}" && ./setup.sh -t "${zephyr_tc}" -h -c ) \
            || { echo "ERROR: setup.sh failed after toolchain download" >&2; exit 1; }
    fi

    resolve_sdk_dir
    if [[ ! -x "${gcc}" ]]; then
        echo "ERROR: Zephyr SDK incomplete (missing ${gcc})" >&2
        exit 1
    fi

    export ZEPHYR_SDK_INSTALL_DIR="${sdk_dir}"
    echo "Zephyr SDK ${want_ver} ready: ${ZEPHYR_SDK_INSTALL_DIR}"
}

# Two partitions: p1 type 0xa2 (raw FIP), p2 FAT. No ext4 / make_sdimage.sh.
create_sdcard_img() {
    local fip_file="${1}" sdcard_img="${2}"
    local a2_start=2048
    local a2_sectors=$((${SDCARD_A2_SIZE} / 512))
    local a2_end=$((${a2_start} + ${a2_sectors} - 1))
    local fat_start=$((${a2_end} + 1))
    local fat_end=$((${SDCARD_IMG_SIZE} / 512 - 1))

    if [[ $(stat -c %s "${fip_file}") -gt ${SDCARD_A2_SIZE} ]]; then
        echo "ERROR: fip.bin is larger than the A2 partition (${SDCARD_A2_SIZE} bytes)" >&2
        exit 1
    fi

    rm -f "${sdcard_img}"
    # If libguestfs fails under nested virt: export LIBGUESTFS_BACKEND=direct
    guestfish <<EOF
sparse ${sdcard_img} ${SDCARD_IMG_SIZE}
run
part-init /dev/sda mbr
part-add /dev/sda p ${a2_start} ${a2_end}
part-set-mbr-id /dev/sda 1 0xa2
part-add /dev/sda p ${fat_start} ${fat_end}
part-set-mbr-id /dev/sda 2 0x0b
mkfs vfat /dev/sda2
upload-offset ${fip_file} /dev/sda1 0
EOF
}

# =============================================================================
# BUILD PROCESS
# =============================================================================

if [ ! -f ${ZCFG_FILE} ] ; then 
    echo "error: config file ${ZCFG_FILE}: no such file" >&2
    exit 1
fi
source ${ZCFG_FILE}

echo "==============================================="
echo "[INFO] Configuration (from file ${ZCFG_FILE}:"
echo "ATF branch -s ${ATF_BRANCH}"
echo "Zephyr:"
echo " Branch: ${ZEPHYR_BRANCH}"
echo " Board:  ${ZEPHYR_BOARD}"
echo " Sample: ${ZEPHYR_SAMPLE}"
echo "==============================================="
echo

echo "[STEP] Setting up build environment (ATF)..."

# Create and enter build directory
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"

# Set environment variables
export ARCH=arm64
# export CROSS_COMPILE="${PWD}/${TOOLCHAIN_DIR}/bin/aarch64-unknown-linux-musl-"
# musl-cross host binaries need glibc >= 2.34, which this host lacks.
declare -r SITE_TC_BIN="/nfs/site/disks/psg_ctools_1/arm_gnu/linaro/aarch64/13.3/1/bin"
if [[ -x "${SITE_TC_BIN}/aarch64-none-linux-gnu-gcc" ]]; then
    export CROSS_COMPILE="${SITE_TC_BIN}/aarch64-none-linux-gnu-"
    export PATH="${SITE_TC_BIN}:${PATH}"
else
    export CROSS_COMPILE="${PWD}/${TOOLCHAIN_DIR}/bin/aarch64-unknown-linux-musl-"
fi

echo "Build directory: ${PWD}"
echo "Architecture: ${ARCH}"
echo "Cross compiler: ${CROSS_COMPILE}"

# =============================================================================
# DOWNLOAD AND SETUP TOOLCHAIN
# =============================================================================

echo "[STEP] Setting up ARM GNU toolchain..."

TOOLCHAIN_ARCHIVE="${TOOLCHAIN_DIR}.tar.xz"

# The site Linaro compiler is used when present. The musl-cross binaries need
# glibc >= 2.34, which is not available on the internal build hosts.
if [[ -x "${CROSS_COMPILE}gcc" && "${CROSS_COMPILE}" != *"unknown-linux-musl-"* ]]; then
    echo "Using site toolchain: ${CROSS_COMPILE}"
else
    if [[ ! -d "${TOOLCHAIN_DIR}" ]]; then
        # A failed wget -O leaves a zero-length file, which must not be reused.
        if [[ -f "${TOOLCHAIN_ARCHIVE}" ]] && ! xz -t "${TOOLCHAIN_ARCHIVE}" >/dev/null 2>&1; then
            echo "Removing invalid toolchain archive ${TOOLCHAIN_ARCHIVE}"
            rm -f "${TOOLCHAIN_ARCHIVE}"
        fi

        if [[ ! -f "${TOOLCHAIN_ARCHIVE}" ]]; then
            echo "Downloading ARM GNU toolchain..."
            if ! download "${TOOLCHAIN_URL}" "${TOOLCHAIN_ARCHIVE}" || ! xz -t "${TOOLCHAIN_ARCHIVE}" >/dev/null 2>&1; then
                rm -f "${TOOLCHAIN_ARCHIVE}"
                echo "ERROR: failed to download the ARM GNU toolchain (${TOOLCHAIN_URL})" >&2
                exit 1
            fi
        fi

        echo "Extracting ARM GNU toolchain..."
        tar -xf "${TOOLCHAIN_ARCHIVE}"

        if [[ ! -x "${TOOLCHAIN_DIR}/bin/aarch64-unknown-linux-musl-gcc" ]]; then
            echo "ERROR: ARM toolchain verification failed" >&2
            exit 1
        fi

        echo "ARM toolchain setup complete"
    else
        echo "ARM toolchain already downloaded"
    fi

    export PATH="${PWD}/${TOOLCHAIN_DIR}/bin:${PATH}"
fi

# =============================================================================
# BUILD ARM TRUSTED FIRMWARE
# =============================================================================

echo "[STEP] Building ARM Trusted Firmware (ATF)..."

if [[ ! -d "${ATF_DIR}" ]]; then
    git clone -b "${ATF_BRANCH}" "${ATF_REPO}" "${ATF_DIR}"
fi

cd "${ATF_DIR}"

# Clean and build ATF
make clean
make -j "${JOBS}" PLAT=agilex5 bl2 bl31 fiptool PRELOADED_BL33_BASE=0x80100000

declare -r FIPTOOL=${PWD}/tools/fiptool/fiptool
declare -r BL31_BIN=${PWD}/build/agilex5/release/bl31.bin
declare -r BL2_BIN=${PWD}/build/agilex5/release/bl2.bin
declare -r BL2_HEX=${PWD}/build/agilex5/release/bl2.hex

# bl2.hex is a raw-binary -> Intel-hex conversion, so any objcopy works. The
# musl-cross host binaries need glibc >= 2.33 and won't run on SLES15.
OBJCOPY_BIN="$(command -v aarch64-none-linux-gnu-objcopy || command -v objcopy)"
echo "Using objcopy: ${OBJCOPY_BIN}"

pushd "$(dirname ${BL2_BIN})"
"${OBJCOPY_BIN}" -v -I binary -O ihex --change-addresses 0x00000000 bl2.bin bl2.hex
popd

cd ..

echo "ATF build complete"

# =============================================================================
# BUILD Zephyr
# =============================================================================

echo "[STEP] Building Zephyr (hello-world)..."

# It is assumed all the dependencies have been installed prior to running this
# script.
if [[ ! -d "${ZEPHYR_DIR}" ]]; then
   mkdir "${ZEPHYR_DIR}"
fi

cd "${ZEPHYR_DIR}"
python3 -m venv ${PWD}/.venv
source ${PWD}/.venv/bin/activate

# pip caches wheels under $HOME by default. On quota-limited home directories
# that fails with "Disk quota exceeded" while building wheels.
export PIP_CACHE_DIR="${PWD}/.pip-cache"
export TMPDIR="${PWD}/.tmp"
mkdir -p "${PIP_CACHE_DIR}" "${TMPDIR}"

pip install west

# west init -m "${ZEPHYR_REPO}" --mr "${ZEPHYR_BRANCH}" zephyr/
[[ -d zephyr/.west ]] || west init -m "${ZEPHYR_REPO}" --mr "${ZEPHYR_BRANCH}" zephyr/
cd zephyr
west update
west zephyr-export
west packages pip --install

ensure_zephyr_sdk

cd zephyr

west build -p always -b ${ZEPHYR_BOARD} ${ZEPHYR_SAMPLE}
declare -r ZEPHYR_BIN=${PWD}/build/zephyr/zephyr.bin

cd ../../..

echo "Zephyr build complete"

# =============================================================================
# CREATE SD CARD IMAGE
# =============================================================================

echo "[STEP] Creating FIP file..."
declare -r FIP_FILE=${PWD}/fip.bin
${FIPTOOL} create --soc-fw ${BL31_BIN}   \
	          --nt-fw  ${ZEPHYR_BIN} \
                  ${FIP_FILE}

echo "[STEP] Creating SD card image..."

if ! command -v guestfish >/dev/null 2>&1; then
    echo "guestfish not found; installing libguestfs-tools..."
    sudo apt-get update
    sudo apt-get install -y libguestfs-tools
    if ! command -v guestfish >/dev/null 2>&1; then
        echo "ERROR: guestfish still not found after installing libguestfs-tools." >&2
        exit 1
    fi
fi

declare -r SDCARD_IMG="${PWD}/sdcard.img"
create_sdcard_img "${FIP_FILE}" "${SDCARD_IMG}"

echo "SUCCESS: SD card image created: sdcard.img"
echo ""
echo "======================================================================"
echo "                           BUILD COMPLETE"
echo "======================================================================"
echo ""
echo "Output file created in: ${PWD}"
echo ""
echo "To write SD card image:"
echo "  sudo dd if=${PWD}/sdcard.img of=/dev/sdX bs=1M"
echo "  (Replace /dev/sdX with your SD card device)"
echo ""
echo "To boot from SD card:"
echo "  1. Write image to SD card"
echo "  2. Insert SD card into Agilex 5 board"
echo "  3. Use quartus_pfg to generate a JIC using GHRD sof + bl2.hex"
echo "     e.g. quartus_pfg \\"
echo "          -c sof_filename.sof output_file.jic \\"
echo "          -o device=MT25QU128 \\"
echo "          -o flash_loader=A5ED065BB32AE6SR0 \\"
echo "          -o hps_path=${BL2_HEX} \\"
echo "          -o mode=ASX4 \\"
echo "          -o hps=1"
echo "  4. Program the JIC and power cycle the board"
echo "     e.g. quartus_pgm -c 1 -m jtag -o \"pvi;output_file.jic\""
echo ""

