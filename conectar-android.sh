#!/bin/bash
# Conectar dispositivo Android por WiFi - Con soporte multi-dispositivo

ADB="/home/leonardo/Android/Sdk/platform-tools/adb"
CONFIG_DIR="$HOME/.config/conectar-android"
DEVICES_FILE="$CONFIG_DIR/devices.conf"
LAST_FILE="$CONFIG_DIR/last.conf"
DEFAULT_IP="192.168.1.145"
DEFAULT_PORT="5555"

# Crear directorio de configuración
mkdir -p "$CONFIG_DIR"

# Migrar configuración antigua si existe
OLD_CONFIG="$HOME/.config/conectar-android.conf"
if [[ -f "$OLD_CONFIG" && ! -f "$LAST_FILE" ]]; then
    source "$OLD_CONFIG"
    echo "LAST_IP=\"$LAST_IP\"" > "$LAST_FILE"
    echo "LAST_PORT=\"$LAST_PORT\"" >> "$LAST_FILE"
    rm -f "$OLD_CONFIG"
fi

# Cargar última conexión
if [[ -f "$LAST_FILE" ]]; then
    source "$LAST_FILE"
    LAST_IP="${LAST_IP:-$DEFAULT_IP}"
    LAST_PORT="${LAST_PORT:-$DEFAULT_PORT}"
else
    LAST_IP="$DEFAULT_IP"
    LAST_PORT="$DEFAULT_PORT"
fi

# Modo línea de comandos
if [[ "$1" == "--disconnect" || "$1" == "-d" ]]; then
    if [[ -n "$2" ]]; then
        $ADB disconnect "$2"
    else
        $ADB disconnect
        echo "Todos los dispositivos desconectados"
    fi
    exit 0
fi

if [[ "$1" == "--list" || "$1" == "-l" ]]; then
    echo "=== Dispositivos conectados ==="
    $ADB devices -l
    echo ""
    echo "=== Dispositivos guardados ==="
    [[ -f "$DEVICES_FILE" ]] && cat "$DEVICES_FILE" || echo "(ninguno)"
    exit 0
fi

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Uso: $0 [opciones]"
    echo ""
    echo "Opciones:"
    echo "  -d, --disconnect [IP:PUERTO]  Desconectar dispositivo (o todos si no se especifica)"
    echo "  -l, --list                    Listar dispositivos conectados y guardados"
    echo "  -h, --help                    Mostrar esta ayuda"
    echo ""
    echo "Sin opciones: Abre la interfaz gráfica"
    exit 0
fi

# Guardar último dispositivo usado
guardar_config() {
    echo "LAST_IP=\"$1\"" > "$LAST_FILE"
    echo "LAST_PORT=\"$2\"" >> "$LAST_FILE"
}

# Guardar dispositivo con nombre
guardar_dispositivo() {
    local nombre="$1"
    local ip="$2"
    local puerto="$3"

    # Eliminar entrada existente con el mismo nombre o IP
    if [[ -f "$DEVICES_FILE" ]]; then
        grep -v "^${nombre}|" "$DEVICES_FILE" | grep -v "|${ip}:" > "${DEVICES_FILE}.tmp" 2>/dev/null
        mv "${DEVICES_FILE}.tmp" "$DEVICES_FILE" 2>/dev/null
    fi

    echo "${nombre}|${ip}:${puerto}" >> "$DEVICES_FILE"
}

# Obtener dispositivos guardados
obtener_dispositivos_guardados() {
    [[ -f "$DEVICES_FILE" ]] && cat "$DEVICES_FILE" | sort -u
}

# Obtener dispositivos conectados actualmente
obtener_conectados() {
    $ADB devices -l 2>/dev/null | grep -v "List" | while read linea; do
        if [[ "$linea" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+)[[:space:]]+device.*model:([^[:space:]]+) ]]; then
            echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|tcp"
        elif [[ "$linea" =~ ^(adb-[^[:space:]]+)[[:space:]]+device.*model:([^[:space:]]+) ]]; then
            echo "${BASH_REMATCH[1]}|${BASH_REMATCH[2]}|mdns"
        fi
    done
}

# Desconectar un dispositivo
desconectar_dispositivo() {
    local addr="$1"
    $ADB disconnect "$addr" 2>&1
}

notificar() {
    notify-send "$1" "$2" -i "${3:-phone}"
}

# Búsqueda rápida
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

    # Escaneo rápido
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
        --text="En tu teléfono ve a:\n\n  📱 Configuración\n  → Opciones de desarrollador\n  → Depuración inalámbrica\n  → Emparejar dispositivo con código\n\nIngresa la IP:Puerto de emparejamiento que aparece:" \
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
        # Extraer IP para guardarla
        local paired_ip="${pair_addr%:*}"
        guardar_config "$paired_ip" "$LAST_PORT"

        zenity --info --title="✓ Emparejado" \
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

