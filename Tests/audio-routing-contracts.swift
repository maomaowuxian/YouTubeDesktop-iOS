func check(_ value: Bool, _ message: String) {
    precondition(value, message)
}
let base = URL(string: "https://r1.googlevideo.com/api/manifest/hls_playlist/id/video/expire/123")!
func stream(_ audioID: String?, _ height: Int, _ bandwidth: Int, _ name: String, _ xtags: String? = nil) -> String {
    var line = "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),CODECS=\"mp4a.40.2,avc1.640028\",RESOLUTION=1920x\(height)"
    if let audioID { line += ",YT-EXT-AUDIO-CONTENT-ID=\"\(audioID)\"" }
    if let xtags { line += ",YT-EXT-XTAGS=\"\(xtags)\"" }
    return line + "\nhttps://r1.googlevideo.com/api/manifest/hls_variant/id/video/track/\(name)?signature=unchanged%2Fvalue\n"
}
let manifest = "#EXTM3U\n" +
    stream("en-US.10",1080,2111757,"english","english-tags") +
    stream(nil,1080,2111577,"original") +
    stream("zh-Hant.4",1080,2111577,"chinese","original-tags") +
    stream("en-US.10",720,988345,"english720","english-tags") +
    stream(nil,720,988164,"original720") +
    stream("zh-Hant.4",720,988164,"chinese720","original-tags")
let variants = NativeHLSAudioRouting.variants(manifest, baseURL: base)
check(variants.count == 6, "All muxed variants, including quoted CODECS comma")
func choose(_ id: String, _ height: Int = 1080, _ xtags: String = "") -> NativeHLSAudioRouting.Variant? {
    NativeHLSAudioRouting.choose(variants, audioID: id, xtags: xtags, preferredHeight: height)
}
check(choose("und")?.url.path.hasSuffix("/original") == true, "Default webpage stream must not choose higher-bandwidth English")
check(choose("und")?.url.absoluteString.hasSuffix("signature=unchanged%2Fvalue") == true, "Preserve the server-returned URL and signature")
check(choose("zh-Hant.4")?.url.path.hasSuffix("/chinese") == true, "Explicit Chinese identity")
check(choose("en-US.10")?.url.path.hasSuffix("/english") == true, "Explicit English identity")
check(choose("und",720)?.url.path.hasSuffix("/original720") == true, "Keep current webpage quality")
check(choose("zh-Hant.4",144)?.url.path.hasSuffix("/chinese720") == true, "Lowest available matching quality")
check(choose("fr.4") == nil, "Missing language must not fall back to a different audio")
check(choose("und",1080,"english-tags")?.audioID == "en-US.10", "A selected xtags identity takes precedence over und")
check(choose("zh-Hant.4",1080,"english-tags") == nil, "Reject contradictory explicit identity and xtags")
check(NativeHLSAudioRouting.choose(variants.filter { $0.audioID != "und" },audioID:"und",xtags:"",preferredHeight:1080) == nil, "No untagged match means no takeover")
let unsafe = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=10x10\nhttp://r1.googlevideo.com/api/manifest/hls_variant/a\n#EXT-X-STREAM-INF:BANDWIDTH=3\nhttps://evil.example/api/manifest/hls_variant/a\n#EXT-X-STREAM-INF:AUDIO=\"different-group\"\nhttps://r1.googlevideo.com/api/manifest/hls_variant/a\n"
check(NativeHLSAudioRouting.variants(unsafe,baseURL:base).isEmpty, "Reject unsafe URLs and separate audio groups")
let relative = "#EXTM3U\r\n#EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=10x10\r\n/api/manifest/hls_variant/id/video/relative\r\n"
check(NativeHLSAudioRouting.variants(relative,baseURL:base).first?.url.path.hasSuffix("/relative") == true, "Resolve relative URI and CRLF")
check(NativeHLSAudioRouting.variants("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2",baseURL:base).isEmpty, "Ignore dangling variant")
let playlistChild = relative.replacingOccurrences(of: "hls_variant", with: "hls_playlist")
check(NativeHLSAudioRouting.variants(playlistChild,baseURL:base).count == 1, "YouTube also returns hls_playlist child URLs")
print("PASS: 15 audio routing contracts")
