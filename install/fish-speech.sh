#!/usr/bin/env bash
#
# Fish-Speech Proxmox VM Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Fish-Speech S2-Pro – SOTA Open-Source TTS (Voice-Cloning, 80+ Sprachen, Gradio WebUI)
# Upstream: https://github.com/fishaudio/fish-speech
# Stack:    Python 3.12 + uv + PyTorch 2.8.0 (cpu/cu129) + Gradio (:7860), nativ ohne Docker
# Laeuft:   vollstaendig lokal in einer KVM-VM, keine Cloud noetig
# Host:     DAS SKRIPT LAEUFT AUF DEM PROXMOX-HOST (nicht im Gast!)
# Modus:    VM-first (leistungshungrig: 4B-Modell, 24 GB VRAM empfohlen).
#           Default CPU (funktioniert ueberall, langsam), optional --gpu PCI-ID fuer NVIDIA-Passthrough.
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FishSpeech/main/install/fish-speech.sh)"
#   VMID=150 CORES=6 RAM=16384 DISK=60 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FishSpeech/main/install/fish-speech.sh)"
#   bash fish-speech.sh --vmid 150 --cores 4 --memory 16384 --disk 60 --bridge vmbr0 --debug
#   bash fish-speech.sh --gpu 0000:01:00 --sshkey ~/.ssh/id_rsa.pub   # NVIDIA-Passthrough + Key
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="fish-speech"                               # VM-Name + Service-Name
APP_PORT="7860"                                 # Gradio WebUI
UPSTREAM_REPO="https://github.com/fishaudio/fish-speech"
INSTALLER_REPO="https://github.com/HatchetMan111/FishSpeech"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/FishSpeech/main/systemd/fish-speech.service"

DEFAULT_CORES="4"                               # vCPU (S2-Pro braucht 4+, 8 empfohlen)
DEFAULT_RAM="16384"                             # RAM in MB (16 GB Default, 8 GB Minimum)
DEFAULT_DISK="60"                               # Disk in GB (Modell + Torch + uv-Cache)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE=""                              # leer = auto (bevorzugt local-lvm)
DEFAULT_CIUSER="fish"
DEBIAN_VERSION="12"
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
IMAGE_DIR="/var/lib/vz/template/qcow"

APP_USER="fish"
APP_DIR="/opt/fish-speech"
HF_MODEL="fishaudio/s2-pro"

# Umgebungs-Overrides: VMID=150 CORES=6 RAM=16384 DISK=80 ./fish-speech.sh
VMID_ARG="${VMID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollstaendige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Caller, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Aufrufstapel: ${FUNCNAME[*]:-main}"; msg_error "Vollstaendiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox VM Installer (VM-first, CPU-Default + optionaler NVIDIA-Passthrough)

Usage:
  bash fish-speech.sh [OPTIONEN]
  VMID=150 bash fish-speech.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO}/../../raw/main/install/fish-speech.sh)"

Optionen:
  --vmid ID            VM-ID (Default: naechste freie ID via 'pvesh get /cluster/nextid')
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       Disk-Storage (Default: auto, bevorzugt local-lvm)
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --gpu PCI            NVIDIA-Passthrough, z.B. 0000:01:00 (Default: kein Passthrough = CPU-Modus)
  --sshkey PATH        SSH Public Key fuer Cloud-Init-User (empfohlen, sonst Passwort+sshpass)
  --ciuser NAME        Cloud-Init-User (Default: ${DEFAULT_CIUSER})
  --ip CIDR            statische IP, z.B. 192.168.1.50/24 (Default: dhcp)
  --gateway IP         Gateway bei statischer IP
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
VMID="$VMID_ARG" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="$DEFAULT_STORAGE" BRIDGE="$DEFAULT_BRIDGE" GPU_PCI="" SSHKEY="" CIUSER="$DEFAULT_CIUSER"
IPCFG="dhcp" GATEWAY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --gpu) GPU_PCI="$2"; shift 2;;
    --sshkey|--ssh-key) SSHKEY="$2"; shift 2;;
    --ciuser) CIUSER="$2"; shift 2;;
    --ip) IPCFG="$2"; shift 2;;
    --gateway|--gw) GATEWAY="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

MODE="cpu"
[[ -n "$GPU_PCI" ]] && MODE="cuda"

# ---------------------------------------------------------------------------
# 1. Host-Pruefung
# ---------------------------------------------------------------------------
[[ "$(id -u)" == "0" ]] || { msg_error "Bitte als root auf dem Proxmox-Host ausfuehren."; exit 1; }
command -v qm >/dev/null || { msg_error "qm nicht gefunden – kein Proxmox-Host?"; exit 1; }
command -v pvesh >/dev/null || { msg_error "pvesh nicht gefunden."; exit 1; }
command -v pvesm >/dev/null || { msg_error "pvesm nicht gefunden."; exit 1; }

