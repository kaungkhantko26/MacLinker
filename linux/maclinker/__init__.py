"""MacLinker for Linux: share keyboard, mouse, clipboard and files with MacLinker on macOS."""

__version__ = "0.1.0"
# Reported to peers in the hello message. Deliberately below the macOS app's 1.2.0, the first
# version that sends brightness/volume messages, so a Mac never sends this program ones it can't handle.
APP_VERSION = "0.1.0"
DEFAULT_PORT = 52845
SERVICE_TYPE = "_maclinker._tcp.local."
