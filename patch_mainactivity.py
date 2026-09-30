#!/usr/bin/env python3
"""Escreve o MethodChannel do MulticastLock no MainActivity.kt gerado pelo
flutter create, preservando a linha `package`.

Uso:
    python3 patch_mainactivity.py ~/remote_control_app
"""
import re
import sys
from pathlib import Path

BODY = '''
import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tv/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        if (multicastLock == null) {
                            val wifi = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifi.createMulticastLock("tv-discovery").apply {
                                setReferenceCounted(true)
                                acquire()
                            }
                        }
                        result.success(null)
                    }
                    "release" -> {
                        multicastLock?.let { if (it.isHeld) it.release() }
                        multicastLock = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }
}
'''


def main(project: Path) -> int:
    roots = list((project / 'android/app/src/main').glob('kotlin/**/MainActivity.kt'))
    roots += list((project / 'android/app/src/main').glob('java/**/MainActivity.kt'))
    if not roots:
        print('MainActivity.kt nao encontrado', file=sys.stderr)
        return 1

    path = roots[0]
    original = path.read_text()

    match = re.search(r'^package\s+[\w.]+', original, re.MULTILINE)
    if not match:
        print('linha package nao encontrada em', path, file=sys.stderr)
        return 1

    if 'tv/multicast' in original:
        print('ja aplicado:', path)
        return 0

    path.write_text(match.group(0) + '\n' + BODY)
    print('MainActivity atualizado:', path)
    return 0


if __name__ == '__main__':
    target = Path(sys.argv[1] if len(sys.argv) > 1 else '.').expanduser()
    raise SystemExit(main(target))
