#!/bin/bash
# Conectar dispositivo Android por WiFi - Launcher

ADB_BACKEND="$HOME/.local/bin/conectar-android-adb.sh"

# CLI flags — delegados al backend
if [[ "${1:-}" == "--disconnect" || "${1:-}" == "-d" ]]; then
    "$ADB_BACKEND" disconnect "${2:-}"
    exit $?
fi

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    echo "=== Dispositivos conectados ==="
    "$ADB_BACKEND" devices-raw
    echo ""
    echo "=== Dispositivos guardados ==="
    "$ADB_BACKEND" devices-saved || echo "(ninguno)"
    exit 0
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Uso: $0 [opciones]"
    echo ""
    echo "Opciones:"
    echo "  -d, --disconnect [IP:PUERTO]  Desconectar dispositivo (o todos)"
    echo "  -l, --list                    Listar dispositivos"
    echo "  -h, --help                    Mostrar esta ayuda"
    echo ""
    echo "Sin opciones: Abre la interfaz gráfica"
    exit 0
fi

# Modo GUI — lanzar Python GTK4
exec python3 "$HOME/.local/bin/conectar-android-gui.py" "$@"
