#!/usr/bin/env bash
# Arch/EndeavourOS + GRUB + NVIDIA single-GPU passthrough installer/manager.
#
# This script intentionally keeps the host NVIDIA driver active at boot.  The
# GPU is released only while the selected libvirt guest is running, then bound
# back to the host when the guest powers off.
set -Eeuo pipefail
export LC_ALL=C

readonly VERSION="2.2.0"
readonly INSTALLED_TOOL="/usr/local/sbin/single-gpu-vfio"
readonly CONFIG_FILE="/etc/single-gpu-vfio.conf"
readonly HOOK_FILE="/etc/libvirt/hooks/qemu.d/10-single-gpu-vfio"
readonly BACKUP_DIR="/var/lib/single-gpu-vfio/backups"

log()  { printf '[single-gpu-vfio] %s\n' "$*"; }
warn() { printf '[single-gpu-vfio] WARNING: %s\n' "$*" >&2; }
die()  { printf '[single-gpu-vfio] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
single-gpu-vfio 2.2.0

Personal Arch/EndeavourOS + GRUB + NVIDIA single-GPU VFIO tool.

The workflow is intentionally split into three stages:

  1. Prepare the host (safe to run from a graphical terminal):
     sudo ./single-gpu-vfio.sh setup-host --user YOUR_USER

  2. Log out of the graphical desktop, switch to a real Linux console such as
     Ctrl+Alt+F3, log in there, then extract and patch the VBIOS:
     sudo single-gpu-vfio extract-rom \
       --gpu 0000:01:00.0 \
       --output /var/lib/libvirt/vbios/gtx1050.rom

  3. Create the VM after rebooting with IOMMU enabled:
     sudo single-gpu-vfio create-vm \
       --vm-name omarchy-vfio \
       --iso /absolute/path/to/installer.iso \
       --rom /var/lib/libvirt/vbios/gtx1050.rom \
       --gpu 0000:01:00.0 \
       --audio 0000:01:00.1 \
       --usb 0000:00:14.0 \
       --disk /absolute/path/to/guest.qcow2 \
       --disk-size 40G --memory 8192 --vcpus 4

setup-host options:
  --user NAME                Desktop user (default: SUDO_USER)
  --yes                      Skip confirmation prompts
  --skip-packages            Do not install packages
  --skip-nvflash             Do not offer nvflash installation from AUR

extract-rom options:
  --gpu BDF                  NVIDIA GPU PCI address (auto-detected if omitted)
  --output PATH              Patched ROM output path (required)
  --raw-output PATH          Raw nvflash backup path (default: OUTPUT.raw.rom)
  --nvflash PATH             nvflash executable (default: detect from PATH)
  --nvflash-index N          nvflash adapter index (single-GPU default: 0)
  --display-manager SERVICE  Auto-detect greetd/sddm/gdm/lightdm by default
  --gpu-services LIST        Comma-separated services to stop (auto: lactd)

create-vm options:
  --vm-name NAME             VM name (default: single-gpu-vm)
  --iso PATH                 Installer ISO (required)
  --rom PATH                 Patched or raw VBIOS (required and revalidated)
  --gpu BDF                  NVIDIA GPU PCI address (auto-detected if omitted)
  --audio BDF                NVIDIA HDMI audio address (auto-detected if omitted)
  --sound BDF                Physical host sound card (auto-detected; none disables)
  --usb BDF                  Whole USB controller to pass through (required)
  --disk PATH                qcow2 path (default: /var/lib/libvirt/images/NAME.qcow2)
  --disk-size SIZE           New disk size (default: 40G)
  --memory MiB               Guest memory (default: 8192)
  --vcpus N                  Guest vCPUs (default: 4)
  --user NAME                Desktop user (default: SUDO_USER)
  --display-manager SERVICE  Auto-detect greetd/sddm/gdm/lightdm by default
  --gpu-services LIST        Comma-separated services to stop (auto: lactd)
  --yes                      Skip IOMMU group confirmation
  --allow-existing-hooks     Allow other existing VFIO hooks (may conflict)

VM management commands:
  sudo single-gpu-vfio detect
  sudo single-gpu-vfio check
  sudo single-gpu-vfio test [SECONDS]
  sudo single-gpu-vfio start
  sudo single-gpu-vfio shutdown
  sudo single-gpu-vfio force-stop
  sudo single-gpu-vfio recover
  sudo single-gpu-vfio eject-iso
  sudo single-gpu-vfio status
  sudo single-gpu-vfio remove

Important:
  * extract-rom refuses to run from a GUI terminal, SSH, or pseudo-terminal.
  * Log out of Plasma/Hyprland before running extract-rom from Ctrl+Alt+F3.
  * test/start terminates the current graphical session. Save your work first.
  * Shut down from inside the guest. Ctrl+Alt+Delete normally reboots it.
  * force-stop is equivalent to pulling the guest power cable.
EOF
}

require_root() {
    (( EUID == 0 )) || die "Run this command as root with sudo or pkexec."
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

confirm() {
    local prompt="$1"
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    [[ -t 0 ]] || die "$prompt (use --yes in non-interactive mode)"
    local answer
    read -r -p "$prompt [type YES to continue]: " answer
    [[ "$answer" == "YES" ]] || die "Cancelled."
}

normalize_bdf() {
    local value="${1,,}"
    if [[ "$value" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
        value="0000:$value"
    fi
    [[ "$value" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || \
        die "Invalid PCI address: $1 (example: 0000:01:00.0)"
    printf '%s\n' "$value"
}

pci_driver() {
    local path="/sys/bus/pci/devices/$1/driver"
    [[ -L "$path" ]] && basename "$(readlink -f "$path")" || printf '%s' 'unbound'
}

pci_class() {
    local path="/sys/bus/pci/devices/$1/class"
    [[ -r "$path" ]] && tr -d '\n' <"$path" || printf '%s' 'unknown'
}

pci_xml_address() {
    local bdf="$1"
    local domain="${bdf%%:*}"
    local rest="${bdf#*:}"
    local bus="${rest%%:*}"
    local slot_function="${rest#*:}"
    local slot="${slot_function%%.*}"
    local function="${slot_function#*.}"
    printf '<address domain="0x%s" bus="0x%s" slot="0x%s" function="0x%s"/>' \
        "$domain" "$bus" "$slot" "$function"
}

xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&apos;/g" <<<"$1"
}

config_value() {
    printf '%s=%q\n' "$1" "$2"
}

load_config() {
    [[ -r "$CONFIG_FILE" ]] || die "Configuration is not installed: $CONFIG_FILE"
    # The file is generated root-owned and mode 0600 by this tool.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    SOUND_BDF="${SOUND_BDF:-none}"
}

state_dir() {
    local safe_name="${VM_NAME//[^A-Za-z0-9_.-]/_}"
    printf '/run/libvirt/single-gpu-vfio-%s\n' "$safe_name"
}

hook_log_file() {
    local safe_name="${VM_NAME//[^A-Za-z0-9_.-]/_}"
    printf '/var/log/libvirt/single-gpu-vfio-%s.log\n' "$safe_name"
}

detect_display_manager() {
    local linked=''
    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        linked="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")"
        [[ "$linked" == *.service ]] && { printf '%s\n' "$linked"; return; }
    fi
    local service
    for service in greetd.service sddm.service gdm.service lightdm.service lxdm.service; do
        if systemctl is-active --quiet "$service" 2>/dev/null || \
           systemctl is-enabled --quiet "$service" 2>/dev/null; then
            printf '%s\n' "$service"
            return
        fi
    done
    die "Could not detect a display manager; use --display-manager."
}

detect_gpu() {
    lspci -Dnn | awk '
        /NVIDIA/ && (/VGA compatible controller/ || /3D controller/) { print $1; exit }
    '
}

detect_gpu_audio() {
    local gpu="$1"
    local prefix="${gpu%.*}"
    local candidate
    while read -r candidate; do
        [[ "${candidate%.*}" == "$prefix" ]] && { printf '%s\n' "$candidate"; return; }
    done < <(lspci -Dnn | awk '/NVIDIA/ && /Audio device/ {print $1}')
}

detect_host_sound() {
    lspci -Dnn | awk '
        /Audio device/ && !/NVIDIA/ { print $1; exit }
    '
}

iommu_group_members() {
    local bdf="$1" group_path member
    group_path="$(readlink -f "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null || true)"
    [[ -n "$group_path" && -d "$group_path/devices" ]] || return 1
    for member in "$group_path"/devices/*; do
        printf '%s\n' "${member##*/}"
    done
}

iommu_active() {
    compgen -G '/sys/kernel/iommu_groups/*/devices/*' >/dev/null 2>&1
}

show_iommu_group() {
    local bdf="$1"
    local group_path
    group_path="$(readlink -f "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null || true)"
    if [[ -z "$group_path" || ! -d "$group_path/devices" ]]; then
        printf '  %s: no IOMMU group\n' "$bdf"
        return 1
    fi
    printf '  %s: group %s\n' "$bdf" "${group_path##*/}"
    local member
    for member in "$group_path"/devices/*; do
        lspci -Dnn -s "${member##*/}" | sed 's/^/    /'
    done
}

