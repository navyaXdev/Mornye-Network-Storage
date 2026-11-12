#!/usr/bin/env python3
"""
cli/tunnel_ops.py
Cloudflare Zero-Trust Tunnel operations for Mornye Bash CLI.
Scrapes real Prometheus metrics from 127.0.0.1:20241 and verifies WAN ingress.
"""

import sys
import asyncio
from pathlib import Path

PROGRAM_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROGRAM_DIR))

from backend.core.config import settings
from backend.services.tunnel_service import get_tunnel_status, execute_wan_health_check

async def show_status():
    status = await get_tunnel_status()
    srv = status.get("service", {})
    net = status.get("network", {})

    print("=" * 60)
    print("             CLOUDFLARE ZERO-TRUST TUNNEL STATUS")
    print("=" * 60)
    print(f"Service Unit / Daemon : {srv.get('unit', 'mornye-tunnel.service')}")
    print(f"Active State          : {srv.get('active_state', 'unknown').upper()} (PID: {srv.get('pid', '—')})")
    print(f"Memory (cgroup)       : {srv.get('memory_mb', 0)} MB ({srv.get('memory_source', 'systemd')})")
    print(f"Service Uptime        : {srv.get('uptime_human', '0s')}")
    print(f"Public Hostname       : {net.get('public_hostname', settings.STORAGE_HOSTNAME)}")
    print(f"Local Ingress Target  : {net.get('local_ingress_target', f'http://127.0.0.1:{settings.WEBDAV_PORT}')}")
    print(f"HA Edge Connections   : {net.get('ha_connections', 0)} active sessions")
    print(f"Edge Router POPs      : {', '.join(net.get('edge_locations', ['Edge POP']))}")
    print(f"Smoothed RTT Latency  : {net.get('rtt_ms', {}).get('smoothed', 0.0)} ms")
    print(f"Cumulative Proxied    : {net.get('total_proxied_requests', 0)} requests")
    print("=" * 60)

async def test_tunnel():
    print("[*] Initiating real-time WAN connectivity handshake probe...")
    res = await execute_wan_health_check()
    default_url = f"https://{settings.STORAGE_HOSTNAME}/dav/"
    print("=" * 60)
    print("             WAN INGRESS HEALTH CHECK RESULTS")
    print("=" * 60)
    print(f"Public Ingress Target : {res.get('target_url') or default_url}")
    print(f"WAN Reachability      : {'HEALTHY & ROUTING' if res.get('healthy') else 'WARNING'}")
    print(f"Handshake RTT Latency : {res.get('latency_ms', 0)} ms")
    print(f"Cloudflare Edge Status: HTTP {res.get('status_code')}")
    print(f"Edge Server Header    : {res.get('edge_server', 'cloudflare')}")
    print(f"Cloudflare Ray ID     : {res.get('edge_ray') or res.get('cf_ray') or 'N/A'}")
    print(f"Local WebDAV Status   : Port {settings.WEBDAV_PORT} -> HTTP {res.get('local_webdav_status')}")
    diag = res.get('error') or "Edge proxying successfully to local WebDAV backend"
    print(f"Diagnostic Summary    : {diag}")
    print("=" * 60)

def main():
    if len(sys.argv) < 2:
        print("Usage: tunnel_ops.py [status|test]")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == "status":
        asyncio.run(show_status())
    elif cmd == "test":
        asyncio.run(test_tunnel())
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()
