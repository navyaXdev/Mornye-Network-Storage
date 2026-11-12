#!/usr/bin/env python3
"""
cli/system_ops.py
Real Linux system monitoring operations for Mornye Bash CLI.
Uses actual host / container telemetry via psutil.
"""

import sys
import time
from pathlib import Path
import psutil

def format_bytes(b: int) -> str:
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if b < 1024.0:
            return f"{b:.2f} {unit}"
        b /= 1024.0
    return f"{b:.2f} PB"

def show_cpu():
    load = psutil.getloadavg()
    pct = psutil.cpu_percent(interval=0.5)
    per_core = psutil.cpu_percent(interval=0.2, percpu=True)
    cores_phys = psutil.cpu_count(logical=False) or 1
    cores_log = psutil.cpu_count(logical=True) or 1

    print("=" * 60)
    print("                     CPU TELEMETRY")
    print("=" * 60)
    print(f"Overall Usage       : {pct:.1f}%")
    print(f"Cores (Phys/Logical): {cores_phys} physical / {cores_log} logical")
    print(f"Load Averages (1/5/15m): {load[0]:.2f}, {load[1]:.2f}, {load[2]:.2f}")
    core_str = ", ".join([f"Core {i}: {c}%" for i, c in enumerate(per_core)])
    print(f"Per-Core Utilization: {core_str}")
    print("=" * 60)

def show_memory():
    vm = psutil.virtual_memory()
    swap = psutil.swap_memory()

    print("=" * 60)
    print("                    MEMORY TELEMETRY")
    print("=" * 60)
    print(f"Total Physical RAM  : {format_bytes(vm.total)}")
    print(f"Used Memory         : {format_bytes(vm.used)} ({vm.percent}%)")
    print(f"Available Memory    : {format_bytes(vm.available)}")
    print(f"Cached / Buffers    : {format_bytes(getattr(vm, 'cached', 0))}")
    print(f"Swap Total / Used   : {format_bytes(swap.total)} / {format_bytes(swap.used)} ({swap.percent}%)")
    print("=" * 60)

def show_disk():
    storage_path = Path("/home/spidyno/.song/storage")
    target_path = storage_path if storage_path.exists() else Path("/")
    usage = psutil.disk_usage(str(target_path))

    print("=" * 60)
    print("                     DISK TELEMETRY")
    print("=" * 60)
    print(f"Mount Inspection    : {target_path}")
    print(f"Total Disk Capacity : {format_bytes(usage.total)}")
    print(f"Used Space          : {format_bytes(usage.used)} ({usage.percent}%)")
    print(f"Free Disk Space     : {format_bytes(usage.free)}")
    print("=" * 60)

def show_network():
    net0 = psutil.net_io_counters()
    time.sleep(0.5)
    net1 = psutil.net_io_counters()

    rx_rate = (net1.bytes_recv - net0.bytes_recv) * 2
    tx_rate = (net1.bytes_sent - net0.bytes_sent) * 2

    print("=" * 60)
    print("                   NETWORK TELEMETRY")
    print("=" * 60)
    print(f"Cumulative Sent     : {format_bytes(net1.bytes_sent)}")
    print(f"Cumulative Received : {format_bytes(net1.bytes_recv)}")
    print(f"Live Ingress Rate   : {format_bytes(rx_rate)}/s")
    print(f"Live Egress Rate    : {format_bytes(tx_rate)}/s")
    print("=" * 60)

def show_all():
    show_cpu()
    print()
    show_memory()
    print()
    show_disk()
    print()
    show_network()

def main():
    if len(sys.argv) < 2:
        show_all()
        return

    cmd = sys.argv[1].lower()
    if cmd in ["all", "monitor"]:
        show_all()
    elif cmd == "cpu":
        show_cpu()
    elif cmd == "memory":
        show_memory()
    elif cmd == "disk":
        show_disk()
    elif cmd == "network":
        show_network()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()

