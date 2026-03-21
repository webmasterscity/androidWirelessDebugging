#!/usr/bin/env python3
"""Conectar Android - GUI GTK4/Adwaita."""

import os
import subprocess
import threading
import tempfile
from concurrent.futures import ThreadPoolExecutor

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, GLib

ADB_BACKEND = os.path.expanduser("~/.local/bin/conectar-android-adb.sh")


def run_adb(cmd, *args, timeout=30):
    """Ejecutar comando del backend ADB y retornar (exitcode, stdout)."""
    try:
        result = subprocess.run(
            [ADB_BACKEND, cmd, *args],
            capture_output=True, text=True, timeout=timeout
        )
        return result.returncode, result.stdout.strip()
    except subprocess.TimeoutExpired:
        return 1, "Timeout"
    except Exception as e:
        return 1, f"{type(e).__name__}: {e}"


def run_adb_async(cmd, *args, timeout=30, callback=None):
    """Ejecutar comando ADB en hilo separado, callback en main thread."""
    def worker():
        rc, out = run_adb(cmd, *args, timeout=timeout)
        if callback:
            GLib.idle_add(callback, rc, out)
    threading.Thread(target=worker, daemon=True).start()


def parse_pipe_lines(text):
    """Parse pipe-delimited lines into a dict (first field -> second field)."""
    result = {}
    for line in text.splitlines():
        parts = line.split("|")
        if len(parts) >= 2:
            result[parts[0]] = parts[1]
    return result


class ConnectAndroidApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id="com.leonardo.conectar_android")
        self.connect("activate", self.on_activate)

    def on_activate(self, app):
        # Verificar USB primero
        rc, out = run_adb("usb-check")
        if rc == 0:
            # USB detectado — configurar automáticamente
            parts = {}
            for p in out.split("|"):
                if ":" in p:
                    k, v = p.split(":", 1)
                    parts[k] = v
            usb_dev = parts.get("USB", "")
            dev_ip = parts.get("IP", "")
            if usb_dev and dev_ip and dev_ip != "unknown":
                run_adb("usb-setup", usb_dev, dev_ip, timeout=10)
                run_adb("notify", "Conectado por USB",
                         f"{dev_ip}:5555 - Puedes desconectar USB",
                         "phone")
                self.quit()  # Terminar la app limpiamente, no dejar proceso zombie
                return

        self.win = MainWindow(application=app)
        self.win.present()


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, **kwargs):
        super().__init__(**kwargs, title="Conectar Android", default_width=460, default_height=580)

        self.toast_overlay = Adw.ToastOverlay()
        self.set_content(self.toast_overlay)

        main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.toast_overlay.set_child(main_box)

        # Header bar
        header = Adw.HeaderBar()
        main_box.append(header)

        # Contenido con scroll
        scroll = Gtk.ScrolledWindow(vexpand=True)
        main_box.append(scroll)

        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        content.set_margin_top(16)
        content.set_margin_bottom(16)
        content.set_margin_start(16)
        content.set_margin_end(16)
        scroll.set_child(content)

        # --- Sección: Conectar ---
        connect_group = Adw.PreferencesGroup(title="Conexión rápida")
        content.append(connect_group)

        # Entry IP:Puerto
        self.entry_row = Adw.EntryRow(title="IP:Puerto")
        rc, last = run_adb("last-config")
        self.entry_row.set_text(last if rc == 0 else "192.168.1.145:5555")
        self.entry_row.connect("entry-activated", lambda _: self.on_connect())
        connect_group.add(self.entry_row)

        # Botón conectar
        connect_btn = Gtk.Button(label="Conectar", css_classes=["suggested-action"])
        connect_btn.set_margin_top(8)
        connect_btn.connect("clicked", lambda _: self.on_connect())
        content.append(connect_btn)

        # --- Sección: Dispositivos ---
        self.devices_group = Adw.PreferencesGroup(title="Dispositivos")
        content.append(self.devices_group)

        self.devices = []  # list of {"row": Adw.ActionRow, "addr": str, "name": str, "is_connected": bool, "check": Gtk.CheckButton}
        self.spinner = Gtk.Spinner()
        self.spinner.set_visible(False)
        content.append(self.spinner)

        # --- Botones de acción sobre dispositivos ---
        dev_actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8, homogeneous=True)
        content.append(dev_actions)

        btn_disconnect_sel = Gtk.Button(label="Desconectar sel.")
        btn_disconnect_sel.connect("clicked", lambda _: self.on_disconnect_selected())
        dev_actions.append(btn_disconnect_sel)

        btn_delete_sel = Gtk.Button(label="Eliminar sel.", css_classes=["destructive-action"])
        btn_delete_sel.connect("clicked", lambda _: self.on_delete_selected())
        dev_actions.append(btn_delete_sel)

        # --- Sección: Herramientas ---
        tools_group = Adw.PreferencesGroup(title="Herramientas")
        content.append(tools_group)

        pair_code_row = Adw.ActionRow(title="Emparejar por código",
                                       subtitle="Ingresa IP:puerto y código de 6 dígitos",
                                       activatable=True)
        pair_code_row.add_suffix(Gtk.Image.new_from_icon_name("dialog-password-symbolic"))
        pair_code_row.connect("activated", lambda _: self.on_pair_code())
        tools_group.add(pair_code_row)

        pair_qr_row = Adw.ActionRow(title="Emparejar por QR",
                                     subtitle="Genera un QR para escanear desde el teléfono",
                                     activatable=True)
        pair_qr_row.add_suffix(Gtk.Image.new_from_icon_name("camera-photo-symbolic"))
        pair_qr_row.connect("activated", lambda _: self.on_pair_qr())
        tools_group.add(pair_qr_row)

        scan_row = Adw.ActionRow(title="Buscar en red",
                                  subtitle="Escanea la red local buscando dispositivos",
                                  activatable=True)
        scan_row.add_suffix(Gtk.Image.new_from_icon_name("edit-find-symbolic"))
        scan_row.connect("activated", lambda _: self.on_scan())
        tools_group.add(scan_row)

        disconnect_all_row = Adw.ActionRow(title="Desconectar todos",
                                            subtitle="Desconecta todos los dispositivos ADB",
                                            activatable=True)
        disconnect_all_row.add_suffix(Gtk.Image.new_from_icon_name("process-stop-symbolic"))
        disconnect_all_row.connect("activated", lambda _: self.on_disconnect_all())
        tools_group.add(disconnect_all_row)

        # Cargar dispositivos al iniciar
        self.refresh_devices()

    def _run_in_thread(self, fn, on_done=None):
        """Run fn in a background thread. Call on_done on main thread when finished."""
        def worker():
            fn()
            if on_done:
                GLib.idle_add(on_done)
        threading.Thread(target=worker, daemon=True).start()

    def refresh_devices(self):
        self.set_busy(True)

        def fetch():
            with ThreadPoolExecutor(max_workers=2) as pool:
                f1 = pool.submit(run_adb, "devices")
                f2 = pool.submit(run_adb, "devices-saved")
                rc1, connected_out = f1.result()
                rc2, saved_out = f2.result()
            GLib.idle_add(self._populate_devices, connected_out if rc1 == 0 else "", saved_out if rc2 == 0 else "")

        threading.Thread(target=fetch, daemon=True).start()

    def _populate_devices(self, connected_out, saved_out):
        self.set_busy(False)

        for dev in self.devices:
            self.devices_group.remove(dev["row"])
        self.devices.clear()

        connected = parse_pipe_lines(connected_out) if connected_out else {}
        saved = parse_pipe_lines(saved_out) if saved_out else {}

        for addr, model in connected.items():
            row = Adw.ActionRow(title=addr, subtitle=f"{model} — Conectado")
            row.add_prefix(Gtk.Image.new_from_icon_name("emblem-ok-symbolic"))
            check = Gtk.CheckButton()
            row.add_suffix(check)
            self.devices_group.add(row)
            self.devices.append({"row": row, "addr": addr, "name": model, "is_connected": True, "check": check})

        for name, addr in saved.items():
            if addr not in connected:
                row = Adw.ActionRow(title=addr, subtitle=f"{name} — Guardado")
                row.add_prefix(Gtk.Image.new_from_icon_name("computer-symbolic"))
                connect_btn = Gtk.Button(label="Conectar", valign=Gtk.Align.CENTER,
                                         css_classes=["suggested-action", "pill"])
                connect_btn.connect("clicked", lambda _, a=addr: self.quick_connect(a))
                row.add_suffix(connect_btn)
                check = Gtk.CheckButton()
                row.add_suffix(check)
                self.devices_group.add(row)
                self.devices.append({"row": row, "addr": addr, "name": name, "is_connected": False, "check": check})

        if not self.devices:
            row = Adw.ActionRow(title="Sin dispositivos",
                                subtitle="Usa Conectar, Emparejar o Buscar para añadir uno")
            self.devices_group.add(row)
            self.devices.append({"row": row, "addr": "", "name": "", "is_connected": False, "check": None})

    # --- Conectar ---
    def on_connect(self):
        text = self.entry_row.get_text().strip()
        if ":" in text:
            ip, port = text.rsplit(":", 1)
        else:
            ip, port = text, "5555"

        self.set_busy(True)
        run_adb_async("connect", ip, port, callback=lambda rc, out: self._on_connected(rc, out, ip, port))

    def _on_connected(self, rc, out, ip, port):
        self.set_busy(False)
        if rc == 0:
            # Extraer modelo del output
            model = "Android"
            for line in out.splitlines():
                if line.startswith("MODEL:"):
                    model = line[6:]
            self.refresh_devices()

            def post_connect():
                run_adb("notify", "Conectado", f"{ip}:{port} ({model})", "phone")
                rc2, _ = run_adb("is-saved", ip)
                if rc2 != 0:
                    GLib.idle_add(self.ask_save_device, ip, port, model)

            threading.Thread(target=post_connect, daemon=True).start()
        else:
            self.show_toast(f"Error: {out}")
            self.ask_pair_after_fail(ip, port)

    def quick_connect(self, addr):
        self.entry_row.set_text(addr)
        self.on_connect()

    # --- Emparejar por código ---
    def on_pair_code(self):
        dialog = Adw.AlertDialog(
            heading="Emparejar por código",
            body="En tu teléfono: Configuración → Opciones de desarrollador → Depuración inalámbrica → Emparejar dispositivo con código"
        )

        # Contenido extra con entries
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_margin_top(8)

        addr_entry = Adw.EntryRow(title="IP:Puerto de emparejamiento")
        current = self.entry_row.get_text().strip()
        last_ip = current.rsplit(":", 1)[0] if ":" in current else "192.168.1.145"
        addr_entry.set_text(f"{last_ip}:37000")

        code_entry = Adw.EntryRow(title="Código de 6 dígitos")

        group = Adw.PreferencesGroup()
        group.add(addr_entry)
        group.add(code_entry)
        box.append(group)

        dialog.set_extra_child(box)
        dialog.add_response("cancel", "Cancelar")
        dialog.add_response("pair", "Emparejar")
        dialog.set_response_appearance("pair", Adw.ResponseAppearance.SUGGESTED)

        dialog.connect("response", lambda d, resp: self._on_pair_code_response(
            resp, addr_entry.get_text().strip(), code_entry.get_text().strip()))
        dialog.present(self)

    def _on_pair_code_response(self, response, addr, code):
        if response != "pair" or not addr or not code:
            return
        self.set_busy(True)
        run_adb_async("pair-code", addr, code, callback=lambda rc, out: self._on_paired(rc, out, addr))

    def _on_paired(self, rc, out, pair_addr):
        if rc == 0:
            self.show_toast("Emparejado correctamente, conectando...")

            def post_pair():
                paired_ip = pair_addr.rsplit(":", 1)[0]
                rc2, connect_addr = run_adb("mdns-wait-ip", "_adb-tls-connect._tcp", paired_ip, "8")
                if rc2 == 0 and connect_addr:
                    ip, port = connect_addr.rsplit(":", 1)
                    run_adb("connect", ip, port)
                    GLib.idle_add(self.entry_row.set_text, connect_addr)
                run_adb("notify", "Emparejado", "Dispositivo emparejado correctamente", "phone")
                GLib.idle_add(self._on_paired_done)

            threading.Thread(target=post_pair, daemon=True).start()
        else:
            self.set_busy(False)
            self.show_toast(f"Error emparejando: {out}")

    def _on_paired_done(self):
        self.set_busy(False)
        self.refresh_devices()

    # --- Emparejar por QR ---
    def on_pair_qr(self):
        self.set_busy(True)

        def generate_qr():
            _, pair_name = run_adb("gen-token", "10")
            pair_name = f"studio-{pair_name}"
            _, pair_code = run_adb("gen-pair-code")
            qr_data = f"WIFI:T:ADB;S:{pair_name};P:{pair_code};;"

            with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
                qr_file = tmp.name
            rc, _ = run_adb("gen-qr", qr_data, qr_file)
            GLib.idle_add(self._on_qr_generated, rc, pair_name, pair_code, qr_file)

        threading.Thread(target=generate_qr, daemon=True).start()

    def _on_qr_generated(self, rc, pair_name, pair_code, qr_file):
        self.set_busy(False)

        if rc != 0:
            try:
                os.unlink(qr_file)
            except OSError:
                pass
            self.show_toast("Error generando QR")
            return

        # Mostrar diálogo con QR
        dialog = Adw.AlertDialog(
            heading="Emparejar por QR",
            body="En tu teléfono: Configuración → Opciones de desarrollador → Depuración inalámbrica → Emparejar con código QR\n\nEscanea este QR:"
        )

        # Imagen QR
        qr_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        qr_box.set_halign(Gtk.Align.CENTER)
        qr_box.set_margin_top(12)

        qr_picture = Gtk.Picture.new_for_filename(qr_file)
        qr_picture.set_size_request(280, 280)
        qr_picture.set_content_fit(Gtk.ContentFit.CONTAIN)
        qr_box.append(qr_picture)

        dialog.set_extra_child(qr_box)
        dialog.add_response("cancel", "Cancelar")
        dialog.add_response("scanned", "Ya escaneé")
        dialog.set_response_appearance("scanned", Adw.ResponseAppearance.SUGGESTED)

        dialog.connect("response", lambda d, resp: self._on_qr_scanned(
            resp, pair_name, pair_code, qr_file))
        dialog.present(self)

    def _on_qr_scanned(self, response, pair_name, pair_code, qr_file):
        try:
            os.unlink(qr_file)
        except OSError:
            pass

        if response != "scanned":
            return

        self.set_busy(True)
        self.show_toast("Esperando emparejamiento QR...")

        def worker():
            rc, pair_addr = run_adb("mdns-wait-name", "_adb-tls-pairing._tcp", pair_name, "90")
            if rc != 0 or not pair_addr:
                GLib.idle_add(self._on_qr_timeout)
                return
            rc, out = run_adb("pair-qr", pair_addr, pair_code)
            GLib.idle_add(self._on_paired, rc, out, pair_addr)

        threading.Thread(target=worker, daemon=True).start()

    def _on_qr_timeout(self):
        self.set_busy(False)
        self.show_toast("No se detectó el escaneo del QR. Inténtalo de nuevo.")

    # --- Buscar en red ---
    def on_scan(self):
        self.set_busy(True)
        self.show_toast("Escaneando red local...")
        run_adb_async("scan", timeout=60, callback=self._on_scan_done)

    def _on_scan_done(self, rc, out):
        self.set_busy(False)
        if out:
            parsed = parse_pipe_lines(out)
            found = list(parsed.items())
            if found:
                if len(found) == 1:
                    self.entry_row.set_text(found[0][0])
                    self.show_toast("1 dispositivo encontrado")
                    self.refresh_devices()
                    return
                # Mostrar diálogo de selección con todos los resultados
                dialog = Adw.AlertDialog(heading="Dispositivos encontrados",
                                          body="Selecciona uno para conectar:")
                group = Adw.PreferencesGroup()
                scan_entries = []  # list of (Gtk.CheckButton, addr)
                for addr, source in found:
                    row = Adw.ActionRow(title=addr, subtitle=source)
                    check = Gtk.CheckButton()
                    if not scan_entries:
                        check.set_active(True)
                    else:
                        check.set_group(scan_entries[0][0])
                    row.add_prefix(check)
                    row.set_activatable_widget(check)
                    group.add(row)
                    scan_entries.append((check, addr))
                dialog.set_extra_child(group)
                dialog.add_response("cancel", "Cancelar")
                dialog.add_response("select", "Usar seleccionado")
                dialog.set_response_appearance("select", Adw.ResponseAppearance.SUGGESTED)
                dialog.connect("response", lambda d, resp: self._on_scan_selected(resp, scan_entries))
                dialog.present(self)
                return
        self.show_toast("No se encontraron dispositivos")

    def _on_scan_selected(self, response, scan_entries):
        if response != "select":
            return
        for check, addr in scan_entries:
            if check.get_active():
                self.entry_row.set_text(addr)
                self.refresh_devices()
                break

    # --- Desconectar ---
    def on_disconnect_selected(self):
        addrs = [dev["addr"] for dev in self.devices
                 if dev["check"] and dev["check"].get_active() and dev["is_connected"]]
        if not addrs:
            return
        self.set_busy(True)
        self._run_in_thread(lambda: [run_adb("disconnect", a) for a in addrs],
                            on_done=self.refresh_devices)

    def on_disconnect_all(self):
        self.set_busy(True)
        def do_disconnect():
            run_adb("disconnect")
            run_adb("notify", "Desconectado", "Todos los dispositivos desconectados", "phone")
        self._run_in_thread(do_disconnect, on_done=self.refresh_devices)

    def on_delete_selected(self):
        names = [dev["name"] for dev in self.devices
                 if dev["check"] and dev["check"].get_active() and not dev["is_connected"]]
        if not names:
            return
        self.set_busy(True)
        self._run_in_thread(lambda: [run_adb("delete-device", n) for n in names],
                            on_done=self.refresh_devices)

    # --- Utilidades UI ---
    def set_busy(self, busy):
        self.spinner.set_visible(busy)
        if busy:
            self.spinner.start()
        else:
            self.spinner.stop()

    def show_toast(self, message):
        toast = Adw.Toast(title=message, timeout=3)
        self.toast_overlay.add_toast(toast)

    def ask_save_device(self, ip, port, model):
        dialog = Adw.AlertDialog(
            heading="Guardar dispositivo",
            body=f"¿Guardar {ip}:{port} ({model}) para acceso rápido?"
        )
        name_entry = Adw.EntryRow(title="Nombre")
        name_entry.set_text(model)
        group = Adw.PreferencesGroup()
        group.add(name_entry)
        dialog.set_extra_child(group)
        dialog.add_response("no", "No guardar")
        dialog.add_response("save", "Guardar")
        dialog.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED)
        dialog.connect("response", lambda d, resp: self._on_save_response(resp, name_entry.get_text(), ip, port))
        dialog.present(self)

    def _on_save_response(self, response, name, ip, port):
        if response == "save" and name:
            self._run_in_thread(lambda: (
                run_adb("save-device", name, ip, port),
                run_adb("notify", "Guardado", f"Dispositivo '{name}' guardado", "document-save"),
            ))

    def ask_pair_after_fail(self, ip, port):
        dialog = Adw.AlertDialog(
            heading="Error de conexión",
            body=f"No se pudo conectar a {ip}:{port}\n\n¿El dispositivo está emparejado?"
        )
        dialog.add_response("cancel", "Cancelar")
        dialog.add_response("pair", "Emparejar ahora")
        dialog.set_response_appearance("pair", Adw.ResponseAppearance.SUGGESTED)
        dialog.connect("response", lambda d, resp: self.on_pair_code() if resp == "pair" else None)
        dialog.present(self)


if __name__ == "__main__":
    app = ConnectAndroidApp()
    app.run(None)
