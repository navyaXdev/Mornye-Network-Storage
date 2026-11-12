import email.utils
import urllib.parse
from typing import List, Dict, Any, Optional

def format_rfc1123(timestamp: float) -> str:
    """Format Unix timestamp as RFC 1123 date string for WebDAV HTTP headers/XML."""
    try:
        return email.utils.formatdate(timestamp, usegmt=True)
    except Exception:
        import time
        return email.utils.formatdate(time.time(), usegmt=True)

def build_multistatus_response(
    items: List[Dict[str, Any]],
    base_prefix: str = "/dav/",
    is_collection_root: bool = True
) -> str:
    """
    Build RFC 4918 compliant WebDAV XML <D:multistatus> response for flat files.
    """
    prefix = base_prefix if base_prefix.endswith("/") else f"{base_prefix}/"

    xml_lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<D:multistatus xmlns:D="DAV:">'
    ]

    if is_collection_root:
        xml_lines.extend([
            '  <D:response>',
            f'    <D:href>{prefix}</D:href>',
            '    <D:propstat>',
            '      <D:prop>',
            '        <D:displayname>Mornye Storage Root</D:displayname>',
            '        <D:resourcetype><D:collection/></D:resourcetype>',
            '      </D:prop>',
            '      <D:status>HTTP/1.1 200 OK</D:status>',
            '    </D:propstat>',
            '  </D:response>'
        ])

    for file_info in items:
        encoded_name = urllib.parse.quote(file_info["filename"])
        file_href = f"{prefix}{encoded_name}"
        rfc_date = format_rfc1123(file_info.get("last_modified", 0))
        mime_type = file_info.get("mime_type", "audio/mpeg")
        size = file_info.get("file_size_bytes", 0)

        xml_lines.extend([
            '  <D:response>',
            f'    <D:href>{file_href}</D:href>',
            '    <D:propstat>',
            '      <D:prop>',
            f'        <D:displayname>{file_info["filename"]}</D:displayname>',
            f'        <D:getcontentlength>{size}</D:getcontentlength>',
            f'        <D:getlastmodified>{rfc_date}</D:getlastmodified>',
            f'        <D:getcontenttype>{mime_type}</D:getcontenttype>',
            '        <D:resourcetype/>',
            '      </D:prop>',
            '      <D:status>HTTP/1.1 200 OK</D:status>',
            '    </D:propstat>',
            '  </D:response>'
        ])

    xml_lines.append('</D:multistatus>')
    return "\n".join(xml_lines)

def build_virtual_multistatus_response(
    self_href: str,
    self_displayname: str,
    is_collection: bool = True,
    child_collections: Optional[List[Dict[str, Any]]] = None,
    child_files: Optional[List[Dict[str, Any]]] = None,
    self_file_info: Optional[Dict[str, Any]] = None
) -> str:
    """
    Build RFC 4918 compliant WebDAV XML <D:multistatus> response supporting:
    - Root collection
    - Virtual directories (collections)
    - Virtual child files
    - Single file PROPFIND queries
    """
    child_collections = child_collections or []
    child_files = child_files or []

    # Ensure self_href has appropriate trailing slash if collection
    clean_self_href = self_href
    if is_collection and not clean_self_href.endswith("/"):
        clean_self_href += "/"

    xml_lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<D:multistatus xmlns:D="DAV:">'
    ]

    # 1. Emit self entry
    if is_collection:
        xml_lines.extend([
            '  <D:response>',
            f'    <D:href>{clean_self_href}</D:href>',
            '    <D:propstat>',
            '      <D:prop>',
            f'        <D:displayname>{self_displayname}</D:displayname>',
            '        <D:resourcetype><D:collection/></D:resourcetype>',
            '      </D:prop>',
            '      <D:status>HTTP/1.1 200 OK</D:status>',
            '    </D:propstat>',
            '  </D:response>'
        ])
    else:
        info = self_file_info or {}
        rfc_date = format_rfc1123(info.get("last_modified", 0))
        mime = info.get("mime_type", "audio/mpeg")
        size = info.get("file_size_bytes", 0)
        xml_lines.extend([
            '  <D:response>',
            f'    <D:href>{clean_self_href}</D:href>',
            '    <D:propstat>',
            '      <D:prop>',
            f'        <D:displayname>{self_displayname}</D:displayname>',
            f'        <D:getcontentlength>{size}</D:getcontentlength>',
            f'        <D:getlastmodified>{rfc_date}</D:getlastmodified>',
            f'        <D:getcontenttype>{mime}</D:getcontenttype>',
            '        <D:resourcetype/>',
            '      </D:prop>',
            '      <D:status>HTTP/1.1 200 OK</D:status>',
            '    </D:propstat>',
            '  </D:response>'
        ])

    # 2. Emit child collections
    for col in child_collections:
        col_href = col["href"]
        if not col_href.endswith("/"):
            col_href += "/"
        xml_lines.extend([
            '  <D:response>',
            f'    <D:href>{col_href}</D:href>',
            '    <D:propstat>',
            '      <D:prop>',
            f'        <D:displayname>{col["name"]}</D:displayname>',
            '        <D:resourcetype><D:collection/></D:resourcetype>',
            '      </D:prop>',
            '      <D:status>HTTP/1.1 200 OK</D:status>',
            '    </D:propstat>',
            '  </D:response>'
        ])

    # 3. Emit child files
    for file_info in child_files:
        file_href = file_info["href"]
        rfc_date = format_rfc1123(file_info.get("last_modified", 0))
        mime = file_info.get("mime_type", "audio/mpeg")
        size = file_info.get("file_size_bytes", 0)
        disp_name = file_info.get("displayname", file_info.get("filename", "audio"))

        xml_lines.extend([
            '  <D:response>',
            f'    <D:href>{file_href}</D:href>',
            '    <D:propstat>',
            '      <D:prop>',
            f'        <D:displayname>{disp_name}</D:displayname>',
            f'        <D:getcontentlength>{size}</D:getcontentlength>',
            f'        <D:getlastmodified>{rfc_date}</D:getlastmodified>',
            f'        <D:getcontenttype>{mime}</D:getcontenttype>',
            '        <D:resourcetype/>',
            '      </D:prop>',
            '      <D:status>HTTP/1.1 200 OK</D:status>',
            '    </D:propstat>',
            '  </D:response>'
        ])

    xml_lines.append('</D:multistatus>')
    return "\n".join(xml_lines)
