#!/usr/bin/env python3
"""Aplica no AndroidManifest.xml gerado pelo flutter create as permissoes e os
atributos de rede que o app precisa.

Idempotente: rodar duas vezes nao duplica nada.

Uso:
    python3 patch_manifest.py ~/remote_control_app
"""
import re
import sys
from pathlib import Path

PERMISSIONS = [
    ('android.permission.INTERNET', {}),
    ('android.permission.ACCESS_NETWORK_STATE', {}),
    ('android.permission.ACCESS_WIFI_STATE', {}),
    ('android.permission.CHANGE_WIFI_MULTICAST_STATE', {}),
    ('android.permission.NEARBY_WIFI_DEVICES', {
        'android:usesPermissionFlags': 'neverForLocation',
        'tools:targetApi': '33',
    }),
]

APP_ATTRS = {
    'android:label': 'Controle Remoto',
    'android:usesCleartextTraffic': 'true',
    'android:networkSecurityConfig': '@xml/network_security_config',
}


def main(project: Path) -> int:
    manifest = project / 'android/app/src/main/AndroidManifest.xml'
    if not manifest.exists():
        print(f'nao encontrei {manifest}', file=sys.stderr)
        return 1

    text = manifest.read_text()
    changed = []

    # 1. namespace tools, exigido pelo tools:targetApi
    if 'xmlns:tools' not in text:
        text = text.replace(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
            '    xmlns:tools="http://schemas.android.com/tools"',
            1,
        )
        changed.append('xmlns:tools')

    # 2. permissoes, inseridas antes de <application
    block = []
    for name, extra in PERMISSIONS:
        if name in text:
            continue
        attrs = ''.join(f'\n        {k}="{v}"' for k, v in extra.items())
        block.append(f'    <uses-permission android:name="{name}"{attrs}/>')
        changed.append(name.split('.')[-1])
    if block:
        text = text.replace('    <application', '\n'.join(block) + '\n\n    <application', 1)

    # 3. atributos dentro da tag <application ...>
    match = re.search(r'<application\b[^>]*>', text)
    if not match:
        print('tag <application> nao encontrada', file=sys.stderr)
        return 1
    tag = match.group(0)
    new_tag = tag
    for key, value in APP_ATTRS.items():
        if f'{key}=' in new_tag:
            new_tag = re.sub(rf'{re.escape(key)}="[^"]*"', f'{key}="{value}"', new_tag)
        else:
            new_tag = new_tag.replace('<application', f'<application\n        {key}="{value}"', 1)
            changed.append(key)
    text = text[:match.start()] + new_tag + text[match.end():]

    manifest.write_text(text)
    print('manifest atualizado:', ', '.join(changed) if changed else 'nada a fazer')

    xml = project / 'android/app/src/main/res/xml/network_security_config.xml'
    print('network_security_config:', 'ok' if xml.exists() else 'FALTANDO')
    return 0


if __name__ == '__main__':
    target = Path(sys.argv[1] if len(sys.argv) > 1 else '.').expanduser()
    raise SystemExit(main(target))
