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
PKG_VERSION = "2.2.0-1"
OUT_IPK = f"{PKG_NAME}_{PKG_VERSION}_all.ipk"

import hashlib
import shutil

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONTROL_DIR = os.path.join(BASE_DIR, "src", "CONTROL")
DATA_DIR = os.path.join(BASE_DIR, "src", "data")
RELEASE_DIR = os.path.join(BASE_DIR, "release")

def read_file_content(path):
    with open(path, "rb") as f:
        data = f.read()
    # Конвертируем CRLF -> LF только для текстовых файлов и скриптов (не трогаем бинарные ELF и .ko)
    ext = os.path.splitext(path)[1].lower()
    fname = os.path.basename(path)
    text_exts = ('.sh', '.js', '.json', '.txt', '.md', '.conf', '.orig')
    text_names = ('postinst', 'prerm', 'control', 'timestamp')
    if ext in text_exts or fname in text_names:
        return data.replace(b"\r\n", b"\n")
    return data

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

def pack_directory(source_dir, executable_exts=(".sh", "postinst", "prerm", "amneziawg", "amneziawg_watchdog", "awg", "95-awgswitch")):
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
                add_bytes_to_tar(tar, arcname, read_file_content(full_path), mode=mode)
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

    os.makedirs(RELEASE_DIR, exist_ok=True)
    rel_path = os.path.join(RELEASE_DIR, OUT_IPK)
    shutil.copy2(out_path, rel_path)

    # Вычисляем SHA256
    with open(out_path, "rb") as f:
        sha256 = hashlib.sha256(f.read()).hexdigest()

    checksum_file = os.path.join(RELEASE_DIR, "sha256sums.txt")
    with open(checksum_file, "w", encoding="utf-8") as f:
        f.write(f"{sha256}  {OUT_IPK}\n")

    print(f"[+] Готово! Файл создан: {out_path} ({os.path.getsize(out_path)} байт)")
    print(f"[+] Релизная копия: {rel_path}")
    print(f"[+] Контрольная сумма SHA256: {sha256}")

if __name__ == "__main__":
    main()