# Verificar USB primero
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

# Sin USB - mostrar diálogo
if ! command -v zenity &> /dev/null; then
    resultado=$($ADB connect "${LAST_IP}:${LAST_PORT}" 2>&1)
    [[ "$resultado" =~ connected|already ]] && notificar "Conectado" "${LAST_IP}:${LAST_PORT}" || notificar "Error" "$resultado" "dialog-error"
    exit 0
fi

while true; do
    # Obtener dispositivos conectados para mostrar estado
    conectados=$(obtener_conectados)
    num_conectados=$(echo "$conectados" | grep -c "." 2>/dev/null || echo 0)

    # Construir texto informativo
    if [[ $num_conectados -gt 0 ]]; then
        info_conectados="Dispositivos conectados: $num_conectados"
    else
        info_conectados="Sin dispositivos conectados"
    fi

    # Diálogo principal con más opciones
    seleccion=$(zenity --entry \
        --title="Conectar Android por WiFi" \
        --text="$info_conectados\n\nIngresa IP:PUERTO de conexión:\n(Configuración → Depuración inalámbrica → IP y puerto)" \
        --entry-text="${LAST_IP}:${LAST_PORT}" \
        --extra-button="📱 Gestionar" \
        --extra-button="🔗 Emparejar" \
        --extra-button="🔍 Buscar" \
        --ok-label="Conectar" \
        --cancel-label="Cancelar" \
        --width=420 \
        2>&1)

    codigo=$?

    # Botón Gestionar dispositivos
    if [[ "$seleccion" == "📱 Gestionar" ]]; then
        while true; do
            # Construir lista de dispositivos conectados
            conectados=$(obtener_conectados)
            guardados=$(obtener_dispositivos_guardados)

            lista_zenity=()

            # Añadir dispositivos conectados
            while IFS='|' read -r addr modelo tipo; do
                [[ -z "$addr" ]] && continue
                lista_zenity+=("TRUE" "🟢 $addr" "$modelo" "Conectado ($tipo)")
            done <<< "$conectados"

            # Añadir dispositivos guardados (no conectados)
            while IFS='|' read -r nombre addr; do
                [[ -z "$nombre" ]] && continue
                # Verificar si ya está en la lista de conectados
                if ! echo "$conectados" | grep -q "^${addr}|"; then
                    lista_zenity+=("FALSE" "⚪ $addr" "$nombre" "Guardado")
                fi
            done <<< "$guardados"

            if [[ ${#lista_zenity[@]} -eq 0 ]]; then
                zenity --info --title="Sin dispositivos" \
                    --text="No hay dispositivos conectados ni guardados.\n\nUsa 'Buscar' o 'Emparejar' para añadir uno." \
                    --width=350 2>/dev/null
                break
            fi

            accion=$(zenity --list \
                --title="Gestionar Dispositivos" \
                --text="Selecciona dispositivos y elige una acción:\n🟢 = Conectado  ⚪ = Guardado" \
                --checklist \
                --column="Sel" --column="Dirección" --column="Nombre/Modelo" --column="Estado" \
                "${lista_zenity[@]}" \
                --width=550 --height=350 \
                --extra-button="🔌 Desconectar sel." \
                --extra-button="🗑️ Eliminar guardado" \
                --extra-button="❌ Desconectar TODOS" \
                --ok-label="Conectar sel." \
                --cancel-label="Volver" \
                --separator="|" \
                --print-column=2 2>&1)

            ret=$?

            if [[ "$accion" == "❌ Desconectar TODOS" ]]; then
                $ADB disconnect 2>/dev/null
                notificar "Desconectado" "Todos los dispositivos desconectados" "phone"
                continue
            fi

            if [[ "$accion" == "🔌 Desconectar sel." ]]; then
                # Leer seleccionados del último comando
                seleccionados=$(zenity --list \
                    --title="Desconectar" \
                    --text="Selecciona dispositivos a desconectar:" \
                    --checklist \
                    --column="Sel" --column="Dirección" --column="Nombre/Modelo" --column="Estado" \
                    "${lista_zenity[@]}" \
                    --width=500 --height=300 \
                    --ok-label="Desconectar" \
                    --cancel-label="Cancelar" \
                    --separator="|" \
                    --print-column=2 2>&1)

                if [[ -n "$seleccionados" ]]; then
                    IFS='|' read -ra addrs <<< "$seleccionados"
                    for addr in "${addrs[@]}"; do
                        # Limpiar el emoji del inicio
                        addr_limpio=$(echo "$addr" | sed 's/^[🟢⚪ ]*//')
                        $ADB disconnect "$addr_limpio" 2>/dev/null
                    done
                    notificar "Desconectado" "Dispositivos seleccionados desconectados" "phone"
                fi
                continue
            fi

            if [[ "$accion" == "🗑️ Eliminar guardado" ]]; then
                # Mostrar solo guardados para eliminar
                lista_guardados=()
                while IFS='|' read -r nombre addr; do
                    [[ -z "$nombre" ]] && continue
                    lista_guardados+=("FALSE" "$nombre" "$addr")
                done <<< "$guardados"

                if [[ ${#lista_guardados[@]} -eq 0 ]]; then
                    zenity --info --text="No hay dispositivos guardados." --width=250 2>/dev/null
                    continue
                fi

                eliminar=$(zenity --list \
                    --title="Eliminar Guardados" \
                    --text="Selecciona dispositivos a eliminar:" \
                    --checklist \
                    --column="Sel" --column="Nombre" --column="Dirección" \
                    "${lista_guardados[@]}" \
                    --width=400 --height=250 \
                    --separator="|" \
                    --print-column=2 2>&1)

                if [[ -n "$eliminar" ]]; then
                    IFS='|' read -ra nombres <<< "$eliminar"
                    for nombre in "${nombres[@]}"; do
                        grep -v "^${nombre}|" "$DEVICES_FILE" > "${DEVICES_FILE}.tmp" 2>/dev/null
                        mv "${DEVICES_FILE}.tmp" "$DEVICES_FILE" 2>/dev/null
                    done
                    notificar "Eliminado" "Dispositivos eliminados de guardados" "edit-delete"
                fi
                continue
            fi

            # Cancelar o Volver
            [[ $ret -eq 1 ]] && break

            # Conectar seleccionados (botón OK)
            if [[ -n "$accion" ]]; then
                IFS='|' read -ra addrs <<< "$accion"
                for addr in "${addrs[@]}"; do
                    addr_limpio=$(echo "$addr" | sed 's/^[🟢⚪ ]*//')
                    # Si ya está conectado, saltar
                    if [[ "$addr" == *"🟢"* ]]; then
                        continue
                    fi
                    resultado=$($ADB connect "$addr_limpio" 2>&1)
                    if echo "$resultado" | grep -qE "connected|already"; then
                        ip_parte="${addr_limpio%:*}"
                        puerto_parte="${addr_limpio##*:}"
                        guardar_config "$ip_parte" "$puerto_parte"
                        notificar "Conectado" "$addr_limpio" "phone"
                    fi
                done
                break
            fi
        done
        continue
    fi

    # Botón Emparejar
    if [[ "$seleccion" == "🔗 Emparejar" ]]; then
        emparejar_dispositivo
        continue
    fi

    # Botón Buscar
    if [[ "$seleccion" == "🔍 Buscar" ]]; then
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

    # Obtener modelo del dispositivo conectado
    modelo=$($ADB -s "${target_ip}:${puerto}" shell getprop ro.product.model 2>/dev/null | tr -d '\r')
    [[ -z "$modelo" ]] && modelo="Android"

    notificar "Android Conectado" "Conectado a ${target_ip}:${puerto} ($modelo)" "phone"

    # Verificar si ya está guardado
    if [[ -f "$DEVICES_FILE" ]] && grep -q "|${target_ip}:" "$DEVICES_FILE"; then
        : # Ya guardado, no hacer nada
    else
        # Preguntar si desea guardar
        nombre_sugerido="$modelo"
        guardar=$(zenity --entry \
            --title="Guardar Dispositivo" \
            --text="¿Guardar este dispositivo para acceso rápido?\n\nIP: ${target_ip}:${puerto}\nModelo: $modelo\n\nIngresa un nombre (o cancela para no guardar):" \
            --entry-text="$nombre_sugerido" \
            --ok-label="Guardar" \
            --cancel-label="No guardar" \
            --width=380 2>/dev/null)

        if [[ -n "$guardar" ]]; then
            guardar_dispositivo "$guardar" "$target_ip" "$puerto"
            notificar "Guardado" "Dispositivo '$guardar' guardado" "document-save"
        fi
    fi
else
    # Ofrecer emparejar si falla
    zenity --question \
        --title="Error de Conexión" \
        --text="No se pudo conectar a ${target_ip}:${puerto}\n\n¿El dispositivo está emparejado?\nPresiona 'Sí' para emparejar ahora." \
        --ok-label="Sí, emparejar" \
        --cancel-label="No, cancelar" \
        --width=350 2>/dev/null

    if [[ $? -eq 0 ]]; then
        emparejar_dispositivo && exec "$0"  # Reiniciar script después de emparejar
    fi
fi