show_detection() {
    require_command lspci
    log "Version: $VERSION"
    printf '\nSystem:\n'
    sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null || true
    printf 'Kernel: %s\n' "$(uname -r)"
    printf 'Kernel command line: %s\n' "$(< /proc/cmdline)"
    printf 'IOMMU groups: %s\n' "$(iommu_active && printf active || printf inactive)"
    printf '\nNVIDIA GPU/audio devices:\n'
    lspci -Dnnk | rg -A3 -i '(VGA compatible controller|3D controller|Audio device).*NVIDIA|NVIDIA.*(VGA compatible controller|3D controller|Audio device)' || true
    printf '\nUSB controllers:\n'
    lspci -Dnnk | rg -A3 'USB controller' || true
    printf '\nDisplay-manager candidates:\n'
    local service
    for service in greetd.service sddm.service gdm.service lightdm.service lxdm.service; do
        if systemctl list-unit-files "$service" --no-legend 2>/dev/null | grep -q .; then
            printf '  %-18s active=%-8s enabled=%s\n' "$service" \
                "$(systemctl is-active "$service" 2>/dev/null || true)" \
                "$(systemctl is-enabled "$service" 2>/dev/null || true)"
        fi
    done
}

install_packages() {
    [[ -e /etc/arch-release ]] || die "Automatic package installation supports Arch/EndeavourOS only."
    require_command pacman
    log "Installing KVM/libvirt/OVMF dependencies..."
    pacman -S --needed --noconfirm \
        qemu-desktop libvirt virt-manager edk2-ovmf swtpm dnsmasq \
        pciutils psmisc python ripgrep
    systemctl enable --now libvirtd.service
}

configure_grub_iommu() {
    [[ -f /etc/default/grub ]] || die "Missing /etc/default/grub; only GRUB is configured automatically."
    require_command grub-mkconfig

    local cpu_vendor iommu_param
    cpu_vendor="$(awk -F: '/vendor_id/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo)"
    case "$cpu_vendor" in
        GenuineIntel) iommu_param='intel_iommu=on' ;;
        AuthenticAMD) iommu_param='amd_iommu=on' ;;
        *) die "Unknown CPU vendor: $cpu_vendor" ;;
    esac

    # shellcheck disable=SC1091
    source /etc/default/grub
    local current="${GRUB_CMDLINE_LINUX_DEFAULT:-}"
    local parameter
    for parameter in "$iommu_param" iommu=pt; do
        if [[ " $current " != *" $parameter "* ]]; then
            current="${current:+$current }$parameter"
        fi
    done

    install -d -m 0755 "$BACKUP_DIR"
    if [[ ! -e "$BACKUP_DIR/grub.before-single-gpu-vfio" ]]; then
        install -m 0644 /etc/default/grub "$BACKUP_DIR/grub.before-single-gpu-vfio"
    fi

    local escaped replacement temporary
    escaped="${current//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    replacement="GRUB_CMDLINE_LINUX_DEFAULT=\"$escaped\""
    temporary="$(mktemp /etc/default/grub.single-gpu-vfio.XXXXXX)"
    awk -v replacement="$replacement" '
        BEGIN { replaced=0 }
        /^GRUB_CMDLINE_LINUX_DEFAULT=/ { print replacement; replaced=1; next }
        { print }
        END { if (!replaced) print replacement }
    ' /etc/default/grub >"$temporary"
    install -o root -g root -m 0644 "$temporary" /etc/default/grub
    rm -f "$temporary"
    grub-mkconfig -o /boot/grub/grub.cfg
    log "Added $iommu_param iommu=pt to GRUB."
}

prepare_rom() {
    local source_rom="$1" destination_rom="$2"
    [[ -f "$source_rom" ]] || die "ROM does not exist: $source_rom"
    require_command python3
    install -d -m 0755 "$(dirname "$destination_rom")"
    local temporary
    temporary="$(mktemp "$(dirname "$destination_rom")/.rom.XXXXXX")"

    local expected_vendor expected_device
    expected_vendor="$(<"/sys/bus/pci/devices/$GPU_BDF/vendor")"
    expected_device="$(<"/sys/bus/pci/devices/$GPU_BDF/device")"
    python3 - "$source_rom" "$temporary" "$expected_vendor" "$expected_device" <<'PY'
import pathlib
import struct
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
data = source.read_bytes()
expected_vendor = int(sys.argv[3], 16)
expected_device = int(sys.argv[4], 16)

def parse_chain(offset):
    images = []
    cursor = offset
    for _ in range(32):
        if cursor + 0x1a > len(data) or data[cursor:cursor + 2] != b"\x55\xaa":
            return None
        pcir_pointer = struct.unpack_from("<H", data, cursor + 0x18)[0]
        pcir = cursor + pcir_pointer
        if pcir + 0x16 > len(data) or data[pcir:pcir + 4] != b"PCIR":
            return None
        vendor, device = struct.unpack_from("<HH", data, pcir + 4)
        if not images and (vendor != expected_vendor or device != expected_device):
            return None
        image_length = struct.unpack_from("<H", data, pcir + 0x10)[0] * 512
        code_type = data[pcir + 0x14]
        indicator = data[pcir + 0x15]
        if image_length == 0 or cursor + image_length > len(data):
            return None
        images.append((cursor, image_length, code_type))
        if indicator & 0x80:
            return images
        cursor += image_length
    return None

chosen = None
for offset in range(0, max(0, len(data) - 1)):
    if data[offset:offset + 2] != b"\x55\xaa":
        continue
    chain = parse_chain(offset)
    if chain and any(code_type == 3 for _, _, code_type in chain):
        chosen = (offset, chain)
        break

if chosen is None:
    raise SystemExit("No valid PCI option-ROM chain with EFI GOP was found")

offset, chain = chosen
destination.write_bytes(data[offset:])
print(f"ROM header offset: {offset}")
for index, (image_offset, image_length, code_type) in enumerate(chain, 1):
    kind = {0: "legacy", 3: "EFI"}.get(code_type, f"type-{code_type}")
    print(f"ROM image {index}: offset={image_offset-offset} length={image_length} {kind}")
PY

    install -o root -g root -m 0644 "$temporary" "$destination_rom"
    rm -f "$temporary"
    log "Installed patched ROM: $destination_rom"
    sha256sum "$destination_rom"
}

require_linux_vt() {
    local terminal
    terminal="$(tty 2>/dev/null || true)"
    [[ "$terminal" =~ ^/dev/tty[0-9]+$ ]] || \
        die "This command must run from a Linux virtual console such as Ctrl+Alt+F3, not from a GUI terminal, SSH, or /dev/pts."
}

