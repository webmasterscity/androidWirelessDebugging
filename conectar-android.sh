#!/bin/bash
# ============================================================================
# Android Wireless Debugging - Conectar dispositivo Android por WiFi
# ============================================================================
# Autor: Leonardo (webmasterscity)
# Repositorio: https://github.com/webmasterscity/androidWirelessDebugging
# Licencia: MIT
# ============================================================================
# Soporta:
#   - Conexión automática vía USB (habilita WiFi debugging)
#   - Conexión directa por IP:Puerto
#   - Emparejamiento de nuevos dispositivos
#   - Búsqueda automática de dispositivos en la red local
# ============================================================================

# Detectar ADB automáticamente
if command -v adb &> /dev/null; then
    ADB="adb"
elif [[ -f "$HOME/Android/Sdk/platform-tools/adb" ]]; then
    ADB="$HOME/Android/Sdk/platform-tools/adb"
elif [[ -f "/usr/bin/adb" ]]; then
    ADB="/usr/bin/adb"
else
    if command -v zenity &> /dev/null; then
        zenity --error --title="Error" \
            --text="ADB no encontrado.\n\nInstálalo con:\nsudo apt install adb\n\nO instala Android Studio." \
            --width=350 2>/dev/null
    else
        echo "ERROR: ADB no encontrado. Instálalo con: sudo apt install adb"
    fi
    exit 1
fi

CONFIG_FILE="$HOME/.config/conectar-android.conf"
DEFAULT_IP="192.168.1.100"
DEFAULT_PORT="5555"

# Cargar última conexión guardada
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    LAST_IP="${LAST_IP:-$DEFAULT_IP}"
    LAST_PORT="${LAST_PORT:-$DEFAULT_PORT}"
else
    LAST_IP="$DEFAULT_IP"
    LAST_PORT="$DEFAULT_PORT"
fi

guardar_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo "LAST_IP=\"$1\"" > "$CONFIG_FILE"
    echo "LAST_PORT=\"$2\"" >> "$CONFIG_FILE"
}

notificar() {
    if command -v notify-send &> /dev/null; then
        notify-send "$1" "$2" -i "${3:-phone}"
    else
        echo "$1: $2"
    fi
}

# Búsqueda de dispositivos en la red
buscar_dispositivos() {
    local temp_file=$(mktemp)
    local encontrados=""

    # Dispositivos ya conectados en ADB
    while IFS= read -r linea; do
        if [[ "$linea" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+)[[:space:]]+device ]]; then
            encontrados+="${BASH_REMATCH[1]}|ADB conectado\n"
        fi
    done < <($ADB devices 2>/dev/null | grep -v "List")

    # Servicios mDNS
    while IFS= read -r linea; do
        if [[ "$linea" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+) ]]; then
            encontrados+="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}|mDNS\n"
        fi
    done < <($ADB mdns services 2>/dev/null)

    # Escaneo rápido de red local
    local mi_ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    local red_base="${mi_ip%.*}"

    if [[ -n "$red_base" ]]; then
        local ips=(1 2 3 4 5 10 100 101 102 103 104 105 106 107 108 109 110 145 200)
        local puertos=(5555 43543 37000 41000 43000 44000 45000)

        for oct in "${ips[@]}"; do
            for puerto in "${puertos[@]}"; do
                (timeout 0.15 bash -c "echo >/dev/tcp/${red_base}.${oct}/$puerto" 2>/dev/null && \
                    echo "${red_base}.${oct}:${puerto}" >> "$temp_file") &
            done
        done
        wait

        if [[ -s "$temp_file" ]]; then
            while IFS= read -r addr; do
                [[ -n "$addr" ]] && encontrados+="${addr}|Escaneado\n"
            done < "$temp_file"
        fi
    fi

    rm -f "$temp_file"
    echo -e "$encontrados" | grep -v "^$" | sort -u
}

# Función de emparejamiento
emparejar_dispositivo() {
    # Paso 1: Pedir IP:Puerto
    local pair_addr=$(zenity --entry \
        --title="Emparejar Android - Paso 1/2" \
        --text="En tu teléfono ve a:\n\n  Configuración\n  → Opciones de desarrollador\n  → Depuración inalámbrica\n  → Emparejar dispositivo con código\n\nIngresa la IP:Puerto de emparejamiento que aparece:" \
        --entry-text="${LAST_IP}:37000" \
        --ok-label="Siguiente" \
        --cancel-label="Cancelar" \
        --width=450 \
        2>&1)

    [[ -z "$pair_addr" || $? -eq 1 ]] && return 1

    # Paso 2: Pedir código
    local pair_code=$(zenity --entry \
        --title="Emparejar Android - Paso 2/2" \
        --text="Ingresa el código de 6 dígitos que aparece en tu teléfono:" \
        --entry-text="" \
        --ok-label="Emparejar" \
        --cancel-label="Cancelar" \
        --width=400 \
        2>&1)

    [[ -z "$pair_code" || $? -eq 1 ]] && return 1

    notificar "Emparejando..." "Conectando a $pair_addr" "network-wireless"

    # Ejecutar adb pair
    resultado=$(echo "$pair_code" | $ADB pair "$pair_addr" 2>&1)

    if echo "$resultado" | grep -qiE "success|paired"; then
        local paired_ip="${pair_addr%:*}"
        guardar_config "$paired_ip" "$LAST_PORT"

        zenity --info --title="Emparejado" \
            --text="Dispositivo emparejado correctamente.\n\nAhora conecta usando el puerto de CONEXIÓN\n(es diferente al de emparejamiento).\n\nBúscalo en: Depuración inalámbrica → IP y puerto" \
            --width=400 2>/dev/null
        notificar "Emparejado" "Dispositivo emparejado correctamente" "phone"
        return 0
    else
        zenity --error --title="Error de Emparejamiento" \
            --text="No se pudo emparejar:\n\n$resultado\n\nVerifica:\n• El código sea correcto\n• No haya expirado (tienen tiempo límite)" \
            --width=420 2>/dev/null
        return 1
    fi
}

