#!/usr/bin/env python3
"""Exercise production playback methods using a deterministic player and page bridge."""
from pathlib import Path
import subprocess, tempfile, shutil

root = Path(__file__).resolve().parent.parent
source = (root / 'YouTubePoC/AppDelegate.swift').read_text()

def method(name):
    start = source.index('    private func ' + name + '(')
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func ', 'func ', 1)

helpers = source[source.index('enum NativePlaybackRate {'):source.index('/// WebKit is paused before the handoff')]
harness = '''
enum World { case page }
final class WebView {
    var rates: [Double] = []
    func callAsyncJavaScript(_ body: String, arguments: [String: Any], in frame: String?, in world: World) {
        rates.append(arguments["rate"] as! Double)
    }
}
final class Item { var isPlaybackBufferEmpty = false }
final class AVPlayer {
    var defaultRate: Float = 1
    var rate: Float = 0
    var currentItem: Item? = Item()
    var starts = 0
    func playImmediately(atRate rate: Float) { self.rate = rate; starts += 1 }
    func play() { rate = defaultRate; starts += 1 }
}
final class Harness {
    var preferredPlaybackRate: Float = 1
    var ownsPlayback = true
    var wantsPlaying = false
    var player: AVPlayer? = AVPlayer()
    var webView: WebView? = WebView()
    var videoID = "TESTVIDEO01"
    func log(_ value: String) {}
    func updateSettingsMenu() {}
'''
checks = '''
let h = Harness()
for rate: Float in [0.25, 0.5, 0.75, 1.25, 1.5, 2] {
    h.wantsPlaying = false
    let starts = h.player!.starts
    h.setPlaybackRate(rate)
    assert(h.player!.starts == starts, "Paused speed change must not play")
    assert(h.player!.defaultRate == rate)
    h.wantsPlaying = true
    h.player!.currentItem!.isPlaybackBufferEmpty = false
    h.startRequestedPlayback(h.player!)
    assert(h.player!.rate == rate, "Buffered start/resume must keep speed")
    h.player!.currentItem!.isPlaybackBufferEmpty = true
    h.startRequestedPlayback(h.player!)
    assert(h.player!.rate == rate, "Empty-buffer play must use defaultRate")
}
assert(NativePlaybackRate.validated(.nan) == 1)
assert(NativePlaybackRate.validated(.infinity) == 1)
assert(NativePlaybackRate.validated(0) == 1)
assert(NativePlaybackRate.validated(5) == 1)
assert(NativePlaybackRate.validated(3) == 3)
let cues = NativeCaptionCue.parse([
    ["start": 3.0, "end": 5.0, "text": "second"],
    ["start": 1.0, "end": 4.0, "text": "first"],
    ["start": 8.0, "end": 7.0, "text": "invalid"],
    ["start": Double.nan, "end": 9.0, "text": "invalid"]])
assert(cues.count == 2)
assert(NativeCaptionCue.text(at: 0, cues: cues).isEmpty)
assert(NativeCaptionCue.text(at: 2, cues: cues) == "first")
assert(NativeCaptionCue.text(at: 3.5, cues: cues) == "first\\nsecond")
assert(NativeCaptionCue.text(at: 5, cues: cues).isEmpty)
assert(NativeCaptionCue.text(at: 2, cues: cues) == "first", "Backward seek reselects cue")
print("PASS: production Swift rate start/resume and paused settings, caption timing/filtering")
'''
with tempfile.TemporaryDirectory(prefix='youtube-settings-tests-') as tmp:
    swift = Path(tmp) / 'contracts.swift'
    swift.write_text('import Foundation\n' + helpers + harness + method('startRequestedPlayback') + '\n' + method('setPlaybackRate') + '\n}\n' + checks)
    subprocess.run(['xcrun', 'swift', '-module-cache-path', str(Path(tmp)/'cache'), str(swift)], check=True)
subprocess.run([shutil.which('node') or '/usr/local/bin/node', str(root/'Tests/playback-settings-contracts.js')], check=True)