# Immer naechste freie ID, ausser --vmid gesetzt (Kollision -> ausweichen)
if [[ -z "$VMID" ]]; then
  VMID="$(pvesh get /cluster/nextid)"
  msg_info "Naechste freie VM-ID: $VMID"
else
  if qm status "$VMID" >/dev/null 2>&1; then
    FREE_ID="$(pvesh get /cluster/nextid)"
    msg_warn "VMID $VMID belegt – weiche auf freie ID $FREE_ID aus."
    VMID="$FREE_ID"
  fi
fi

# Storage: Argument > local-lvm (wenn vorhanden) > erstes verfuegbares
if [[ -z "$STORAGE_ARG" ]]; then
  if pvesm status --storage local-lvm >/dev/null 2>&1; then STORAGE_ARG="local-lvm";
  else STORAGE_ARG="$(pvesm status -content images 2>/dev/null | awk 'NR>1 {print $1; exit}')";
  fi
fi
[[ -n "$STORAGE_ARG" ]] || { msg_error "Kein Disk-Storage gefunden."; exit 1; }
msg_info "Storage: $STORAGE_ARG | Bridge: $BRIDGE | Modus: $MODE | VM-Name: $APP"

[[ "$RAM" -ge 8192 ]] || msg_warn "Unter 8192 MB wird S2-Pro kaum starten (gewaehlt: $RAM)."
[[ "$CORES" -ge 4 ]] || msg_warn "Unter 4 vCPU wird Torch sehr langsam (gewaehlt: $CORES)."
[[ "$DISK" -ge 40 ]] || msg_warn "Unter 40 GB wird es mit Modell + Torch eng (gewaehlt: $DISK)."

if [[ -n "$SSHKEY" ]]; then
  [[ -f "$SSHKEY" ]] || { msg_error "SSH-Key nicht gefunden: $SSHKEY"; exit 1; }
fi

# ---------------------------------------------------------------------------
# 2. Cloud-Image sicherstellen
# ---------------------------------------------------------------------------
mkdir -p "$IMAGE_DIR"
IMAGE_FILE="$IMAGE_DIR/debian-${DEBIAN_VERSION}-generic-amd64-${APP}.qcow2"
if [[ ! -s "$IMAGE_FILE" ]]; then
  msg_info "Lade Debian $DEBIAN_VERSION Cloud-Image ..."
  if command -v wget >/dev/null; then wget -O "$IMAGE_FILE" "$IMAGE_URL";
  else curl -fsSL -o "$IMAGE_FILE" "$IMAGE_URL"; fi
else
  msg_ok "Cloud-Image vorhanden: $IMAGE_FILE"
fi

# ---------------------------------------------------------------------------
# 3. VM erstellen (idempotent: existiert die ID, wird nur Gast provisioniert)
# ---------------------------------------------------------------------------
CIPASS=""
if qm status "$VMID" >/dev/null 2>&1; then
  msg_warn "VM $VMID existiert – ueberspringe Erstellung (Update-Modus)."
else
  CIPASS="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)"
  IPCONFIG="ip=dhcp"
  [[ "$IPCFG" != "dhcp" ]] && IPCONFIG="ip=$IPCFG"
  [[ -n "$GATEWAY" ]] && IPCONFIG="$IPCONFIG,gw=$GATEWAY"
  msg_info "Erstelle VM $VMID ($APP): $CORES vCPU / $RAM MB / ${DISK}G ..."
  qm create "$VMID" \
    --name "$APP" --ostype l26 \
    --cores "$CORES" --memory "$RAM" --balloon 0 \
    --agent enabled=1 \
    --onboot 1 \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=${BRIDGE}" \
    --ide2 "${STORAGE_ARG}:cloudinit" \
    --boot order=scsi0 \
    --serial0 socket --vga serial0 \
    --ciuser "$CIUSER" --cipassword "$CIPASS" \
    --ipconfig0 "$IPCONFIG" \
    --nameserver "1.1.1.1 8.8.8.8"
  if [[ -n "$SSHKEY" ]]; then
    qm set "$VMID" --sshkey "$SSHKEY"
  fi
  if [[ -n "$GPU_PCI" ]]; then
    msg_info "Aktiviere GPU-Passthrough $GPU_PCI ..."
    qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1" \
      || msg_warn "hostpci0 fehlgeschlagen – fahre ohne Passthrough fort (CPU-Fallback)."
  fi
  msg_info "Importiere Disk (${DISK}G) ..."
  qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE_ARG"
  UNUSED="$(qm config "$VMID" | grep -oP '^unused0: \K[^,]+' | head -n1)"
  [[ -n "${UNUSED:-}" ]] || { msg_error "unused0 nach importdisk nicht gefunden."; exit 1; }
  qm set "$VMID" --scsi0 "$UNUSED"
  # Disk vergroessern (schlaegt fehl wenn gleich gross – dann nur warnen)
  qm resize "$VMID" scsi0 "${DISK}G" || msg_warn "resize uebersprungen (evtl. bereits $DISK G)."
  msg_ok "VM $VMID erstellt (onboot=1, agent=1)."
  qm start "$VMID" || true
