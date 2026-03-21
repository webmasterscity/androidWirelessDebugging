#!/bin/bash
# conectar-android-adb.sh — ADB/config/QR backend for conectar-android
# Usage: conectar-android-adb.sh <command> [args...]

set -uo pipefail

ADB="/home/leonardo/Android/Sdk/platform-tools/adb"
CONFIG_DIR="$HOME/.config/conectar-android"
DEVICES_FILE="$CONFIG_DIR/devices.conf"
LAST_FILE="$CONFIG_DIR/last.conf"
QR_VENV_DIR="$CONFIG_DIR/qr-venv"

mkdir -p "$CONFIG_DIR"

# Migrar configuración antigua si existe
OLD_CONFIG="$HOME/.config/conectar-android.conf"
if [[ -f "$OLD_CONFIG" && ! -f "$LAST_FILE" ]]; then
    source "$OLD_CONFIG"
    echo "LAST_IP=\"$LAST_IP\"" > "$LAST_FILE"
    echo "LAST_PORT=\"$LAST_PORT\"" >> "$LAST_FILE"
    rm -f "$OLD_CONFIG"
fi

# ---------------------------------------------------------------------------

guardar_config() {
    echo "LAST_IP=\"$1\"" > "$LAST_FILE"
    echo "LAST_PORT=\"$2\"" >> "$LAST_FILE"
}

guardar_dispositivo() {
    local nombre="$1"
    local ip="$2"
    local puerto="$3"

    # Eliminar entrada existente con el mismo nombre o IP
    if [[ -f "$DEVICES_FILE" ]]; then
        grep -vE "^${nombre}\||\\|${ip}:" "$DEVICES_FILE" > "${DEVICES_FILE}.tmp" 2>/dev/null
        mv "${DEVICES_FILE}.tmp" "$DEVICES_FILE" 2>/dev/null
    fi

    echo "${nombre}|${ip}:${puerto}" >> "$DEVICES_FILE"
}

obtener_dispositivos_guardados() {
    [[ -f "$DEVICES_FILE" ]] && sort -u "$DEVICES_FILE"
}

obtener_conectados() {
    $ADB devices -l 2>/dev/null | grep -v "List" | while read linea; do
        if [[ "$linea" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+)[[:space:]]+device.*model:([^[:space:]]+) ]]; then
            echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|tcp"
        elif [[ "$linea" =~ ^(adb-[^[:space:]]+)[[:space:]]+device.*model:([^[:space:]]+) ]]; then
            echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|mdns"
        fi
    done
}

desconectar_dispositivo() {
    local addr="$1"
    $ADB disconnect "$addr" 2>&1
}

notificar() {
    notify-send "$1" "$2" -i "${3:-phone}"
}

generar_token() {
    local longitud="$1"
    tr -dc 'a-z0-9' </dev/urandom | head -c "$longitud" || true
}

obtener_python_qr() {
    local venv_python="$QR_VENV_DIR/bin/python"

    if [[ -x "$venv_python" ]] && "$venv_python" -c 'import qrcode' >/dev/null 2>&1; then
        echo "$venv_python"
        return 0
    fi

    if ! command -v python3 &> /dev/null; then
        return 1
    fi

    mkdir -p "$QR_VENV_DIR"

    if [[ ! -x "$venv_python" ]]; then
        python3 -m venv "$QR_VENV_DIR" >/dev/null 2>&1 || return 1
    fi

    "$venv_python" -m pip install qrcode[pil] >/dev/null 2>&1 || return 1

    "$venv_python" -c 'import qrcode' >/dev/null 2>&1 || return 1
    echo "$venv_python"
}

generar_qr_png() {
    local data="$1"
    local output="$2"
    local python_qr="${3:-}"

    if [[ -z "$python_qr" ]]; then
        python_qr="$(obtener_python_qr)" || return 1
    fi

    "$python_qr" - "$data" "$output" <<'PY'
import sys

try:
    import qrcode
    from qrcode.constants import ERROR_CORRECT_M
except Exception as exc:
    print(f"qrcode unavailable: {exc}", file=sys.stderr)
    sys.exit(1)

data = sys.argv[1]
output = sys.argv[2]

qr = qrcode.QRCode(
    version=None,
    error_correction=ERROR_CORRECT_M,
    box_size=10,
    border=2,
)
qr.add_data(data)
qr.make(fit=True)
img = qr.make_image(fill_color="black", back_color="white")
img.save(output)
PY
}

obtener_servicio_mdns_por_nombre() {
    local service_type="$1"
    local service_name="$2"

    $ADB mdns services 2>/dev/null | awk -v type="$service_type" -v name="$service_name" '
        $1 == name && $2 == type { print $3; exit }
    '
}

obtener_servicio_mdns_por_ip() {
    local service_type="$1"
    local ip="$2"

    $ADB mdns services 2>/dev/null | awk -v type="$service_type" -v ip="$ip" '
        $2 == type && index($3, ip ":") == 1 { print $3; exit }
    '
}

