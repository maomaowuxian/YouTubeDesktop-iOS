#!/usr/bin/env python3
"""Run contracts against the actual Swift routing helper and injected page bridge."""
from pathlib import Path
import subprocess, tempfile, shutil
root = Path(__file__).resolve().parent.parent
source = (root / 'YouTubePoC/AppDelegate.swift').read_text()
helper = source[source.index('enum NativeHLSAudioRouting {'):source.index('/// Verifies the actual webpage media URL')]
with tempfile.TemporaryDirectory(prefix='youtube-audio-tests-') as tmp:
    swift = Path(tmp) / 'contracts.swift'
    swift.write_text('import Foundation\n' + helper + (root / 'Tests/audio-routing-contracts.swift').read_text())
    subprocess.run(['xcrun','swift','-module-cache-path',str(Path(tmp)/'cache'),str(swift)],check=True)
subprocess.run([shutil.which('node') or '/usr/local/bin/node',str(root/'Tests/audio-bridge-contracts.js')],check=True)