fi

# GPU nachtraeglich sicherstellen (Update-Modus)
if [[ -n "$GPU_PCI" ]]; then
  qm config "$VMID" | grep -q "hostpci0" || qm set "$VMID" --hostpci0 "${GPU_PCI},pcie=1" || true
fi
qm start "$VMID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Gast-IP + SSH warten
# ---------------------------------------------------------------------------
msg_info "Warte auf QEMU-Guest-Agent / SSH (max. 5 Min) ..."
VM_IP=""
for _ in $(seq 1 60); do
  sleep 5
  # Versuch 1: guest-agent
  VM_IP="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | grep -oP '"ip-address"\s*:\s*"\K(?!127\.|::1|fe80)[0-9a-fA-F:.]+' | head -n1 || true)"
  if [[ -z "${VM_IP:-}" ]]; then
    # Versuch 2: qm guest exec hostname -I
    VM_IP="$(qm guest exec "$VMID" -- hostname -I 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  fi
  [[ -n "${VM_IP:-}" ]] && break
done
[[ -n "${VM_IP:-}" ]] || { msg_error "Keine Gast-IP (Guest-Agent). qm guest cmd $VMID ping pruefen."; qm config "$VMID" || true; exit 1; }
msg_ok "Gast-IP: $VM_IP"

SSH_BASE=(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10)
SSH_TARGET="${CIUSER}@${VM_IP}"
if [[ -n "$SSHKEY" ]]; then
  SSH_KEY_PRIV="${SSHKEY%.pub}"
  if [[ -f "$SSH_KEY_PRIV" ]]; then
    SSH_BASE+=( -i "$SSH_KEY_PRIV" )
  fi
  SSH_CMD=("${SSH_BASE[@]}" "$SSH_TARGET")
else
  if command -v sshpass >/dev/null 2>&1 && [[ -n "${CIPASS:-}" ]]; then
    SSH_CMD=(sshpass -p "$CIPASS" "${SSH_BASE[@]}" "$SSH_TARGET")
  else
    msg_warn "Kein --sshkey und kein sshpass: versuche Standard-SSH (ggf. Passwort: ${CIPASS:-<bestehende VM, unveraendert>})."
    SSH_CMD=("${SSH_BASE[@]}" "$SSH_TARGET")
  fi
fi

msg_info "Warte auf SSH ..."
for _ in $(seq 1 30); do
  if "${SSH_CMD[@]}" true >/dev/null 2>&1; then break; fi
  sleep 10
done
"${SSH_CMD[@]}" true || { msg_error "SSH zu $SSH_TARGET fehlgeschlagen. Key/Passwort pruefen (ssh -vvv)."; exit 1; }
msg_ok "SSH bereit: $SSH_TARGET"

# ---------------------------------------------------------------------------
# 5. Fish-Speech im Gast (via SSH, idempotent)
# ---------------------------------------------------------------------------
UV_EXTRA="cpu"
DEVICE_FLAG="cpu"
if [[ "$MODE" == "cuda" ]]; then UV_EXTRA="cu129"; DEVICE_FLAG="cuda"; fi
msg_info "Provisioniere Fish-Speech im Gast (uv --extra $UV_EXTRA, device $DEVICE_FLAG) ..."

"${SSH_CMD[@]}" bash -s -- "$UV_EXTRA" "$DEVICE_FLAG" <<'GUEST_EOF'
set -euo pipefail
UV_EXTRA="$1"
DEVICE_FLAG="$2"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y git curl ca-certificates python3.12 python3.12-venv portaudio19-dev libsox-dev ffmpeg
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
export PATH="$HOME/.local/bin:$PATH"
if [ ! -d /opt/fish-speech/.git ]; then
  sudo rm -rf /opt/fish-speech
  sudo mkdir -p /opt/fish-speech
  sudo chown "$(whoami)":"$(whoami)" /opt/fish-speech
  git clone https://github.com/fishaudio/fish-speech /opt/fish-speech
