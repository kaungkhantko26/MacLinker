"""Bonjour/mDNS discovery (python-zeroconf), compatible with the Mac app's `_maclinker._tcp` service."""
from __future__ import annotations

import asyncio
import logging
import socket
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

from . import SERVICE_TYPE

log = logging.getLogger("maclinker.discovery")


@dataclass
class Found:
    id: str
    name: str
    host: str
    port: int


def local_ipv4() -> List[str]:
    """Non-loopback IPv4 addresses, including link-local ones (a USB-C/Thunderbolt cable gets 169.254.x.x)."""
    try:
        import ifaddr
    except ImportError:
        return []
    out = []
    for adapter in ifaddr.get_adapters():
        for ip in adapter.ips:
            if ip.is_IPv4 and not str(ip.ip).startswith("127."):
                out.append(str(ip.ip))
    return out


def pick_address(addresses: List[str], local: List[str]) -> Optional[str]:
    """Prefer an address on the same /16 as one of ours (so a cable link beats routing out and back)."""
    if not addresses:
        return None
    for a in addresses:
        for l in local:
            if a.split(".")[:2] == l.split(".")[:2]:
                return a
    return addresses[0]


class Discovery:
    def __init__(self, name: str, device_id: str, port: int, on_found: Callable[[Found], None],
                 on_lost: Callable[[str], None]) -> None:
        self.name, self.device_id, self.port = name, device_id, port
        self.on_found, self.on_lost = on_found, on_lost
        self._azc = None
        self._browser = None
        self._by_service: Dict[str, str] = {}   # service name -> device id

    async def start(self) -> None:
        try:
            from zeroconf import ServiceInfo
            from zeroconf.asyncio import AsyncServiceBrowser, AsyncZeroconf
        except ImportError:
            log.warning("python-zeroconf not installed: discovery off (use `maclinker connect HOST`)")
            return
        self._azc = AsyncZeroconf()
        addrs = [socket.inet_aton(a) for a in local_ipv4()]
        info = ServiceInfo(SERVICE_TYPE, f"{self.name}.{SERVICE_TYPE}", port=self.port,
                           properties={"id": self.device_id, "v": "1"}, addresses=addrs,
                           server=f"{socket.gethostname().split('.')[0]}.local.")
        await self._azc.async_register_service(info, allow_name_change=True)
        self._browser = AsyncServiceBrowser(self._azc.zeroconf, SERVICE_TYPE, handlers=[self._handler])
        log.info("advertising and browsing %s", SERVICE_TYPE)

    def _handler(self, zeroconf, service_type, name, state_change) -> None:
        from zeroconf import ServiceStateChange
        if state_change == ServiceStateChange.Removed:
            dev = self._by_service.pop(name, None)
            if dev:
                self.on_lost(dev)
            return
        asyncio.ensure_future(self._resolve(zeroconf, service_type, name))

    async def _resolve(self, zeroconf, service_type: str, name: str) -> None:
        from zeroconf.asyncio import AsyncServiceInfo
        info = AsyncServiceInfo(service_type, name)
        if not await info.async_request(zeroconf, 3000):
            return
        props = {(k.decode() if isinstance(k, bytes) else k): (v.decode() if isinstance(v, bytes) else v)
                 for k, v in (info.properties or {}).items()}
        dev_id = props.get("id")
        host = pick_address(info.parsed_addresses(), local_ipv4())
        if not dev_id or dev_id == self.device_id or not host or not info.port:
            return
        self._by_service[name] = dev_id
        self.on_found(Found(dev_id, name.split(".")[0], host, info.port))

    async def stop(self) -> None:
        if self._browser:
            await self._browser.async_cancel()
        if self._azc:
            await self._azc.async_unregister_all_services()
            await self._azc.async_close()