graphical_session_active() {
    local session type class
    while read -r session _; do
        [[ -n "$session" ]] || continue
        type="$(loginctl show-session "$session" -p Type --value 2>/dev/null || true)"
        class="$(loginctl show-session "$session" -p Class --value 2>/dev/null || true)"
        case "$type:$class" in
            wayland:user|wayland:user-early|x11:user|x11:user-early|mir:user|mir:user-early) return 0 ;;
        esac
    done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    return 1
}

extract_rom_nvflash() {
    local nvflash_bin="$1" nvflash_index="$2" destination_raw="$3"
    [[ -x "$nvflash_bin" ]] || die "nvflash is not executable: $nvflash_bin"
    [[ "$nvflash_index" =~ ^[0-9]+$ ]] || die "--nvflash-index must be a non-negative integer."
    require_linux_vt
    graphical_session_active && \
        die "A Wayland/X11 session is still active. Log out of the desktop, switch to Ctrl+Alt+F3, and try again."
    install -d -m 0755 "$(dirname "$destination_raw")"
    local temporary
    temporary="$(mktemp "$(dirname "$destination_raw")/.raw-rom.XXXXXX")"
    log "The console may go black while the NVIDIA driver is unloaded. Do not power off the host."
    if ! (
        set -Eeuo pipefail
        local -a active_services=() vtconsoles=()
        local display_manager_was_active=0
        restore_after_nvflash() {
            local rc=$?
            local recovery_failed=0
            trap - EXIT
            set +e
            modprobe nvidia
            modprobe nvidia_modeset
            modprobe nvidia_uvm
            modprobe nvidia_drm
            if [[ ! -L "/sys/bus/pci/devices/$GPU_BDF/driver" ]]; then
                printf '%s' "$GPU_BDF" >/sys/bus/pci/drivers_probe
            fi
            local vtconsole service
            for vtconsole in "${vtconsoles[@]}"; do
                [[ -w "/sys/class/vtconsole/$vtconsole/bind" ]] && \
                    printf '1' >"/sys/class/vtconsole/$vtconsole/bind"
            done
            for service in "${active_services[@]}"; do systemctl start "$service" || recovery_failed=1; done
            if (( display_manager_was_active )); then
                systemctl start "$DISPLAY_MANAGER" || recovery_failed=1
            fi
            [[ "$(pci_driver "$GPU_BDF")" == nvidia ]] || recovery_failed=1
            if (( rc == 0 && recovery_failed != 0 )); then rc=1; fi
            exit "$rc"
        }
        trap restore_after_nvflash EXIT

        local service
        for service in $GPU_SERVICES; do
            [[ -n "$service" ]] || continue
            if systemctl is-active --quiet "$service"; then
                active_services+=("$service")
                systemctl stop "$service"
            fi
        done
        if systemctl is-active --quiet "$DISPLAY_MANAGER"; then
            display_manager_was_active=1
            systemctl stop "$DISPLAY_MANAGER"
        fi
        local -a nvidia_nodes=()
        mapfile -t nvidia_nodes < <(compgen -G '/dev/nvidia*' || true)
        local attempt
        for ((attempt=0; attempt<20; attempt++)); do
            if ((${#nvidia_nodes[@]} == 0)) || ! fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
        if ((${#nvidia_nodes[@]} > 0)) && fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
            fuser -v "${nvidia_nodes[@]}" || true
            die "NVIDIA device nodes are still in use after stopping the display manager."
        fi

        local vtconsole
        for vtconsole in /sys/class/vtconsole/vtcon*; do
            [[ -r "$vtconsole/name" && -w "$vtconsole/bind" ]] || continue
            if grep -qi 'frame buffer' "$vtconsole/name" && [[ "$(<"$vtconsole/bind")" == "1" ]]; then
                vtconsoles+=("$(basename "$vtconsole")")
                printf '0' >"$vtconsole/bind"
            fi
        done

        local gpu_path="/sys/bus/pci/devices/$GPU_BDF"
        if [[ -L "$gpu_path/driver" ]]; then
            local driver
            driver="$(basename "$(readlink -f "$gpu_path/driver")")"
            [[ "$driver" == nvidia ]] || die "Expected the nvidia driver before extraction, found: $driver"
            printf '%s' "$GPU_BDF" >"$gpu_path/driver/unbind"
        fi
        local module
        for module in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
            [[ ! -d "/sys/module/$module" ]] || modprobe -r "$module"
        done

        log "NVIDIA adapters reported by nvflash:"
        "$nvflash_bin" --list
        log "Saving VBIOS from nvflash adapter $nvflash_index..."
        "$nvflash_bin" --index="$nvflash_index" --save "$temporary"
        log "Verifying the saved raw ROM against the adapter..."
        "$nvflash_bin" --index="$nvflash_index" --verify "$temporary"
    ); then
        rm -f "$temporary"
        die "nvflash extraction or verification failed; host recovery was attempted."
    fi
    [[ -s "$temporary" ]] || { rm -f "$temporary"; die "nvflash produced an empty ROM."; }
    install -o root -g root -m 0644 "$temporary" "$destination_raw"
    rm -f "$temporary"
    log "Saved raw VBIOS backup: $destination_raw"
    sha256sum "$destination_raw"
}

find_ovmf() {
    local code_candidates=(
        /usr/share/edk2/x64/OVMF_CODE.4m.fd
        /usr/share/edk2/ovmf/OVMF_CODE.fd
        /usr/share/OVMF/OVMF_CODE.fd
    )
    local vars_candidates=(
        /usr/share/edk2/x64/OVMF_VARS.4m.fd
        /usr/share/edk2/ovmf/OVMF_VARS.fd
        /usr/share/OVMF/OVMF_VARS.fd
    )
    OVMF_CODE=''
    OVMF_VARS=''
    local candidate
    for candidate in "${code_candidates[@]}"; do [[ -f "$candidate" ]] && { OVMF_CODE="$candidate"; break; }; done
    for candidate in "${vars_candidates[@]}"; do [[ -f "$candidate" ]] && { OVMF_VARS="$candidate"; break; }; done
    [[ -n "$OVMF_CODE" && -n "$OVMF_VARS" ]] || die "Could not find non-Secure-Boot OVMF CODE/VARS firmware."
}

ensure_default_network() {
    if ! virsh -c qemu:///system net-info default >/dev/null 2>&1; then
        local template='/usr/share/libvirt/networks/default.xml'
        [[ -f "$template" ]] || die "The libvirt default network is missing and $template was not found."
        virsh -c qemu:///system net-define "$template"
    fi
    virsh -c qemu:///system net-autostart default
    if ! virsh -c qemu:///system net-info default | grep -q '^Active:.*yes'; then
        virsh -c qemu:///system net-start default
    fi
}

write_config() {
    local temporary
    temporary="$(mktemp /etc/single-gpu-vfio.conf.XXXXXX)"
    {
        printf '# Generated by single-gpu-vfio %s\n' "$VERSION"
        config_value VM_NAME "$VM_NAME"
        config_value HOST_USER "$HOST_USER"
        config_value HOST_UID "$HOST_UID"
        config_value DISPLAY_MANAGER "$DISPLAY_MANAGER"
        config_value GPU_SERVICES "$GPU_SERVICES"
        config_value GPU_BDF "$GPU_BDF"
        config_value AUDIO_BDF "$AUDIO_BDF"
        config_value USB_BDF "$USB_BDF"
        config_value SOUND_BDF "$SOUND_BDF"
        config_value GPU_HOST_DRIVER "$GPU_HOST_DRIVER"
        config_value AUDIO_HOST_MODULE "$AUDIO_HOST_MODULE"
        config_value USB_HOST_MODULE "$USB_HOST_MODULE"
        config_value ISO_PATH "$ISO_PATH"
        config_value RAW_ROM_PATH "$RAW_ROM_PATH"
        config_value ROM_PATH "$ROM_PATH"
        config_value DISK_PATH "$DISK_PATH"
        config_value OVMF_CODE "$OVMF_CODE"
        config_value OVMF_VARS "$OVMF_VARS"
    } >"$temporary"
    install -o root -g root -m 0600 "$temporary" "$CONFIG_FILE"
    rm -f "$temporary"
}

write_hook() {
    install -d -o root -g root -m 0755 "$(dirname "$HOOK_FILE")"
    local temporary
    temporary="$(mktemp /etc/libvirt/hooks/qemu.d/.single-gpu-vfio.XXXXXX)"
    cat >"$temporary" <<EOF
#!/usr/bin/env bash
exec "$INSTALLED_TOOL" hook "\$@"
EOF
    install -o root -g root -m 0755 "$temporary" "$HOOK_FILE"
    rm -f "$temporary"
}

create_domain_xml() {
    local output="$1"
    local gpu_source audio_source usb_source sound_source
    gpu_source="$(pci_xml_address "$GPU_BDF")"
    audio_source="$(pci_xml_address "$AUDIO_BDF")"
    usb_source="$(pci_xml_address "$USB_BDF")"
    sound_source=''
    if [[ "$SOUND_BDF" != none ]]; then
        sound_source="$(pci_xml_address "$SOUND_BDF")"
    fi

    local vm_xml iso_xml disk_xml rom_xml code_xml vars_xml uuid_xml
    vm_xml="$(xml_escape "$VM_NAME")"
    iso_xml="$(xml_escape "$ISO_PATH")"
    disk_xml="$(xml_escape "$DISK_PATH")"
    rom_xml="$(xml_escape "$ROM_PATH")"
    code_xml="$(xml_escape "$OVMF_CODE")"
    vars_xml="$(xml_escape "$OVMF_VARS")"
    uuid_xml=''
    if [[ -n "${VM_UUID:-}" ]]; then
        uuid_xml="  <uuid>$(xml_escape "$VM_UUID")</uuid>"
    fi

    local sound_hostdev_xml
    sound_hostdev_xml=''
    if [[ "$SOUND_BDF" != none ]]; then
        sound_hostdev_xml="    <hostdev mode=\"subsystem\" type=\"pci\" managed=\"yes\">
      <driver name=\"vfio\"/>
      <source>$sound_source</source>
    </hostdev>"
    fi

    cat >"$output" <<EOF
<domain type="kvm">
  <name>$vm_xml</name>
$uuid_xml
  <title>NVIDIA single-GPU passthrough</title>
  <description>Starting this guest terminates the host graphical session and passes through its only GPU.</description>
  <memory unit="MiB">$MEMORY_MIB</memory>
  <currentMemory unit="MiB">$MEMORY_MIB</currentMemory>
  <vcpu placement="static">$VCPUS</vcpu>
  <os>
    <type arch="x86_64" machine="q35">hvm</type>
    <loader readonly="yes" secure="no" type="pflash">$code_xml</loader>
    <nvram template="$vars_xml">/var/lib/libvirt/qemu/nvram/${vm_xml}_VARS.fd</nvram>
    <boot dev="hd"/>
    <boot dev="cdrom"/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode="host-passthrough" check="none" migratable="on"/>
  <clock offset="utc">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="pit" tickpolicy="delay"/>
    <timer name="hpet" present="no"/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled="no"/>
    <suspend-to-disk enabled="no"/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" discard="unmap"/>
      <source file="$disk_xml"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <source file="$iso_xml"/>
      <target dev="sda" bus="sata"/>
      <readonly/>
    </disk>
    <controller type="usb" model="qemu-xhci" ports="15"/>
    <controller type="pci" model="pcie-root"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <controller type="pci" model="pcie-root-port"/>
    <interface type="network">
      <source network="default"/>
      <model type="virtio"/>
    </interface>
    <audio id="1" type="none"/>
    <video>
      <model type="none"/>
    </video>
    <console type="pty"/>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <driver name="vfio"/>
      <source>$gpu_source</source>
      <rom bar="on" file="$rom_xml"/>
      <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x0" multifunction="on"/>
    </hostdev>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <driver name="vfio"/>
      <source>$audio_source</source>
      <address type="pci" domain="0x0000" bus="0x06" slot="0x00" function="0x1"/>
    </hostdev>
    <hostdev mode="subsystem" type="pci" managed="yes">
      <driver name="vfio"/>
      <source>$usb_source</source>
    </hostdev>
$sound_hostdev_xml
    <memballoon model="virtio"/>
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>
  </devices>
</domain>
EOF
}

runtime_preflight() {
    load_config
    iommu_active || die "No IOMMU groups are active; check firmware settings and GRUB, then reboot."
    [[ -f "$ROM_PATH" ]] || die "ROM is missing: $ROM_PATH"
    [[ -f "$DISK_PATH" ]] || die "Virtual disk is missing: $DISK_PATH"
    local -a devices=("$GPU_BDF" "$AUDIO_BDF" "$USB_BDF")
    [[ "$SOUND_BDF" == none ]] || devices+=("$SOUND_BDF")
    local bdf
    for bdf in "${devices[@]}"; do
        [[ -e "/sys/bus/pci/devices/$bdf" ]] || die "PCI device does not exist: $bdf"
        [[ -L "/sys/bus/pci/devices/$bdf/iommu_group" ]] || die "PCI device has no IOMMU group: $bdf"
    done
    virsh -c qemu:///system dominfo "$VM_NAME" >/dev/null || die "libvirt domain does not exist: $VM_NAME"
}

domain_is_off() {
    [[ "$(virsh -c qemu:///system domstate "$VM_NAME")" == "shut off" ]]
}

hook_prepare() (
    set -Eeuo pipefail
    load_config
    local state log_file
    state="$(state_dir)"
    log_file="$(hook_log_file)"
    mkdir -p "$state" "$(dirname "$log_file")"
    exec >>"$log_file" 2>&1
    local log_prefix='prepare'
    hlog() { printf '[%s] %s: %s\n' "$(date --iso-8601=seconds)" "$log_prefix" "$*"; }
    recover_on_error() {
        local rc=$?
        trap - EXIT
        if (( rc != 0 )); then
            hlog "hand-off failed (status $rc); restoring host graphics"
            hook_release || true
        fi
        exit "$rc"
    }
    trap recover_on_error EXIT

    hlog "beginning hand-off of $GPU_BDF"
    printf '%s\n' preparing >"$state/status"
    : >"$state/vtconsoles"
    : >"$state/services"
    : >"$state/sound-group-companions"
    rm -f "$state/display-manager-was-active"

    local service
    for service in $GPU_SERVICES; do
        [[ -n "$service" ]] || continue
        if systemctl is-active --quiet "$service"; then
            printf '%s\n' "$service" >>"$state/services"
            systemctl stop "$service"
            hlog "stopped $service"
        fi
    done

    if systemctl is-active --quiet "$DISPLAY_MANAGER"; then
        touch "$state/display-manager-was-active"
        systemctl stop "$DISPLAY_MANAGER"
        hlog "stopped $DISPLAY_MANAGER"
    fi

    loginctl terminate-user "$HOST_USER" || true
    pkill -TERM -u "$HOST_UID" || true
    hlog "requested termination of user $HOST_USER (uid $HOST_UID)"
    sleep 3
    if pgrep -u "$HOST_UID" >/dev/null 2>&1; then
        pkill -KILL -u "$HOST_UID" || true
        hlog "force-killed remaining uid $HOST_UID processes"
    fi

    if [[ "$SOUND_BDF" != none ]]; then
        local group_member group_driver
        while read -r group_member; do
            [[ "$group_member" != "$SOUND_BDF" ]] || continue
            group_driver="$(pci_driver "$group_member")"
            [[ "$group_driver" != unbound ]] || continue
            printf '%s %s\n' "$group_member" "$group_driver" >>"$state/sound-group-companions"
            printf '%s' "$group_member" >"/sys/bus/pci/devices/$group_member/driver/unbind"
            hlog "temporarily unbound sound-group companion $group_member from $group_driver"
        done < <(iommu_group_members "$SOUND_BDF")
    fi

    local -a nvidia_nodes=()
    mapfile -t nvidia_nodes < <(compgen -G '/dev/nvidia*' || true)
    local attempt
    for ((attempt=0; attempt<20; attempt++)); do
        if ((${#nvidia_nodes[@]} == 0)) || ! fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
    if ((${#nvidia_nodes[@]} > 0)) && fuser "${nvidia_nodes[@]}" >/dev/null 2>&1; then
        hlog "GPU device nodes remain in use; refusing unsafe detach"
        fuser -v "${nvidia_nodes[@]}" || true
        exit 1
    fi

    local vtconsole
    for vtconsole in /sys/class/vtconsole/vtcon*; do
        [[ -r "$vtconsole/name" && -w "$vtconsole/bind" ]] || continue
        if grep -qi 'frame buffer' "$vtconsole/name" && [[ "$(<"$vtconsole/bind")" == "1" ]]; then
            basename "$vtconsole" >>"$state/vtconsoles"
            printf '0' >"$vtconsole/bind"
        fi
    done

    local gpu_device="/sys/bus/pci/devices/$GPU_BDF"
    if [[ -L "$gpu_device/driver" ]]; then
        local driver
        driver="$(basename "$(readlink -f "$gpu_device/driver")")"
        [[ "$driver" == "$GPU_HOST_DRIVER" ]] || die "GPU driver is $driver; expected $GPU_HOST_DRIVER"
        printf '%s' "$GPU_BDF" >"$gpu_device/driver/unbind"
        hlog "unbound $GPU_BDF from $driver"
    fi
    [[ ! -L "$gpu_device/driver" ]] || die "GPU is still bound after the unbind request"

    local module
    for module in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        if [[ -d "/sys/module/$module" ]]; then
            modprobe -r "$module"
            hlog "unloaded $module"
        fi
    done
    modprobe vfio-pci
    printf '%s\n' ready >"$state/status"
    hlog "host NVIDIA stack released; libvirt may attach devices"
    trap - EXIT
)

hook_release() (
    set -Eeuo pipefail
    load_config
    local state log_file
    state="$(state_dir)"
    log_file="$(hook_log_file)"
    mkdir -p "$state" "$(dirname "$log_file")"
    exec >>"$log_file" 2>&1
    hlog() { printf '[%s] release: %s\n' "$(date --iso-8601=seconds)" "$*"; }

    exec 9>"$state/release.lock"
    flock 9
    if [[ -r "$state/status" && "$(<"$state/status")" == "recovered" ]]; then
        hlog "host graphics already recovered; ignoring duplicate release"
        exit 0
    fi
    hlog "recovering host graphics"
    printf '%s\n' recovering >"$state/status"

    modprobe nvidia
    modprobe nvidia_modeset
    modprobe nvidia_uvm
    modprobe nvidia_drm
    modprobe "$AUDIO_HOST_MODULE"
    modprobe "$USB_HOST_MODULE"

    local -a devices=("$GPU_BDF" "$AUDIO_BDF" "$USB_BDF")
    [[ "$SOUND_BDF" == none ]] || devices+=("$SOUND_BDF")
    local device
    for device in "${devices[@]}"; do
        if [[ -e "/sys/bus/pci/devices/$device" && ! -L "/sys/bus/pci/devices/$device/driver" ]]; then
            printf '%s' "$device" >/sys/bus/pci/drivers_probe || true
        fi
    done

    if [[ -s "$state/vtconsoles" ]]; then
        local vtconsole
        while read -r vtconsole; do
            [[ -w "/sys/class/vtconsole/$vtconsole/bind" ]] && \
                printf '1' >"/sys/class/vtconsole/$vtconsole/bind" || true
        done <"$state/vtconsoles"
    fi

    if [[ -s "$state/services" ]]; then
        local service
        while read -r service; do systemctl start "$service" || true; done <"$state/services"
    fi
    if [[ -s "$state/sound-group-companions" ]]; then
        local group_member group_driver
        while read -r group_member group_driver; do
            [[ -e "/sys/bus/pci/devices/$group_member" && ! -L "/sys/bus/pci/devices/$group_member/driver" ]] && \
                printf '%s' "$group_member" >/sys/bus/pci/drivers_probe || true
        done <"$state/sound-group-companions"
    fi
    if [[ -e "$state/display-manager-was-active" ]]; then
        systemctl start "$DISPLAY_MANAGER"
    fi
    printf '%s\n' recovered >"$state/status"
    hlog "host graphics recovered"
)

cmd_hook() {
    local guest="${1:-}" operation="${2:-}" phase="${3:-}"
    local xml_file
    xml_file="$(mktemp /run/libvirt-single-gpu-hook.XXXXXX)"
    trap 'rm -f "$xml_file"' EXIT
    cat >"$xml_file"
    if [[ -r "$CONFIG_FILE" ]]; then
        load_config
        if [[ "$guest" == "$VM_NAME" && "$operation" == "prepare" && "$phase" == "begin" ]]; then
            hook_prepare
        elif [[ "$guest" == "$VM_NAME" && "$operation" == "release" && "$phase" == "end" ]]; then
            hook_release
        fi
    fi
    cat "$xml_file"
    rm -f "$xml_file"
    trap - EXIT
}

cmd_recover() {
    require_root
    load_config
    if virsh -c qemu:///system domstate "$VM_NAME" 2>/dev/null | grep -qiE 'running|paused|in shutdown|pmsuspended'; then
        die "$VM_NAME is still active; run shutdown or force-stop first."
    fi

    local -a devices=("$GPU_BDF" "$AUDIO_BDF" "$USB_BDF")
    [[ "$SOUND_BDF" == none ]] || devices+=("$SOUND_BDF")
    local device path driver
    for device in "${devices[@]}"; do
        path="/sys/bus/pci/devices/$device"
        [[ -e "$path" ]] || continue
        driver="$(pci_driver "$device")"
        if [[ "$driver" == "vfio-pci" ]]; then
            printf '%s' "$device" >/sys/bus/pci/drivers/vfio-pci/unbind
        fi
        printf '%s' '' >"$path/driver_override"
    done

    modprobe nvidia
    modprobe nvidia_modeset
    modprobe nvidia_uvm
    modprobe nvidia_drm
    modprobe "$AUDIO_HOST_MODULE"
    modprobe "$USB_HOST_MODULE"
    for device in "${devices[@]}"; do
        [[ -e "/sys/bus/pci/devices/$device" && ! -L "/sys/bus/pci/devices/$device/driver" ]] && \
            printf '%s' "$device" >/sys/bus/pci/drivers_probe || true
    done

    local vtconsole
    for vtconsole in /sys/class/vtconsole/vtcon*; do
        [[ -w "$vtconsole/bind" && -r "$vtconsole/name" ]] || continue
        grep -qi 'frame buffer' "$vtconsole/name" && printf '1' >"$vtconsole/bind" || true
    done
    local service
    for service in $GPU_SERVICES; do
        systemctl is-enabled --quiet "$service" 2>/dev/null && systemctl start "$service" || true
    done
    local state group_member group_driver
    state="$(state_dir)"
    if [[ -s "$state/sound-group-companions" ]]; then
        while read -r group_member group_driver; do
            [[ -e "/sys/bus/pci/devices/$group_member" && ! -L "/sys/bus/pci/devices/$group_member/driver" ]] && \
                printf '%s' "$group_member" >/sys/bus/pci/drivers_probe || true
        done <"$state/sound-group-companions"
    fi
    systemctl start "$DISPLAY_MANAGER"
    log "Requested host GPU recovery and started $DISPLAY_MANAGER."
}

cmd_check() {
    runtime_preflight
    log "VM: $VM_NAME ($(virsh -c qemu:///system domstate "$VM_NAME"))"
    printf 'IOMMU/PCI:\n'
    show_iommu_group "$GPU_BDF" || true
    show_iommu_group "$AUDIO_BDF" || true
    show_iommu_group "$USB_BDF" || true
    [[ "$SOUND_BDF" == none ]] || show_iommu_group "$SOUND_BDF" || true
    printf '\nDrivers:\n'
    printf '  %-14s %s\n' "$GPU_BDF" "$(pci_driver "$GPU_BDF")"
    printf '  %-14s %s\n' "$AUDIO_BDF" "$(pci_driver "$AUDIO_BDF")"
    printf '  %-14s %s\n' "$USB_BDF" "$(pci_driver "$USB_BDF")"
    [[ "$SOUND_BDF" == none ]] || printf '  %-14s %s (physical sound card)\n' "$SOUND_BDF" "$(pci_driver "$SOUND_BDF")"
    printf '\nFiles:\n'
    stat -c '  %A %U:%G %s %n' "$ROM_PATH" "$DISK_PATH" "$ISO_PATH" 2>/dev/null || true
    qemu-img check "$DISK_PATH"

    local native
    native="$(mktemp /tmp/single-gpu-vfio-native.XXXXXX)"
    virsh -c qemu:///system domxml-to-native qemu-argv \
        <(virsh -c qemu:///system dumpxml "$VM_NAME") >"$native"
    if rg -q 'display["=]|x-vga|OVMF_CODE\.secboot' "$native"; then
        rg 'display["=]|x-vga|OVMF_CODE\.secboot' "$native" >&2
        rm -f "$native"
        die "Found forbidden vGPU, x-vga, or Secure Boot parameters."
    fi
    rm -f "$native"
    log "Checks passed."
}

cmd_test() {
    require_root
    runtime_preflight
    domain_is_off || die "$VM_NAME is not shut off."
    local timeout_seconds="${1:-90}"
    [[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds >= 30 && timeout_seconds <= 600 )) || \
        die "Test duration must be between 30 and 600 seconds."
    local run_id safety_unit launch_unit
    run_id="$(date +%s)-$$"
    safety_unit="single-gpu-vfio-safety-$run_id"
    launch_unit="single-gpu-vfio-test-$run_id"
    systemd-run --quiet --collect --unit="$safety_unit" \
        --on-active="${timeout_seconds}s" --timer-property=AccuracySec=1s \
        /usr/bin/bash -c "/usr/bin/virsh -c qemu:///system destroy '$VM_NAME' >/dev/null 2>&1 || true; '$INSTALLED_TOOL' recover || true"
    log "Starting $VM_NAME; forced stop and host recovery are armed for ${timeout_seconds} seconds."
    systemd-run --collect --unit="$launch_unit" \
        /usr/bin/virsh -c qemu:///system start --reset-nvram "$VM_NAME"
}

cmd_start() {
    require_root
    runtime_preflight
    domain_is_off || die "$VM_NAME is not shut off."
    local unit="single-gpu-vfio-start-$(date +%s)-$$"
    log "Starting $VM_NAME; the current graphical session will terminate."
    systemd-run --collect --unit="$unit" \
        /usr/bin/virsh -c qemu:///system start "$VM_NAME"
}

cmd_shutdown() {
    require_root
    load_config
    virsh -c qemu:///system shutdown "$VM_NAME"
    log "Sent an ACPI shutdown request to $VM_NAME."
}

cmd_force_stop() {
    require_root
    load_config
    warn "This will force-stop $VM_NAME, equivalent to pulling its power cable."
    confirm "Force-stop the VM?"
    virsh -c qemu:///system destroy "$VM_NAME" || true
    sleep 2
    cmd_recover
}

cmd_status() {
    load_config
    printf 'VM: %s\n' "$VM_NAME"
    virsh -c qemu:///system domstate "$VM_NAME" 2>/dev/null || true
    printf '\nPCI drivers:\n'
    local -a devices=("$GPU_BDF" "$AUDIO_BDF" "$USB_BDF")
    [[ "$SOUND_BDF" == none ]] || devices+=("$SOUND_BDF")
    local device
    for device in "${devices[@]}"; do
        printf '  %-14s %s\n' "$device" "$(pci_driver "$device")"
    done
    printf '\nTransient safety timers:\n'
    systemctl list-timers --all 'single-gpu-vfio-*' --no-pager --plain || true
    printf '\nRecent hook log:\n'
    tail -n 60 "$(hook_log_file)" 2>/dev/null || true
}

cmd_eject_iso() {
    require_root
    load_config
    domain_is_off || die "Shut down $VM_NAME first."
    virsh -c qemu:///system change-media "$VM_NAME" sda --eject --config
    log "Installer ISO ejected; the next boot will use the virtual disk."
}

cmd_remove() {
    require_root
    load_config
    domain_is_off || die "Shut down $VM_NAME first."
    warn "This removes the libvirt definition, hook, configuration, and installed tool."
    warn "The disk $DISK_PATH and ROM $ROM_PATH will be preserved."
    confirm "Remove the configuration?"
    virsh -c qemu:///system undefine "$VM_NAME" --nvram 2>/dev/null || \
        virsh -c qemu:///system undefine "$VM_NAME" 2>/dev/null || true
    rm -f "$HOOK_FILE" "$CONFIG_FILE"
    log "Configuration removed. IOMMU parameters, packages, disk, and ROM were preserved."
    rm -f "$INSTALLED_TOOL"
}

cmd_setup_host() {
    require_root
    HOST_USER="${SUDO_USER:-}"
    ASSUME_YES=0
    SKIP_PACKAGES=0
    SKIP_NVFLASH=0

    while (($#)); do
        case "$1" in
            --user) HOST_USER="${2:?}"; shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            --skip-packages) SKIP_PACKAGES=1; shift ;;
            --skip-nvflash) SKIP_NVFLASH=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown setup-host option: $1" ;;
        esac
    done

    [[ -n "$HOST_USER" && "$HOST_USER" != root ]] || die "Could not determine the desktop user; use --user."
    id "$HOST_USER" >/dev/null 2>&1 || die "User does not exist: $HOST_USER"

    if (( ! SKIP_PACKAGES )); then install_packages; fi
    if (( ! SKIP_NVFLASH )) && ! command -v nvflash >/dev/null 2>&1 && ! command -v nvflash_linux >/dev/null 2>&1; then
        local aur_helper=''
        aur_helper="$(command -v yay 2>/dev/null || command -v paru 2>/dev/null || true)"
        if [[ -n "$aur_helper" ]]; then
            warn "nvflash is an AUR package and will be built with $(basename "$aur_helper")."
            confirm "Install the nvflash AUR package?"
            sudo -H -u "$HOST_USER" "$aur_helper" -S --needed nvflash
        else
            warn "nvflash is not installed and no yay/paru helper was found. Install it before extract-rom."
        fi
    fi

    if ! grep -qwE 'intel_iommu=on|amd_iommu=on' /proc/cmdline || ! grep -qw iommu=pt /proc/cmdline; then
        configure_grub_iommu
        warn "Reboot is required before create-vm or test."
    else
        log "IOMMU kernel parameters are already active."
    fi

    usermod -a -G libvirt,kvm "$HOST_USER"
    local self_path
    self_path="$(readlink -f "$0")"
    if [[ "$self_path" != "$INSTALLED_TOOL" ]]; then
        install -o root -g root -m 0755 "$self_path" "$INSTALLED_TOOL"
    fi
    log "Host setup complete."
    log "Next: log out of the desktop, switch to Ctrl+Alt+F3, and run extract-rom."
}

cmd_extract_rom() {
    GPU_BDF=''
    ROM_PATH=''
    RAW_ROM_PATH=''
    NVFLASH_BIN=''
    NVFLASH_INDEX='0'
    NVFLASH_INDEX_SET=0
    DISPLAY_MANAGER=''
    GPU_SERVICES='auto'
    ASSUME_YES=0

    while (($#)); do
        case "$1" in
            --gpu) GPU_BDF="${2:?}"; shift 2 ;;
            --output) ROM_PATH="${2:?}"; shift 2 ;;
            --raw-output) RAW_ROM_PATH="${2:?}"; shift 2 ;;
            --nvflash) NVFLASH_BIN="${2:?}"; shift 2 ;;
            --nvflash-index) NVFLASH_INDEX="${2:?}"; NVFLASH_INDEX_SET=1; shift 2 ;;
            --display-manager) DISPLAY_MANAGER="${2:?}"; shift 2 ;;
            --gpu-services) GPU_SERVICES="${2:?}"; shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown extract-rom option: $1" ;;
        esac
    done

    require_root
    require_linux_vt

    require_command lspci
    GPU_BDF="${GPU_BDF:-$(detect_gpu)}"
    [[ -n "$GPU_BDF" ]] || die "No NVIDIA VGA/3D device was detected; use --gpu."
    GPU_BDF="$(normalize_bdf "$GPU_BDF")"
    [[ -e "/sys/bus/pci/devices/$GPU_BDF" ]] || die "PCI device does not exist: $GPU_BDF"
    [[ "$(pci_class "$GPU_BDF")" == 0x0300* || "$(pci_class "$GPU_BDF")" == 0x0302* ]] || \
        die "$GPU_BDF is not a VGA/3D controller."
    [[ "$(pci_driver "$GPU_BDF")" == nvidia ]] || die "$GPU_BDF is not using the nvidia driver."
    [[ -n "$ROM_PATH" && "$ROM_PATH" == /* ]] || die "--output must be an absolute path."
    if [[ -z "$RAW_ROM_PATH" ]]; then
        RAW_ROM_PATH="${ROM_PATH%.rom}.raw.rom"
    fi
    [[ "$RAW_ROM_PATH" == /* && "$RAW_ROM_PATH" != "$ROM_PATH" ]] || \
        die "--raw-output must be an absolute path different from --output."

    NVFLASH_BIN="${NVFLASH_BIN:-$(command -v nvflash 2>/dev/null || command -v nvflash_linux 2>/dev/null || true)}"
    [[ -n "$NVFLASH_BIN" ]] || die "nvflash was not found. Run setup-host or use --nvflash."
    NVFLASH_BIN="$(readlink -f "$NVFLASH_BIN")"
    local nvidia_gpu_count
    nvidia_gpu_count="$(lspci -Dnn | awk '/NVIDIA/ && (/VGA compatible controller/ || /3D controller/) {count++} END {print count+0}')"
    if (( nvidia_gpu_count > 1 && ! NVFLASH_INDEX_SET )); then
        die "Multiple NVIDIA GPUs were detected; inspect nvflash --list and use --nvflash-index."
    fi

    DISPLAY_MANAGER="${DISPLAY_MANAGER:-$(detect_display_manager)}"
    [[ "$DISPLAY_MANAGER" == *.service ]] || DISPLAY_MANAGER="${DISPLAY_MANAGER}.service"
    if [[ "$GPU_SERVICES" == auto ]]; then
        GPU_SERVICES=''
        systemctl list-unit-files lactd.service --no-legend 2>/dev/null | grep -q . && GPU_SERVICES='lactd.service'
    else
        GPU_SERVICES="${GPU_SERVICES//,/ }"
    fi
    local service
    for service in $GPU_SERVICES; do
        [[ "$service" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || die "Invalid service name: $service"
    done

    if [[ -e "$ROM_PATH" || -e "$RAW_ROM_PATH" ]]; then
        warn "The output or raw backup already exists and will be replaced."
        confirm "Replace existing ROM output files?"
    fi
    extract_rom_nvflash "$NVFLASH_BIN" "$NVFLASH_INDEX" "$RAW_ROM_PATH"
    prepare_rom "$RAW_ROM_PATH" "$ROM_PATH"
    log "ROM extraction, hardware verification, and patching completed."
    log "Raw ROM: $RAW_ROM_PATH"
    log "Patched ROM: $ROM_PATH"
}

cmd_create_vm() {
    require_root
    VM_NAME='single-gpu-vm'
    VM_UUID=''
    ISO_PATH=''
    ROM_SOURCE=''
    GPU_BDF=''
    AUDIO_BDF=''
    USB_BDF=''
    SOUND_BDF='auto'
    DISK_PATH=''
    DISK_SIZE='40G'
    MEMORY_MIB='8192'
    VCPUS='4'
    HOST_USER="${SUDO_USER:-}"
    DISPLAY_MANAGER=''
    GPU_SERVICES='auto'
    ASSUME_YES=0
    ALLOW_EXISTING_HOOKS=0

    while (($#)); do
        case "$1" in
            --vm-name) VM_NAME="${2:?}"; shift 2 ;;
            --iso) ISO_PATH="${2:?}"; shift 2 ;;
            --rom) ROM_SOURCE="${2:?}"; shift 2 ;;
            --gpu) GPU_BDF="${2:?}"; shift 2 ;;
            --audio) AUDIO_BDF="${2:?}"; shift 2 ;;
            --sound) SOUND_BDF="${2:?}"; shift 2 ;;
            --usb) USB_BDF="${2:?}"; shift 2 ;;
            --disk) DISK_PATH="${2:?}"; shift 2 ;;
            --disk-size) DISK_SIZE="${2:?}"; shift 2 ;;
            --memory) MEMORY_MIB="${2:?}"; shift 2 ;;
            --vcpus) VCPUS="${2:?}"; shift 2 ;;
            --user) HOST_USER="${2:?}"; shift 2 ;;
            --display-manager) DISPLAY_MANAGER="${2:?}"; shift 2 ;;
            --gpu-services) GPU_SERVICES="${2:?}"; shift 2 ;;
            --yes) ASSUME_YES=1; shift ;;
            --allow-existing-hooks) ALLOW_EXISTING_HOOKS=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown create-vm option: $1" ;;
        esac
    done

    [[ "$VM_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "VM name may contain only letters, digits, dots, underscores, and hyphens."
    [[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || die "--iso must point to an existing installer ISO."
    [[ -n "$ROM_SOURCE" && -f "$ROM_SOURCE" ]] || die "--rom must point to an existing VBIOS file."
    [[ -n "$USB_BDF" ]] || die "--usb must specify a whole USB controller."
    [[ -n "$HOST_USER" && "$HOST_USER" != root ]] || die "Could not determine the desktop user; use --user."
    id "$HOST_USER" >/dev/null 2>&1 || die "User does not exist: $HOST_USER"
    HOST_UID="$(id -u "$HOST_USER")"
    (( HOST_UID > 0 )) || die "Refusing to terminate root sessions."
    [[ "$MEMORY_MIB" =~ ^[0-9]+$ ]] && (( MEMORY_MIB >= 2048 )) || die "--memory must be at least 2048 MiB."
    [[ "$VCPUS" =~ ^[0-9]+$ ]] && (( VCPUS >= 1 )) || die "--vcpus must be a positive integer."
    [[ "$DISK_SIZE" =~ ^[1-9][0-9]*[GMTP]$ ]] || die "Invalid --disk-size (example: 40G)."

    require_command lspci
    require_command virsh
    require_command qemu-img
    require_command virt-xml-validate
    require_command systemd-run
    iommu_active || die "IOMMU is not active. Run setup-host and reboot first."

    GPU_BDF="${GPU_BDF:-$(detect_gpu)}"
    [[ -n "$GPU_BDF" ]] || die "No NVIDIA VGA/3D device was detected; use --gpu."
    GPU_BDF="$(normalize_bdf "$GPU_BDF")"
    AUDIO_BDF="${AUDIO_BDF:-$(detect_gpu_audio "$GPU_BDF")}"
    [[ -n "$AUDIO_BDF" ]] || die "No matching NVIDIA HDMI audio device was found; use --audio."
    AUDIO_BDF="$(normalize_bdf "$AUDIO_BDF")"
    USB_BDF="$(normalize_bdf "$USB_BDF")"
    if [[ "$SOUND_BDF" == auto ]]; then
        SOUND_BDF="$(detect_host_sound || true)"
        if [[ -z "$SOUND_BDF" ]]; then
            SOUND_BDF=none
            warn "No non-NVIDIA PCI sound card was detected; only HDMI/DP audio will be passed through."
        fi
    elif [[ "$SOUND_BDF" != none ]]; then
        SOUND_BDF="$(normalize_bdf "$SOUND_BDF")"
    fi

    local -a devices=("$GPU_BDF" "$AUDIO_BDF" "$USB_BDF")
    [[ "$SOUND_BDF" == none ]] || devices+=("$SOUND_BDF")
    local bdf
    for bdf in "${devices[@]}"; do
        [[ -e "/sys/bus/pci/devices/$bdf" ]] || die "PCI device does not exist: $bdf"
    done
    [[ "$(pci_class "$GPU_BDF")" == 0x0300* || "$(pci_class "$GPU_BDF")" == 0x0302* ]] || die "$GPU_BDF is not a VGA/3D controller."
    [[ "$(pci_class "$AUDIO_BDF")" == 0x0403* ]] || die "$AUDIO_BDF is not an HDA audio device."
    [[ "$(pci_class "$USB_BDF")" == 0x0c03* ]] || die "$USB_BDF is not a USB controller."
    if [[ "$SOUND_BDF" != none ]]; then
        [[ "$SOUND_BDF" != "$AUDIO_BDF" ]] || die "--sound must not duplicate the NVIDIA --audio device."
        [[ "$(pci_class "$SOUND_BDF")" == 0x0403* ]] || die "$SOUND_BDF is not an HDA audio device."
        log "Physical sound card selected for passthrough: $SOUND_BDF"
    fi
    GPU_HOST_DRIVER="$(pci_driver "$GPU_BDF")"
    [[ "$GPU_HOST_DRIVER" == nvidia ]] || die "GPU must use the nvidia driver; current driver: $GPU_HOST_DRIVER"
    AUDIO_HOST_MODULE='snd_hda_intel'
    USB_HOST_MODULE='xhci_pci'

    DISPLAY_MANAGER="${DISPLAY_MANAGER:-$(detect_display_manager)}"
    [[ "$DISPLAY_MANAGER" == *.service ]] || DISPLAY_MANAGER="${DISPLAY_MANAGER}.service"
    if [[ "$GPU_SERVICES" == auto ]]; then
        GPU_SERVICES=''
        systemctl list-unit-files lactd.service --no-legend 2>/dev/null | grep -q . && GPU_SERVICES='lactd.service'
    else
        GPU_SERVICES="${GPU_SERVICES//,/ }"
    fi
    local service
    for service in $GPU_SERVICES; do
        [[ "$service" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || die "Invalid service name: $service"
    done

    if (( ! ALLOW_EXISTING_HOOKS )); then
        local existing=''
        existing="$(rg -l -i 'vfio|nvidia.*unbind|nodedev-detach' /etc/libvirt/hooks 2>/dev/null | grep -vFx "$HOOK_FILE" || true)"
        [[ -z "$existing" ]] || die "Potentially conflicting VFIO hooks were found:\n$existing\nReview them or use --allow-existing-hooks."
    fi

    printf '\nIOMMU groups selected for passthrough:\n'
    show_iommu_group "$GPU_BDF" || true
    show_iommu_group "$AUDIO_BDF" || true
    show_iommu_group "$USB_BDF" || true
    [[ "$SOUND_BDF" == none ]] || show_iommu_group "$SOUND_BDF" || true
    confirm "Can the selected devices be handed off and active group companions be temporarily unbound?"

    DISK_PATH="${DISK_PATH:-/var/lib/libvirt/images/${VM_NAME}.qcow2}"
    [[ "$ISO_PATH" == /* && "$ROM_SOURCE" == /* && "$DISK_PATH" == /* ]] || \
        die "ISO, ROM, and disk paths must be absolute."
    install -d -m 0755 "$(dirname "$DISK_PATH")"
    if [[ ! -e "$DISK_PATH" ]]; then
        qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
    else
        qemu-img check "$DISK_PATH"
        warn "Preserving existing virtual disk: $DISK_PATH"
    fi

    RAW_ROM_PATH="$ROM_SOURCE"
    ROM_PATH="/var/lib/libvirt/vbios/${VM_NAME}.rom"
    prepare_rom "$ROM_SOURCE" "$ROM_PATH"
    find_ovmf
    ensure_default_network

    install -d -m 0755 "$BACKUP_DIR"
    if virsh -c qemu:///system dominfo "$VM_NAME" >/dev/null 2>&1; then
        local domain_state
        domain_state="$(virsh -c qemu:///system domstate "$VM_NAME")"
        [[ "$domain_state" == "shut off" ]] || die "Existing domain $VM_NAME is active."
        VM_UUID="$(virsh -c qemu:///system domuuid "$VM_NAME")"
        virsh -c qemu:///system dumpxml "$VM_NAME" >"$BACKUP_DIR/${VM_NAME}.$(date +%Y%m%d-%H%M%S).xml"
        warn "Updating existing libvirt domain: $VM_NAME"
    fi

    local self_path
    self_path="$(readlink -f "$0")"
    if [[ "$self_path" != "$INSTALLED_TOOL" ]]; then
        install -o root -g root -m 0755 "$self_path" "$INSTALLED_TOOL"
    fi

    local xml_file native_file
    xml_file="$(mktemp /tmp/single-gpu-vfio-domain.XXXXXX.xml)"
    native_file="$(mktemp /tmp/single-gpu-vfio-native.XXXXXX)"
    create_domain_xml "$xml_file"
    virt-xml-validate "$xml_file"
    virsh -c qemu:///system domxml-to-native qemu-argv "$xml_file" >"$native_file"
    if rg -q 'display["=]|x-vga|OVMF_CODE\.secboot' "$native_file"; then
        rm -f "$xml_file" "$native_file"
        die "Generated QEMU arguments contain forbidden display, x-vga, or Secure Boot settings."
    fi
    virsh -c qemu:///system define "$xml_file"
    rm -f "$xml_file" "$native_file"
    write_config
    write_hook
    virsh -c qemu:///system autostart "$VM_NAME" --disable >/dev/null 2>&1 || true
    usermod -a -G libvirt,kvm "$HOST_USER"
    systemctl restart libvirtd.service

    log "VM creation complete."
    printf '\nNext steps:\n  sudo %s check\n  sudo %s test 90\n' "$INSTALLED_TOOL" "$INSTALLED_TOOL"
    printf '\nNormal start:\n  sudo %s start\n' "$INSTALLED_TOOL"
}

main() {
    local command="${1:-help}"
    shift || true
    case "$command" in
        help|-h|--help) usage ;;
        version|--version) printf '%s\n' "$VERSION" ;;
        detect) show_detection ;;
        setup-host) cmd_setup_host "$@" ;;
        extract-rom) cmd_extract_rom "$@" ;;
        create-vm) cmd_create_vm "$@" ;;
        install) die "The install command was split into setup-host, extract-rom, and create-vm. Run $0 help." ;;
        check) cmd_check "$@" ;;
        test) cmd_test "$@" ;;
        start) cmd_start "$@" ;;
        shutdown) cmd_shutdown "$@" ;;
        force-stop) cmd_force_stop "$@" ;;
        recover) cmd_recover "$@" ;;
        eject-iso) cmd_eject_iso "$@" ;;
        status) cmd_status "$@" ;;
        remove) cmd_remove "$@" ;;
        hook) cmd_hook "$@" ;;
        *) die "Unknown command: $command (run $0 help)." ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