else
  git -C /opt/fish-speech pull --ff-only || true
fi
test -f /opt/fish-speech/tools/run_webui.py
cd /opt/fish-speech
uv sync --python 3.12 --extra "$UV_EXTRA" || uv sync --python 3.12 --extra cpu
# Modell best-effort laden (Fehler = nur Warnung, Service startet trotzdem)
if [ ! -f /opt/fish-speech/checkpoints/s2-pro/model.safetensors ]; then
  .venv/bin/python -m huggingface_hub.cli download fishaudio/s2-pro --local-dir /opt/fish-speech/checkpoints/s2-pro || echo "WARN: Modell-Download fehlgeschlagen – manuell nachholen, siehe README."
fi
GUEST_EOF

# systemd-Unit aus Installer-Repo uebernehmen (Fallback: Inline-Unit)
if "${SSH_CMD[@]}" "curl -fsSL -o /tmp/fish-speech.service '$SERVICE_URL'"; then
  msg_ok "fish-speech.service aus Repo uebernommen."
  "${SSH_CMD[@]}" "sudo mv /tmp/fish-speech.service /etc/systemd/system/fish-speech.service"
else
  msg_warn "Service-URL nicht erreichbar – schreibe Inline-Unit."
  "${SSH_CMD[@]}" "sudo tee /etc/systemd/system/fish-speech.service" <<UNIT
[Unit]
Description=Fish-Speech S2-Pro WebUI (Gradio :7860)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CIUSER}
WorkingDirectory=${APP_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=GRADIO_SERVER_NAME=0.0.0.0
Environment=GRADIO_SERVER_PORT=${APP_PORT}
ExecStart=${APP_DIR}/.venv/bin/python tools/run_webui.py --device ${DEVICE_FLAG}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
fi

# GPU-Modus: ExecStart auf cuda umstellen (CPU-Unit ist Default aus Repo)
if [[ "$MODE" == "cuda" ]]; then
  "${SSH_CMD[@]}" "sudo sed -i 's/--device cpu/--device cuda/' /etc/systemd/system/fish-speech.service"
fi

"${SSH_CMD[@]}" "sudo systemctl daemon-reload"
"${SSH_CMD[@]}" "sudo systemctl enable --now fish-speech"

# ---------------------------------------------------------------------------
# 6. Verifikation: Service + Web UI
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
"${SSH_CMD[@]}" "systemctl is-active fish-speech" || { msg_error "systemd-Service fish-speech ist nicht active."; "${SSH_CMD[@]}" "systemctl status fish-speech --no-pager" || true; exit 1; }
msg_ok "Service laeuft (systemctl is-active fish-speech = active)."

msg_info "Warte auf Web UI (max. 10 Min, erster Start laedt 4B-Modell) ..."
WEB_OK=0
for _ in $(seq 1 60); do
  if "${SSH_CMD[@]}" "curl -fs -m 10 'http://localhost:${APP_PORT}/' >/dev/null 2>&1"; then WEB_OK=1; break; fi
  sleep 10
done
[[ "$WEB_OK" == "1" ]] \
  || { msg_error "Web UI antwortet nicht auf localhost:${APP_PORT}/."; "${SSH_CMD[@]}" "systemctl status fish-speech --no-pager" || true; "${SSH_CMD[@]}" "journalctl -u fish-speech --no-pager -n 100" || true; exit 1; }
msg_ok "Web UI antwortet (HTTP 200 auf localhost:${APP_PORT}/)."

qm config "$VMID" | grep -q "onboot: 1" && msg_ok "onboot=1 gesetzt." || msg_warn "onboot nicht 1 – bitte pruefen."

echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Fish-Speech S2-Pro – SOTA Open-Source TTS"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  VM           : $VMID (Name: $APP, onboot=1, Modus: $MODE)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : http://${VM_IP}:${APP_PORT}"
echo "  SSH          : ssh ${CIUSER}@${VM_IP}"
echo "  CIPasswort   : ${CIPASS:-<bestehende VM, unveraendert>} (nur jetzt angezeigt!)"
echo "  Service      : systemctl status fish-speech  (im Gast)"
echo "  Modell       : $HF_MODEL nach /opt/fish-speech/checkpoints/s2-pro"
echo "  Update       : Skript erneut laufen lassen (idempotent, git pull + uv sync + restart)"
echo "  Deinstall    : qm stop $VMID && qm destroy $VMID"
echo "  Reboot-Test  : qm reboot $VMID && sleep 120 && curl -fs http://${VM_IP}:${APP_PORT}/"
echo "  Log          : $LOG_FILE"
echo "══════════════════════════════════════════════════════════"
