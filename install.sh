#!/bin/bash
# ============================================================================
# Instalador de Android Wireless Debugging
# ============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/.local/share/applications"
QR_VENV_DIR="$HOME/.config/conectar-android/qr-venv"

# Detectar directorio del escritorio (soporta diferentes idiomas)
if command -v xdg-user-dir &> /dev/null; then
    DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null)"
fi
# Fallback si xdg-user-dir no funciona
if [[ -z "$DESKTOP_DIR" || ! -d "$DESKTOP_DIR" ]]; then
    for dir in "$HOME/Desktop" "$HOME/Escritorio" "$HOME/Bureau" "$HOME/Schreibtisch"; do
        if [[ -d "$dir" ]]; then
            DESKTOP_DIR="$dir"
            break
        fi
    done
fi

print_header() {
    echo -e "${BLUE}"
    echo "=============================================="
    echo "   Android Wireless Debugging - Instalador"
    echo "=============================================="
    echo -e "${NC}"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

preparar_soporte_qr() {
    local venv_python="$QR_VENV_DIR/bin/python"

    if [[ -x "$venv_python" ]] && "$venv_python" -c 'import qrcode' >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v python3 &> /dev/null; then
        return 1
    fi

    mkdir -p "$(dirname "$QR_VENV_DIR")"

    if [[ ! -x "$venv_python" ]]; then
        python3 -m venv "$QR_VENV_DIR" >/dev/null 2>&1 || return 1
    fi

    "$venv_python" -m pip install --upgrade pip >/dev/null 2>&1 || true
    "$venv_python" -m pip install qrcode[pil] >/dev/null 2>&1 || return 1
    "$venv_python" -c 'import qrcode' >/dev/null 2>&1
}

# Desinstalar
uninstall() {
    print_header
    echo "Desinstalando Android Wireless Debugging..."
    echo ""

    for f in conectar-android.sh conectar-android-adb.sh conectar-android-gui.py; do
        if [[ -f "$INSTALL_DIR/$f" ]]; then
            rm -f "$INSTALL_DIR/$f"
            print_success "$f eliminado"
        fi
    done

    if [[ -f "$APPS_DIR/conectar-android.desktop" ]]; then
        rm -f "$APPS_DIR/conectar-android.desktop"
        print_success "Acceso directo del menú eliminado"
    fi

    if [[ -n "$DESKTOP_DIR" && -f "$DESKTOP_DIR/conectar-android.desktop" ]]; then
        rm -f "$DESKTOP_DIR/conectar-android.desktop"
        print_success "Acceso directo del escritorio eliminado"
    fi

    if [[ -f "$HOME/.config/conectar-android.conf" ]]; then
        read -p "¿Eliminar configuración guardada? [s/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            rm -f "$HOME/.config/conectar-android.conf"
            print_success "Configuración eliminada"
        fi
    fi

    echo ""
    print_success "Desinstalación completada"
    exit 0
}

# Verificar argumento --uninstall
if [[ "$1" == "--uninstall" || "$1" == "-u" ]]; then
    uninstall
fi

# Instalación
print_header

# Verificar que estamos en el directorio correcto
for f in conectar-android.sh conectar-android-adb.sh conectar-android-gui.py; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        print_error "No se encontró $f en el directorio del proyecto"
        print_info "Ejecuta este script desde el directorio del proyecto"
        exit 1
    fi
done

echo "Este script instalará:"
echo "  - Launcher + backend ADB + GUI GTK4 en ~/.local/bin/"
echo "  - Acceso directo en el menú de aplicaciones"
echo "  - Acceso directo en el escritorio (un clic para conectar)"
echo "  - Soporte QR en un entorno privado de Python"
echo ""

# Verificar e instalar dependencias
echo "Verificando dependencias..."
echo ""

DEPS_MISSING=0
ADB_MISSING=0
QR_MISSING=0

# ADB
if command -v adb &> /dev/null; then
    print_success "ADB encontrado: $(which adb)"
elif [[ -f "$HOME/Android/Sdk/platform-tools/adb" ]]; then
    print_success "ADB encontrado: $HOME/Android/Sdk/platform-tools/adb"
else
    print_warning "ADB no encontrado"
    DEPS_MISSING=1
    ADB_MISSING=1
fi

# Python3 + GTK4/Adwaita (requerido para la GUI)
if python3 -c "import gi; gi.require_version('Gtk','4.0'); gi.require_version('Adw','1')" 2>/dev/null; then
    print_success "Python3 + GTK4 + Adwaita encontrados"
else
    print_warning "Python3 con GTK4/Adwaita no encontrado (requerido para la GUI)"
    DEPS_MISSING=1
fi

# Soporte QR vía Python
if preparar_soporte_qr; then
    print_success "Soporte QR preparado en $QR_VENV_DIR"
else
    print_warning "No se pudo preparar soporte QR automáticamente"
    QR_MISSING=1
fi

# notify-send
if command -v notify-send &> /dev/null; then
    print_success "notify-send encontrado"
else
    print_warning "notify-send no encontrado (opcional, para notificaciones)"
fi

echo ""

# Ofrecer instalar dependencias faltantes
if [[ $DEPS_MISSING -eq 1 ]]; then
    print_warning "Faltan dependencias necesarias"
    echo ""

    # Detectar gestor de paquetes
    if command -v apt &> /dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL="sudo apt install -y"
        PACKAGES="adb python3-gi gir1.2-adw-1 libnotify-bin"
    elif command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="sudo dnf install -y"
        PACKAGES="android-tools python3-gobject gtk4 libadwaita libnotify"
    elif command -v pacman &> /dev/null; then
        PKG_MGR="pacman"
        PKG_INSTALL="sudo pacman -S --noconfirm"
        PACKAGES="android-tools python-gobject gtk4 libadwaita libnotify"
    elif command -v zypper &> /dev/null; then
        PKG_MGR="zypper"
        PKG_INSTALL="sudo zypper install -y"
        PACKAGES="android-tools python3-gobject gtk4 libadwaita libnotify-tools"
    else
        print_error "No se detectó un gestor de paquetes conocido"
        print_info "Instala las dependencias manualmente antes de continuar"
        exit 1
    fi

    read -p "¿Instalar dependencias automáticamente? ($PKG_MGR) [S/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        print_info "Instalando dependencias..."
        $PKG_INSTALL $PACKAGES
        print_success "Dependencias instaladas"
    else
        print_warning "Continuando sin instalar dependencias"
        if [[ $ADB_MISSING -eq 1 ]]; then
            print_info "La aplicación puede no funcionar correctamente sin ADB"
        fi
        if [[ $QR_MISSING -eq 1 ]]; then
            print_info "La opción de emparejamiento por QR no estará disponible"
        fi
    fi
fi

echo ""
echo "Instalando..."
echo ""

# Crear directorios
mkdir -p "$INSTALL_DIR"
mkdir -p "$APPS_DIR"

# Copiar scripts
cp "$SCRIPT_DIR/conectar-android.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/conectar-android.sh"
print_success "Launcher instalado en $INSTALL_DIR/conectar-android.sh"

cp "$SCRIPT_DIR/conectar-android-adb.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/conectar-android-adb.sh"
print_success "Backend ADB instalado en $INSTALL_DIR/conectar-android-adb.sh"

cp "$SCRIPT_DIR/conectar-android-gui.py" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/conectar-android-gui.py"
print_success "GUI GTK4 instalada en $INSTALL_DIR/conectar-android-gui.py"

# Crear archivo .desktop con ruta correcta
DESKTOP_CONTENT="[Desktop Entry]
Version=1.0
Type=Application
Name=Conectar Android
Name[es]=Conectar Android
Comment=Connect Android device via WiFi debugging
Comment[es]=Conectar dispositivo Android por WiFi
Exec=$INSTALL_DIR/conectar-android.sh
Icon=phone
Terminal=false
Categories=Development;Utility;
Keywords=android;adb;wireless;debug;wifi;"

# Instalar en menú de aplicaciones
echo "$DESKTOP_CONTENT" > "$APPS_DIR/conectar-android.desktop"
chmod +x "$APPS_DIR/conectar-android.desktop"
print_success "Acceso directo en menú de aplicaciones instalado"

# Instalar en escritorio
if [[ -n "$DESKTOP_DIR" && -d "$DESKTOP_DIR" ]]; then
    echo "$DESKTOP_CONTENT" > "$DESKTOP_DIR/conectar-android.desktop"
    chmod +x "$DESKTOP_DIR/conectar-android.desktop"
    # En GNOME, marcar como confiable para que sea ejecutable
    if command -v gio &> /dev/null; then
        gio set "$DESKTOP_DIR/conectar-android.desktop" metadata::trusted true 2>/dev/null || true
    fi
    print_success "Acceso directo en escritorio instalado ($DESKTOP_DIR)"
else
    print_warning "No se pudo detectar el directorio del escritorio"
fi

# Actualizar base de datos de aplicaciones
if command -v update-desktop-database &> /dev/null; then
    update-desktop-database "$APPS_DIR" 2>/dev/null || true
fi

# Verificar que ~/.local/bin está en PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    print_warning "~/.local/bin no está en tu PATH"
    print_info "Agrega esta línea a tu ~/.bashrc o ~/.zshrc:"
    echo ""
    echo '    export PATH="$HOME/.local/bin:$PATH"'
    echo ""
    print_info "O ejecuta: source ~/.bashrc"
fi

echo ""
echo -e "${GREEN}=============================================="
echo "   Instalacion completada exitosamente!"
echo "==============================================${NC}"
echo ""
echo "Puedes usar la aplicacion de estas formas:"
echo ""
echo "  1. Doble clic en 'Conectar Android' en tu escritorio"
echo "  2. Busca 'Conectar Android' en el menu de aplicaciones"
echo "  3. Ejecuta: conectar-android.sh"
echo "  4. Desde 'Emparejar', elige código o QR"
echo ""
echo "Para desinstalar: ./install.sh --uninstall"
echo ""