# ============================================================================
# FLUJO PRINCIPAL
# ============================================================================

# Verificar si hay dispositivo conectado por USB primero
usb_device=$($ADB devices 2>/dev/null | grep -v "List" | grep "device$" | grep -v ":" | head -1 | cut -f1)

if [ -n "$usb_device" ]; then
    notificar "Configurando WiFi" "Habilitando desde USB..." "network-wireless"

    device_ip=$($ADB -s "$usb_device" shell "ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1" 2>/dev/null | tr -d '\r')
    [[ -z "$device_ip" ]] && device_ip=$LAST_IP

    $ADB -s "$usb_device" tcpip 5555 2>&1
    sleep 2

    resultado=$($ADB connect "${device_ip}:5555" 2>&1)

    if echo "$resultado" | grep -qE "connected|already"; then
        guardar_config "$device_ip" "5555"
        notificar "Conectado" "${device_ip}:5555 - Puedes desconectar USB" "phone"
    else
        notificar "Error" "$resultado" "dialog-error"
    fi
    exit 0
fi

# Sin USB - mostrar diálogo interactivo
if ! command -v zenity &> /dev/null; then
    # Modo terminal sin GUI
    resultado=$($ADB connect "${LAST_IP}:${LAST_PORT}" 2>&1)
    if [[ "$resultado" =~ connected|already ]]; then
        notificar "Conectado" "${LAST_IP}:${LAST_PORT}"
    else
        notificar "Error" "$resultado" "dialog-error"
    fi
    exit 0
fi

while true; do
    # Diálogo principal
    seleccion=$(zenity --entry \
        --title="Conectar Android por WiFi" \
        --text="Ingresa IP:PUERTO de conexión:\n(Configuración → Depuración inalámbrica → IP y puerto)\n\nSi es la primera vez, presiona 'Emparejar' primero." \
        --entry-text="${LAST_IP}:${LAST_PORT}" \
        --extra-button="Emparejar" \
        --extra-button="Buscar" \
        --ok-label="Conectar" \
        --cancel-label="Cancelar" \
        --width=420 \
        2>&1)

    codigo=$?

    # Botón Emparejar
    if [[ "$seleccion" == "Emparejar" ]]; then
        emparejar_dispositivo
        continue
    fi

    # Botón Buscar
    if [[ "$seleccion" == "Buscar" ]]; then
        buscar_dispositivos > /tmp/android_scan_result.txt &
        SEARCH_PID=$!

        (
            i=0
            while kill -0 $SEARCH_PID 2>/dev/null; do
                echo $((i % 100))
                echo "# Buscando dispositivos Android..."
                sleep 0.3
                ((i+=10))
            done
            echo 100
        ) | zenity --progress \
            --title="Buscando" \
            --text="Escaneando red local..." \
            --percentage=0 \
            --auto-close \
            --width=300 \
            2>/dev/null

        if [[ $? -eq 1 ]]; then
            kill $SEARCH_PID 2>/dev/null
            pkill -P $SEARCH_PID 2>/dev/null
            continue
        fi

        wait $SEARCH_PID 2>/dev/null
        dispositivos=$(cat /tmp/android_scan_result.txt 2>/dev/null)
        rm -f /tmp/android_scan_result.txt

        if [[ -n "$dispositivos" ]]; then
            lista_zenity=()
            while IFS='|' read -r addr desc; do
                [[ -z "$addr" ]] && continue
                lista_zenity+=("$addr" "$desc")
            done <<< "$dispositivos"

            elegido=$(zenity --list \
                --title="Dispositivos Encontrados" \
                --text="Selecciona uno:" \
                --column="Dirección" --column="Fuente" \
                "${lista_zenity[@]}" \
                --width=420 --height=300 \
                --print-column=1 2>/dev/null)

            if [[ -n "$elegido" ]]; then
                LAST_IP="${elegido%:*}"
                LAST_PORT="${elegido##*:}"
            fi
        else
            zenity --warning --title="Sin resultados" \
                --text="No se encontraron dispositivos.\n\n¿Primera vez? Presiona 'Emparejar' primero." \
                --width=300 2>/dev/null
        fi
        continue
    fi

    # Cancelar
    [[ $codigo -eq 1 ]] && exit 0

    # Conectar
    if [[ -n "$seleccion" && "$seleccion" == *":"* ]]; then
        target_ip="${seleccion%:*}"
        puerto="${seleccion##*:}"
    else
        target_ip="$LAST_IP"
        puerto="$LAST_PORT"
    fi

    break
done

# Intentar conexión
resultado=$($ADB connect "${target_ip}:${puerto}" 2>&1)

if echo "$resultado" | grep -qE "connected|already"; then
    guardar_config "$target_ip" "$puerto"
    notificar "Android Conectado" "Conectado a ${target_ip}:${puerto}" "phone"
else
    # Ofrecer emparejar si falla
    zenity --question \
        --title="Error de Conexión" \
        --text="No se pudo conectar a ${target_ip}:${puerto}\n\n¿El dispositivo está emparejado?\nPresiona 'Sí' para emparejar ahora." \
        --ok-label="Sí, emparejar" \
        --cancel-label="No, cancelar" \
        --width=350 2>/dev/null

    if [[ $? -eq 0 ]]; then
        emparejar_dispositivo && exec "$0"
    fi
fi
