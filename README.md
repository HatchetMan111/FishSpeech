# Fish-Speech auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil, VM-first)

> Upstream-App (kein Teil dieses Ordners): `https://github.com/fishaudio/fish-speech`
> (Fish Audio S2-Pro, 4B Dual-AR, 80+ Sprachen, Voice-Cloning)
> Dieser Ordner enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft nativ (Python 3.12 + uv + PyTorch, ohne Docker) – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FishSpeech/main/install/fish-speech.sh)"
```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
VMID=150 CORES=8 RAM=16384 DISK=60 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/FishSpeech/main/install/fish-speech.sh)"
bash fish-speech.sh --vmid 150 --cores 4 --memory 16384 --disk 60 --bridge vmbr0 --storage local-lvm
# Neuinstallation mit statischer IP (empfohlen wenn DHCP klemmt, z.B. FritzBox-Netz):
bash fish-speech.sh --ip 192.168.178.50/24 --gateway 192.168.178.1
bash fish-speech.sh --gpu 0000:01:00 --sshkey ~/.ssh/id_rsa.pub   # NVIDIA-Passthrough (sonst CPU-Modus)
bash fish-speech.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/fish-speech-install-*.log
```

| Eigenschaft | Wert |
|---|---|
| App-Name / VM-Name | `fish-speech` |
| Zweck | SOTA Open-Source TTS – Text-to-Speech, Voice-Cloning (10–30 s Referenz), Emotion-Tags (`[whisper]`, `[excited]` …), Gradio WebUI |
| Tech-Stack | Python 3.12 + `uv sync --extra cpu` (Default) / `--extra cu129` (GPU) + PyTorch 2.8.0 + Gradio `:7860`, venv `/opt/fish-speech/.venv` |
| GitHub-Repo (Upstream) | `https://github.com/fishaudio/fish-speech` |
| Web UI | `http://<VM-IP>:7860` (Gradio, `GRADIO_SERVER_NAME=0.0.0.0`) |
| Standard-Ressourcen | 4 vCPU / 16384 MB RAM / 60 GB Disk (Minimum 4 / 8192 / 40; GPU-Empfehlung 24 GB VRAM) |
| VM-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--vmid` gesetzt (Kollision → ausweichen) |
| Template | Debian-12 Cloud-Image (`cloud.debian.org`, `generic-amd64.qcow2` nach `/var/lib/vz/template/qcow`) |
| VM-Features | QEMU-Guest-Agent, `onboot: 1`, `--hostpci0 …,pcie=1` nur bei `--gpu` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie VM-ID, erkennt Disk-Storage
   (bevorzugt `local-lvm`), lädt das Debian-12-Cloud-Image falls nötig,
2. erstellt die VM `fish-speech` (`onboot: 1`, Cloud-Init-User `fish`, SSH-Key optional),
   optional GPU-Passthrough, `qm importdisk + resize + start`,
3. wartet auf Guest-Agent-IP + SSH, installiert im Gast Systemdeps
   (`portaudio19-dev libsox-dev ffmpeg`), `uv`, klont/pullt `fishaudio/fish-speech`
   nach `/opt/fish-speech`, `uv sync --extra cpu/cu129`, lädt best-effort
   `fishaudio/s2-pro` nach `checkpoints/s2-pro`, schreibt `fish-speech.service`,
   `systemctl enable --now fish-speech`,
4. verifiziert `systemctl is-active fish-speech` + HTTP auf `localhost:7860/`
   (Poll bis 10 Min – erster Start lädt 4B-Modell) und gibt die finale URL + VM-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active fish-speech = active).
[OK]    Web UI antwortet (HTTP 200 auf localhost:7860/).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Fish-Speech S2-Pro – SOTA Open-Source TTS
  VM           : 100 (Name: fish-speech, onboot=1, Modus: cpu)
  Ressourcen   : 4 vCPU / 16384 MB RAM / 60 GB Disk
  Web UI       : http://192.168.1.100:7860
  ...
  Log          : /tmp/fish-speech-install-2026-....log
══════════════════════════════════════════════════════════
```

## Reboot-Test (Reboot-sicher belegen)

```bash
VM=100
qm reboot $VM
sleep 120
qm guest exec $VM -- systemctl is-active fish-speech
curl -fs http://<VM-IP>:7860/ >/dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash fish-speech.sh --vmid 100            # Update: idempotent (git pull + uv sync + restart)
qm stop 100 && qm destroy 100             # Deinstall
```

Modell manuell nachladen (falls best-effort-Download im Gast fehlschlug):

```bash
ssh fish@<VM-IP>
cd /opt/fish-speech
.venv/bin/python -m huggingface_hub.cli download fishaudio/s2-pro --local-dir checkpoints/s2-pro
sudo systemctl restart fish-speech
```

GPU nachträglich: `bash fish-speech.sh --vmid 100 --gpu 0000:01:00` (stellt auf `cu129` + `--device cuda` um).

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code + Aufrufstapel aus, Voll-Log unter `/tmp/fish-speech-install-*.log`.
- `bash fish-speech.sh --debug` für `bash -x`-Trace.
- Im Gast: `systemctl status fish-speech --no-pager`, `journalctl -u fish-speech -n 100`.

## Troubleshooting: Keine Gast-IP (Guest-Agent)

Symptom: `Keine Gast-IP (Guest-Agent)` nach 10 Min, `qm config` zeigt `agent: enabled=1`.

1. Agent-Status prüfen:
```bash
qm agent 108 ping
qm guest cmd 108 network-get-interfaces
qm status 108
```
2. Häufigste Ursachen: Cloud-Init Erstboot dauert (Thin-Pool-Warnung = langsamer Storage),
   DHCP auf `vmbr0` antwortet nicht, oder `qemu-guest-agent` im Gast läuft noch nicht.
   Das Script versucht Agent + ARP/DHCP-Fallback (per Gast-MAC) – bleibt beides leer,
   hat der Gast schlicht kein Netz.
3. Konsole öffnen und im Gast prüfen:
```bash
qm terminal 108
# im Gast:
systemctl status qemu-guest-agent --no-pager
ip -4 addr show
```
4. Schnellweg ohne Warten: bekannte/statische IP direkt übergeben –
   überspringt den Agent-Wait komplett:
```bash
bash fish-speech.sh --vmid 108 --ip 192.168.1.50
```
5. Danach Update-Modus erneut laufen lassen (idempotent, VM bleibt bestehen):
```bash
bash fish-speech.sh --vmid 108
```

## Dateien

- `install/fish-speech.sh` – Proxmox-Einzeiler (Host, root, `qm` + SSH-Provision).
- `systemd/fish-speech.service` – Gradio-Unit (`:7860`, `After=network-online.target`, `Restart=always`).
