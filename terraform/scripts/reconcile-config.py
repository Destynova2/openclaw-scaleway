#!/usr/bin/env python3
"""Reconcile on-disk config files with cloud-init metadata on every boot."""
import hashlib, json, os, subprocess, sys, urllib.request

import yaml

METADATA_URL = "http://169.254.42.42/user_data/cloud-init"
MANAGED_PREFIXES = (
    "/home/openclaw/config/openclaw.json",
    "/home/openclaw/kube.yml",
    "/home/openclaw/caddy/Caddyfile",
    "/home/openclaw/.config/containers/systemd/openclaw.kube",
    "/home/openclaw/.config/containers/auth.json",
    "/home/openclaw/config/workspace/SOUL.md",
)

def sha256(content):
    if isinstance(content, str):
        content = content.encode()
    return hashlib.sha256(content).hexdigest()

def fetch_metadata():
    try:
        req = urllib.request.Request(METADATA_URL)
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.read().decode()
    except Exception as e:
        print(f"reconcile: cannot fetch metadata: {e}", file=sys.stderr)
        return None

def main():
    raw = fetch_metadata()
    if not raw:
        return

    try:
        cloud_config = yaml.safe_load(raw)
    except yaml.YAMLError as e:
        print(f"reconcile: invalid YAML: {e}", file=sys.stderr)
        return

    write_files = cloud_config.get("write_files", [])
    if not write_files:
        print("reconcile: no write_files in metadata")
        return

    changed = False
    for entry in write_files:
        path = entry.get("path", "")
        if path not in MANAGED_PREFIXES:
            continue

        content = entry.get("content", "")
        perms = entry.get("permissions", "0644")

        # Compare with on-disk file
        if os.path.exists(path):
            try:
                with open(path) as f:
                    disk_content = f.read()
                if sha256(disk_content) == sha256(content):
                    continue
            except OSError:
                pass

        # Write updated file
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        os.chmod(path, int(perms, 8))
        print(f"reconcile: updated {path}")
        changed = True

    # Fix ownership for all openclaw files
    if changed:
        subprocess.run(
            ["chown", "-R", "openclaw:openclaw", "/home/openclaw"],
            capture_output=True
        )
        # Restart pod to pick up changes
        print("reconcile: restarting openclaw service...")
        subprocess.run(
            ["sudo", "-u", "openclaw",
             "XDG_RUNTIME_DIR=/run/user/1000",
             "systemctl", "--user", "restart", "openclaw.service"],
            capture_output=True
        )
    if changed:
        print("reconcile: done (files updated + pod restarted)")
    else:
        print("reconcile: all files up to date")

if __name__ == "__main__":
    main()