esperar_servicio_mdns() {
    local lookup_fn="$1"
    local arg1="$2"
    local arg2="$3"
    local timeout="${4:-60}"
    local elapsed=0
    while (( elapsed < timeout )); do
        local addr
        addr="$("$lookup_fn" "$arg1" "$arg2")"
        if [[ -n "$addr" ]]; then
            echo "$addr"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    return 1
}

buscar_dispositivos() {
    local temp_file=$(mktemp)
    local encontrados=""

    # Dispositivos ya en ADB
    while IFS= read -r linea; do
        if [[ "$linea" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+)[[:space:]]+device ]]; then
            encontrados+="${BASH_REMATCH[1]}|ADB conectado\n"
        fi
    done < <($ADB devices 2>/dev/null | grep -v "List")

    # mDNS
    while IFS= read -r linea; do
        if [[ "$linea" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+) ]]; then
            encontrados+="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}|mDNS\n"
        fi
    done < <($ADB mdns services 2>/dev/null)

    # Fase 1: Escanear IPs de dispositivos guardados en rango completo de puertos.
    # Android wireless debugging usa puertos aleatorios en ~30000-50000 que
    # cambian cada vez, así que una lista fija de puertos no sirve.
    local ips_guardadas=()
    if [[ -f "$DEVICES_FILE" ]]; then
        while IFS='|' read -r _ addr; do
            local saved_ip="${addr%:*}"
            [[ -n "$saved_ip" ]] && ips_guardadas+=("$saved_ip")
        done < "$DEVICES_FILE"
    fi

    for ip in "${ips_guardadas[@]}"; do
        for port in $(seq 30000 50000) 5555; do
            (timeout 0.08 bash -c "echo >/dev/tcp/${ip}/$port" 2>/dev/null && \
                echo "${ip}:${port}" >> "$temp_file") &
            (( port % 1000 == 0 )) && wait
        done
    done

    # Fase 2: Descubrir nuevos dispositivos en la red local (puerto 5555 clásico)
    local redes_base=()
    while IFS= read -r net_ip; do
        local base="${net_ip%.*}"
        [[ -n "$base" && "$base" != "127.0.0" ]] && redes_base+=("$base")
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

    local discovery_ips=(1 2 3 4 5 10 100 101 102 103 104 105 106 107 108 109 110 120 125 130 140 142 145 150 200)
    for red_base in "${redes_base[@]}"; do
        for oct in "${discovery_ips[@]}"; do
            (timeout 0.15 bash -c "echo >/dev/tcp/${red_base}.${oct}/5555" 2>/dev/null && \
                echo "${red_base}.${oct}:5555" >> "$temp_file") &
        done
    done

    wait

    if [[ -s "$temp_file" ]]; then
        while IFS= read -r addr; do
            [[ -n "$addr" ]] && encontrados+="${addr}|Escaneado\n"
        done < "$temp_file"
    fi

    rm -f "$temp_file"
    echo -e "$encontrados" | grep -v "^$" | sort -u || true
}

# ---------------------------------------------------------------------------
# Command dispatcher
# ---------------------------------------------------------------------------

cmd="${1:-}"
shift || true

