#!/usr/bin/env python3
"""
Сборщик пакета .ipk для OpenWrt (работает на Windows / Linux / macOS без SDK).
Просто отредактируйте любые файлы в папке src/ в VS Code и запустите:
    python build_ipk.py
На выходе появится готовый файл luci-app-awg-switch_2.0.0-1_all.ipk
"""
import os
import io
import time
import tarfile

PKG_NAME = "luci-app-awg-switch"
PKG_VERSION = "2.0.0-1"
OUT_IPK = f"{PKG_NAME}_{PKG_VERSION}_all.ipk"

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONTROL_DIR = os.path.join(BASE_DIR, "src", "CONTROL")
DATA_DIR = os.path.join(BASE_DIR, "src", "data")

def read_file_unix(path):
    with open(path, "rb") as f:
        data = f.read()
    # Конвертируем CRLF -> LF, чтобы при редактировании в Windows не ломались shell-скрипты на роутере
    return data.replace(b"\r\n", b"\n")

def add_bytes_to_tar(tar, arcname, content_bytes, mode=0o644, is_dir=False):
    ti = tarfile.TarInfo(name=arcname)
    ti.mtime = int(time.time())
    ti.uid = 0
    ti.gid = 0
    ti.uname = "root"
    ti.gname = "root"
    if is_dir:
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        tar.addfile(ti)
    else:
        ti.type = tarfile.REGTYPE
        ti.mode = mode
        ti.size = len(content_bytes)
        tar.addfile(ti, io.BytesIO(content_bytes))

def pack_directory(source_dir, executable_exts=(".sh", "postinst", "prerm")):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.USTAR_FORMAT) as tar:
        for root, dirs, files in os.walk(source_dir):
            dirs.sort()
            files.sort()
            rel_root = os.path.relpath(root, source_dir).replace("\\", "/")
            if rel_root != ".":
                add_bytes_to_tar(tar, f"./{rel_root}", b"", is_dir=True)
            for fname in files:
                full_path = os.path.join(root, fname)
                rel_path = os.path.relpath(full_path, source_dir).replace("\\", "/")
                arcname = f"./{rel_path}"
                is_exec = fname.endswith(executable_exts) or fname in executable_exts
                mode = 0o755 if is_exec else 0o644
                add_bytes_to_tar(tar, arcname, read_file_unix(full_path), mode=mode)
    return buf.getvalue()

def main():
    print(f"[*] Сборка control.tar.gz из {CONTROL_DIR}...")
    ctrl_bytes = pack_directory(CONTROL_DIR)

    print(f"[*] Сборка data.tar.gz из {DATA_DIR}...")
    data_bytes = pack_directory(DATA_DIR)

    print(f"[*] Упаковка итогового пакета {OUT_IPK}...")
    out_path = os.path.join(BASE_DIR, OUT_IPK)
    with tarfile.open(out_path, mode="w:gz", format=tarfile.USTAR_FORMAT) as ipk:
        add_bytes_to_tar(ipk, "./debian-binary", b"2.0\n", mode=0o644)
        add_bytes_to_tar(ipk, "./control.tar.gz", ctrl_bytes, mode=0o644)
        add_bytes_to_tar(ipk, "./data.tar.gz", data_bytes, mode=0o644)

    print(f"[+] Готово! Файл создан: {out_path} ({os.path.getsize(out_path)} байт)")

if __name__ == "__main__":
    main()
