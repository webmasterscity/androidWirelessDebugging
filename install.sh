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
DESKTOP_DIR="$HOME/.local/share/applications"

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

# Desinstalar
uninstall() {
    print_header
    echo "Desinstalando Android Wireless Debugging..."
    echo ""

    if [[ -f "$INSTALL_DIR/conectar-android.sh" ]]; then
        rm -f "$INSTALL_DIR/conectar-android.sh"
        print_success "Script eliminado"
    fi

    if [[ -f "$DESKTOP_DIR/conectar-android.desktop" ]]; then
        rm -f "$DESKTOP_DIR/conectar-android.desktop"
        print_success "Acceso directo eliminado"
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
if [[ ! -f "$SCRIPT_DIR/conectar-android.sh" ]]; then
    print_error "No se encontró conectar-android.sh en el directorio actual"
    print_info "Ejecuta este script desde el directorio del proyecto"
    exit 1
fi

echo "Este script instalará:"
echo "  - Script principal en ~/.local/bin/"
echo "  - Acceso directo en el menú de aplicaciones"
echo ""

# Verificar e instalar dependencias
echo "Verificando dependencias..."
echo ""

DEPS_MISSING=0

# ADB
if command -v adb &> /dev/null; then
    print_success "ADB encontrado: $(which adb)"
elif [[ -f "$HOME/Android/Sdk/platform-tools/adb" ]]; then
    print_success "ADB encontrado: $HOME/Android/Sdk/platform-tools/adb"
else
    print_warning "ADB no encontrado"
    DEPS_MISSING=1
fi

# Zenity
if command -v zenity &> /dev/null; then
    print_success "Zenity encontrado"
else
    print_warning "Zenity no encontrado (opcional, para interfaz gráfica)"
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
        PACKAGES="adb zenity libnotify-bin"
    elif command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="sudo dnf install -y"
        PACKAGES="android-tools zenity libnotify"
    elif command -v pacman &> /dev/null; then
        PKG_MGR="pacman"
        PKG_INSTALL="sudo pacman -S --noconfirm"
        PACKAGES="android-tools zenity libnotify"
    elif command -v zypper &> /dev/null; then
        PKG_MGR="zypper"
        PKG_INSTALL="sudo zypper install -y"
        PACKAGES="android-tools zenity libnotify-tools"
    else
        print_error "No se detectó un gestor de paquetes conocido"
        print_info "Instala ADB manualmente antes de continuar"
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
        print_info "La aplicación puede no funcionar correctamente sin ADB"
    fi
fi

echo ""
echo "Instalando..."
echo ""

# Crear directorios
mkdir -p "$INSTALL_DIR"
mkdir -p "$DESKTOP_DIR"

# Copiar script principal
cp "$SCRIPT_DIR/conectar-android.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/conectar-android.sh"
print_success "Script instalado en $INSTALL_DIR/conectar-android.sh"

# Crear archivo .desktop con ruta correcta
cat > "$DESKTOP_DIR/conectar-android.desktop" << EOF
[Desktop Entry]
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
Keywords=android;adb;wireless;debug;wifi;
EOF
chmod +x "$DESKTOP_DIR/conectar-android.desktop"
print_success "Acceso directo instalado"

# Actualizar base de datos de aplicaciones
if command -v update-desktop-database &> /dev/null; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
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
echo "   Instalación completada exitosamente!"
echo "==============================================${NC}"
echo ""
echo "Puedes usar la aplicación de estas formas:"
echo ""
echo "  1. Busca 'Conectar Android' en el menú de aplicaciones"
echo "  2. Ejecuta: conectar-android.sh"
echo ""
echo "Para desinstalar: ./install.sh --uninstall"
echo ""