case "$cmd" in
    connect)
        ip="${1:?connect: se requiere IP}"
        port="${2:?connect: se requiere puerto}"
        resultado=$($ADB connect "${ip}:${port}" 2>&1)
        echo "$resultado"
        if echo "$resultado" | grep -qE "connected|already"; then
            guardar_config "$ip" "$port"
            modelo=$($ADB -s "${ip}:${port}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
            echo "MODEL:${modelo:-Android}"
        else
            exit 1
        fi
        ;;

    disconnect)
        if [[ -n "${1:-}" ]]; then
            desconectar_dispositivo "$1"
        else
            $ADB disconnect 2>&1
        fi
        ;;

    pair-code)
        # Pipes the pairing code via stdin (for manual code entry flow)
        addr="${1:?pair-code: se requiere dirección IP:puerto}"
        code="${2:?pair-code: se requiere código}"
        resultado=$(echo "$code" | $ADB pair "$addr" 2>&1)
        echo "$resultado"
        echo "$resultado" | grep -qiE "success|paired" || exit 1
        ;;

    pair-qr)
        # Passes the pairing code as a CLI argument (for QR-based pairing flow)
        addr="${1:?pair-qr: se requiere dirección IP:puerto}"
        code="${2:?pair-qr: se requiere código}"
        resultado=$($ADB pair "$addr" "$code" 2>&1)
        echo "$resultado"
        echo "$resultado" | grep -qiE "success|paired" || exit 1
        ;;

    devices)
        obtener_conectados
        ;;

    devices-raw)
        $ADB devices -l
        ;;

    devices-saved)
        obtener_dispositivos_guardados
        ;;

    save-device)
        nombre="${1:?save-device: se requiere nombre}"
        ip="${2:?save-device: se requiere IP}"
        port="${3:?save-device: se requiere puerto}"
        guardar_dispositivo "$nombre" "$ip" "$port"
        ;;

    delete-device)
        nombre="${1:?delete-device: se requiere nombre}"
        if [[ -f "$DEVICES_FILE" ]]; then
            grep -v "^${nombre}|" "$DEVICES_FILE" > "${DEVICES_FILE}.tmp" 2>/dev/null || true
            mv "${DEVICES_FILE}.tmp" "$DEVICES_FILE" 2>/dev/null || true
        fi
        ;;

    is-saved)
        ip="${1:?is-saved: se requiere IP}"
        [[ -f "$DEVICES_FILE" ]] && grep -q "|${ip}:" "$DEVICES_FILE"
        ;;

    scan)
        buscar_dispositivos
        ;;

    mdns-wait-name)
        type="${1:?mdns-wait-name: se requiere tipo de servicio}"
        name="${2:?mdns-wait-name: se requiere nombre}"
        timeout="${3:?mdns-wait-name: se requiere timeout}"
        esperar_servicio_mdns obtener_servicio_mdns_por_nombre "$type" "$name" "$timeout"
        ;;

    mdns-wait-ip)
        type="${1:?mdns-wait-ip: se requiere tipo de servicio}"
        ip="${2:?mdns-wait-ip: se requiere IP}"
        timeout="${3:?mdns-wait-ip: se requiere timeout}"
        esperar_servicio_mdns obtener_servicio_mdns_por_ip "$type" "$ip" "$timeout"
        ;;

    gen-qr)
        data="${1:?gen-qr: se requiere data}"
        output="${2:?gen-qr: se requiere ruta de salida PNG}"
        generar_qr_png "$data" "$output"
        ;;

    gen-token)
        length="${1:?gen-token: se requiere longitud}"
        generar_token "$length"
        echo  # newline after token
        ;;

    gen-pair-code)
        code=$(tr -dc '0-9' </dev/urandom | head -c 10 || true)
        echo "$code"
        ;;

    usb-check)
        usb_dev=$($ADB devices 2>/dev/null | grep -v "List" | grep "device$" | grep -v ":" | head -1 | cut -f1)
        if [[ -n "$usb_dev" ]]; then
            dev_ip=$($ADB -s "$usb_dev" shell "ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" 2>/dev/null | tr -d '\r')
            echo "USB:${usb_dev}|IP:${dev_ip:-unknown}"
        else
            exit 1
        fi
        ;;

    usb-setup)
        usb_dev="${1:?usb-setup: se requiere serial USB}"
        ip="${2:?usb-setup: se requiere IP}"
        $ADB -s "$usb_dev" tcpip 5555 2>&1
        sleep 2
        resultado=$($ADB connect "${ip}:5555" 2>&1)
        echo "$resultado"
        if echo "$resultado" | grep -qE "connected|already"; then
            guardar_config "$ip" "5555"
        else
            exit 1
        fi
        ;;

    last-config)
        if [[ -f "$LAST_FILE" ]]; then
            source "$LAST_FILE"
            echo "${LAST_IP:-}:${LAST_PORT:-}"
        else
            echo "192.168.1.145:5555"
        fi
        ;;

    notify)
        title="${1:?notify: se requiere título}"
        msg="${2:?notify: se requiere mensaje}"
        icon="${3:-phone}"
        notificar "$title" "$msg" "$icon"
        ;;

    *)
        echo "conectar-android-adb.sh — ADB backend dispatcher" >&2
        echo "" >&2
        echo "Comandos:" >&2
        echo "  connect <ip> <port>                   Conectar por TCP" >&2
        echo "  disconnect [addr]                     Desconectar uno o todos" >&2
        echo "  pair-code <addr> <code>               Emparejar con código" >&2
        echo "  pair-qr <addr> <code>                 Emparejar con QR" >&2
        echo "  devices                               Listar dispositivos (addr|model|type)" >&2
        echo "  devices-raw                           Salida directa de adb devices -l" >&2
        echo "  devices-saved                         Dispositivos guardados" >&2
        echo "  save-device <name> <ip> <port>        Guardar dispositivo" >&2
        echo "  delete-device <name>                  Eliminar dispositivo guardado" >&2
        echo "  is-saved <ip>                         Verificar si IP está guardada" >&2
        echo "  scan                                  Escanear red" >&2
        echo "  mdns-wait-name <type> <name> <tout>   Esperar mDNS por nombre" >&2
        echo "  mdns-wait-ip <type> <ip> <tout>       Esperar mDNS por IP" >&2
        echo "  gen-qr <data> <output.png>            Generar imagen QR" >&2
        echo "  gen-token <length>                    Generar token aleatorio" >&2
        echo "  gen-pair-code                         Generar código de 10 dígitos" >&2
        echo "  usb-check                             Detectar dispositivo USB" >&2
        echo "  usb-setup <usb_dev> <ip>              Configurar tcpip por USB" >&2
        echo "  last-config                           Última IP:PUERTO" >&2
        echo "  notify <title> <msg> [icon]           Notificación de escritorio" >&2
        exit 1
        ;;
esac
