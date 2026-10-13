import UIKit
import WebKit

final class ScriptBridge: NSObject, WKScriptMessageHandler {
    var onAdSkipRequest: ((String) -> Void)?
    var onDiagnostic: ((Any) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "diag":
            // Media request URLs contain ephemeral signatures. Keep the source
            // message in memory and exclude it from all console/file logging.
            if (message.body as? [String: Any])?["kind"] as? String != "nativeSource" {
                print("[YouTubeDesktop][JS] \(message.body)")
            }
            onDiagnostic?(message.body)
        case "adSkip":
            guard
                let body = message.body as? [String: Any],
                let text = body["text"] as? String,
                !text.isEmpty
            else { return }
            print("[YouTubeDesktop][AdSkip] JS requested native click text=\(text)")
            onAdSkipRequest?(text)
        default:
            break
        }
    }
}

final class ViewController: UIViewController, WKNavigationDelegate {
    private let scriptBridge = ScriptBridge()
    private let webView: WKWebView
    private let nativeAudioProbe = NativeAudioSourceProbe()
    private let nativePlayback = NativePiPPlayback()
    private var lastMediaState: [String: Any] = [:]
    private var didRunNativeSmokeTest = false
    private var adSkipClickInFlight = false
    private var lastAdSkipClickAt = Date.distantPast
    #if DEBUG
    private var lastCaptionProbeAt = Date.distantPast
    #endif

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        // PiP uses the app-owned AVPlayer; prevent the WebKit fullscreen
        // controls from starting a second PiP session through the old path.
        config.allowsPictureInPictureMediaPlayback = false
        do {
            // The page selects HLS and transforms its media URL before handoff.
            for name in ["_setMediaSourceEnabled:", "_setManagedMediaSourceEnabled:"] {
                let selector = NSSelectorFromString(name)
                let preferences = config.preferences
                if preferences.responds(to: selector), let implementation = preferences.method(for: selector) {
                    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                    unsafeBitCast(implementation, to: Setter.self)(preferences, selector, false)
                    PlaybackAudioSession.shared.log("NATIVE_SOURCE HLS preference disabled \(name)")
                }
            }
        }
        config.userContentController.add(scriptBridge, name: "diag")
        config.userContentController.add(scriptBridge, name: "adSkip")

        let pageTweaks = #"""
        (() => {
          if (window.__rayYouTubeDesktopInstalled) return;
          window.__rayYouTubeDesktopInstalled = true;

          const post = (body) => {
            try { window.webkit?.messageHandlers?.diag?.postMessage(body); } catch (_) {}
          };


          // Observe completed media requests without consuming response bodies.
          // Signed URLs stay in memory and are never printed in diagnostics.
          let sourceVideoID = '';
          const seenSources = new Set();
          const sourceOwners = new Map();
          const observeMediaURL = (rawURL, declaredMime = '') => {
            try {
              const videoID = new URL(location.href).searchParams.get('v') || '';
              if (!videoID || document.querySelector('.html5-video-player')?.classList.contains('ad-showing')) return;
              const audioTrack = readAudioTrack();
              const sourceIdentity = videoID + ':' + audioTrack.key;
              if (sourceVideoID !== sourceIdentity) { sourceVideoID = sourceIdentity; seenSources.clear(); }
              if (!audioTrack.known) return;
              const videoHeight = document.querySelector('.html5-video-player video')?.videoHeight || 1080;
              const url = new URL(rawURL, location.href);
              if (url.protocol !== 'https:' ||
                  !(url.hostname === 'googlevideo.com' || url.hostname.endsWith('.googlevideo.com'))) return;
              const hls = /^\/api\/manifest\/hls_(playlist|variant)(\/|$)/.test(url.pathname);
              if (hls) {
                // Only a current player response may introduce a manifest.
                // Buffered resource entries may still belong to the previous video.
                if (declaredMime !== 'application/vnd.apple.mpegurl') return;
                const key = 'hls:' + videoID + ':' + url.toString();
                if (seenSources.has(key) || seenSources.size >= 4) return;
                seenSources.add(key);
                post({kind:'nativeSource', videoID, audioTrack, videoHeight, url:url.toString(), mime:'application/vnd.apple.mpegurl'});
                return;
              }
              if (url.pathname !== '/videoplayback') return;
              const mime = url.searchParams.get('mime') || declaredMime.split(';')[0].trim();
              if (!mime.startsWith('audio/') && mime !== 'video/mp4') return;
              const signed = new Set((url.searchParams.get('sparams') || '').split(',').concat(
                (url.searchParams.get('lsparams') || '').split(',')));
              for (const name of ['range', 'rn', 'rbuf', 'ump']) {
                if (url.searchParams.has(name) && signed.has(name)) return;
                url.searchParams.delete(name);
              }
              const key = (url.searchParams.get('itag') || '') + ':' + mime +
                ':' + (url.searchParams.get('id') || '');
              const previousOwner = sourceOwners.get(key);
              if (previousOwner && previousOwner !== videoID) return;
              if (seenSources.has(key) || seenSources.size >= 4) return;
              if (sourceOwners.size >= 256) sourceOwners.delete(sourceOwners.keys().next().value);
              sourceOwners.set(key, videoID);
              seenSources.add(key);
              post({kind:'nativeSource', videoID, audioTrack, videoHeight, url:url.toString(), mime});
            } catch (_) {}
          };
          let lastSourceInventory = '';
          const scanPlayerSources = () => {
            try {
              const videoID = new URL(location.href).searchParams.get('v') || '';
              if (!videoID || document.querySelector('.html5-video-player')?.classList.contains('ad-showing')) return null;
              const response = document.getElementById('movie_player')?.getPlayerResponse?.();
              // The player may still describe the previous SPA video.
              if (response?.videoDetails?.videoId !== videoID) return null;
              const data = response.streamingData;
              if (!data) return null;
              const formats = [...(data.formats || []), ...(data.adaptiveFormats || [])];
              let hlsEndpoint = 'none', hlsHost = 'none';
              try {
                const manifest = new URL(data.hlsManifestUrl);
                hlsEndpoint = manifest.pathname.split('/').slice(0, 4).join('/');
                hlsHost = manifest.hostname;
              } catch (_) {}
              const inventory = {kind:'nativeSourceInventory', videoID,
                formats:formats.length, direct:formats.filter(f => typeof f.url === 'string').length,
                cipher:formats.filter(f => f.signatureCipher || f.cipher).length,
                audio:formats.filter(f => String(f.mimeType || '').startsWith('audio/')).length,
                hls:!!data.hlsManifestUrl, hlsHost, hlsEndpoint, dash:!!data.dashManifestUrl,
                sabr:!!data.serverAbrStreamingUrl};
              const key = JSON.stringify(inventory);
              if (key !== lastSourceInventory) { lastSourceInventory = key; post(inventory); }
              // Only use already available URLs. Never guess or bypass signatures.
              // Capture the URL the current video actually uses, after the
              // YouTube player has applied its own challenge transformation.
              try {
                const video = document.querySelector('.html5-video-player video');
                const actual = new URL(video?.currentSrc || '');
                const reference = new URL(data.hlsManifestUrl || '');
                const pathValue = (url, key) => url.searchParams.get(key) ||
                  decodeURIComponent(url.pathname.match(new RegExp('/' + key + '/([^/]+)'))?.[1] || '');
                if (Number.isFinite(video?.duration) &&
                    Math.abs(video.duration - Number(response.videoDetails.lengthSeconds)) < 3 &&
                    pathValue(reference, 'id') &&
                    pathValue(actual, 'id') === pathValue(reference, 'id') &&
                    pathValue(actual, 'expire') === pathValue(reference, 'expire')) {
                  observeMediaURL(actual.toString(), 'application/vnd.apple.mpegurl');
                }
              } catch (_) {}
              return response;
            } catch (_) { return null; }
          };
          // YouTube's HLS muxed variants use IDs/xtags, outside AVPlayer's language groups.
          const readAudioTrack = () => {
            const player = document.getElementById('movie_player');
            const videoID = new URL(location.href).searchParams.get('v') || '';
            const clean = (value) => typeof value === 'string' && !value.includes('://') ? value.slice(0,160) : '';
            let track = null, response = null;
            try { track = player?.getAudioTrack?.(); response = player?.getPlayerResponse?.(); } catch (_) {}
            if (!videoID || response?.videoDetails?.videoId !== videoID) return {known:false, key:''};
            const id = clean(track?.id);
            const xtags = clean(track?.xtags);
            const data = response.streamingData;
            const defaults = [...(data?.formats || []), ...(data?.adaptiveFormats || [])]
              .map(f => f.audioTrack).filter(t => t?.audioIsDefault === true);
            const defaultIDs = [...new Set(defaults.map(t => clean(t.id)).filter(Boolean))].sort();
            const known = /^[A-Za-z0-9_.-]+$/.test(id) || !!xtags;
            return {known, id, xtags, defaultID:defaultIDs.join(','),
              key:known ? JSON.stringify([id, xtags, defaultIDs]) : ''};
          };
          const readPlaybackRate = (video) => {
            const rate = Number(video?.playbackRate);
            return Number.isFinite(rate) && rate >= 0.25 && rate <= 4 ? rate : 1;
          };
          const audioChoicesForVideo = (videoID) => {
            try {
              const response = document.getElementById('movie_player')?.getPlayerResponse?.();
              if (response?.videoDetails?.videoId !== videoID) return [];
              const formats = [...(response.streamingData?.formats || []),
                ...(response.streamingData?.adaptiveFormats || [])];
              const choices = new Map();
              for (const format of formats) {
                const track = format.audioTrack;
                const id = String(track?.id || '');
                const xtags = String(format.xtags || '');
                if (!/^[A-Za-z0-9_.-]{1,80}$/.test(id) || !/^[A-Za-z0-9_-]{1,160}$/.test(xtags)) continue;
                if (!choices.has(id) || xtags.length < choices.get(id).xtags.length)
                  choices.set(id,{id,xtags,name:String(track.displayName || id).slice(0,80)});
              }
              return [...choices.values()].slice(0,20);
            } catch (_) { return []; }
          };
          const captionTrackID = (track, index) => String(track.vssId ||
            [track.languageCode || 'und', track.kind || '', index].join(':')).slice(0,160);
          const captionTracksForVideo = (videoID) => {
            try {
              const response = document.getElementById('movie_player')?.getPlayerResponse?.();
              if (response?.videoDetails?.videoId !== videoID) return [];
              return (response.captions?.playerCaptionsTracklistRenderer?.captionTracks || []).slice(0,50);
            } catch (_) { return []; }
          };
          const readCaptionSettings = (videoID) => {
            const tracks = captionTracksForVideo(videoID);
            let selected = null;
            const player = document.getElementById('movie_player');
            try { selected = player?.getOption?.('captions','track'); } catch (_) {}
            const button = player?.querySelector?.('.ytp-subtitles-button');
            const enabled = button ? button.getAttribute('aria-pressed') === 'true' : !!selected?.languageCode;
            let index = tracks.findIndex(t => t.vssId && t.vssId === selected?.vssId);
            if (index < 0) index = tracks.findIndex(t => t.languageCode === selected?.languageCode &&
              (t.kind || '') === (selected?.kind || ''));
            if (index < 0 && enabled && tracks.length) index = 0;
            return {enabled:enabled && index >= 0, selectedID:index >= 0 ? captionTrackID(tracks[index],index) : '',
              tracks:tracks.map((t,i) => ({id:captionTrackID(t,i), languageCode:String(t.languageCode || '').slice(0,40),
                name:String(t.name?.simpleText || t.name?.runs?.map(r => r.text).join('') || t.languageCode || '字幕').slice(0,100)}))};
          };
          const parseCaptionBody = (body) => {
            const rows = [];
            if (body.trimStart().startsWith('{')) {
              const data = JSON.parse(body);
              for (const event of data.events || []) {
                if (!Array.isArray(event.segs)) continue;
                const start = Number(event.tStartMs) / 1000;
                const end = start + Number(event.dDurationMs) / 1000;
                rows.push({start,end,text:event.segs.map(s => s.utf8 || '').join('').trim()});
              }
            } else {
              const xml = new DOMParser().parseFromString(body,'application/xml');
              if (xml.querySelector('parsererror')) return [];
              for (const node of xml.querySelectorAll('text, body > p')) {
                const modern = node.hasAttribute('t');
                const start = Number(node.getAttribute(modern ? 't' : 'start')) / (modern ? 1000 : 1);
                const duration = Number(node.getAttribute(modern ? 'd' : 'dur')) / (modern ? 1000 : 1);
                rows.push({start,end:start+duration,text:String(node.textContent || '').trim()});
              }
            }
            return rows.filter(c => Number.isFinite(c.start) && Number.isFinite(c.end) &&
              c.start >= 0 && c.end > c.start && c.text).slice(0,12000)
              .map(c => ({...c,text:c.text.slice(0,800)}));
          };
          const captionCuesCache = new Map();
          const timedTextURL = (raw) => {
            try {
              const url = new URL(raw,location.href);
              return url.protocol === 'https:' && !url.username && !url.password &&
                (url.hostname === 'youtube.com' || url.hostname.endsWith('.youtube.com')) &&
                url.pathname === '/api/timedtext' ? url : null;
            } catch (_) { return null; }
          };
          const rememberCaptionResponse = (raw,body,requestVideoID) => {
            const url = timedTextURL(raw);
            const currentID = new URL(location.href).searchParams.get('v');
            if (!url || !currentID || currentID !== requestVideoID ||
                url.searchParams.get('v') !== currentID || url.searchParams.has('tlang') ||
                typeof body !== 'string' || body.length > 2*1024*1024) return;
            const tracks = captionTracksForVideo(currentID);
            const index = tracks.findIndex(t => t.languageCode === url.searchParams.get('lang') &&
              (t.kind || '') === (url.searchParams.get('kind') || ''));
            if (index < 0) return;
            try {
              const cues = parseCaptionBody(body);
              if (!cues.length) return;
              const key = currentID + ':' + captionTrackID(tracks[index],index);
              if (captionCuesCache.size >= 4 && !captionCuesCache.has(key))
                captionCuesCache.delete(captionCuesCache.keys().next().value);
              captionCuesCache.set(key,cues);
            } catch (_) {}
          };
          // Observe the player's normal request after it applies its own session
          // parameters. Originals still receive the unmodified response.
          if (typeof window.fetch === 'function') {
            const originalFetch = window.fetch;
            window.fetch = function(input,...args) {
              const raw = typeof input === 'string' || input instanceof URL ? String(input) : input?.url;
              const requestID = new URL(location.href).searchParams.get('v');
              const result = originalFetch.call(this,input,...args);
              if (timedTextURL(raw)) result.then(response => {
                if (!response.ok) return;
                response.clone().text().then(body => rememberCaptionResponse(raw,body,requestID)).catch(() => {});
              }).catch(() => {});
              return result;
            };
          }
          if (typeof XMLHttpRequest !== 'undefined') {
            const originalOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method,raw,...args) {
              const result = originalOpen.call(this,method,raw,...args);
              if (timedTextURL(raw)) {
                const requestID = new URL(location.href).searchParams.get('v');
                const receive = () => {
                  this.removeEventListener('load',receive);
                  this.removeEventListener('loadend',cleanup);
                  try {
                    if (this.status < 200 || this.status >= 300) return;
                    const body = this.responseType === 'json' ? JSON.stringify(this.response) : this.responseText;
                    rememberCaptionResponse(raw,body,requestID);
                  } catch (_) {}
                };
                const cleanup = () => {
                  this.removeEventListener('load',receive);
                  this.removeEventListener('loadend',cleanup);
                };
                this.addEventListener('load',receive);
                this.addEventListener('loadend',cleanup);
              }
              return result;
            };
          }
          window.__rayLoadNativeCaptions = async (videoID, trackID) => {
            const matches = () => window.__rayNativePiPOwner === videoID &&
              new URL(location.href).searchParams.get('v') === videoID;
            if (!matches()) return null;
            const tracks = captionTracksForVideo(videoID);
            const index = tracks.findIndex((t,i) => captionTrackID(t,i) === trackID);
            if (index < 0) return null;
            const cached = () => captionCuesCache.get(videoID + ':' + trackID);
            const payload = cues => ({videoID,trackID,cues});
            if (cached()) return payload(cached());
            // Ask the paused webpage player to load this real track through its
            // normal caption module. Capture its response, without rebuilding URLs.
            const player = document.getElementById('movie_player');
            if (typeof player?.loadModule === 'function' && typeof player?.setOption === 'function') {
              try {
                player.loadModule('captions');
                player.setOption('captions','track',tracks[index]);
                for (let attempt=0; attempt<80 && matches(); attempt++) {
                  if (cached()) return payload(cached());
                  await new Promise(resolve => setTimeout(resolve,100));
                  if (attempt === 3 || attempt === 9) player.setOption('captions','track',tracks[index]);
                }
              } catch (_) {}
            }
            if (!matches()) return null;
            const url = timedTextURL(tracks[index].baseUrl);
            if (!url) return null;
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(),15000);
            try {
              const response = await fetch(url.toString(),{credentials:'same-origin',signal:controller.signal});
              if (!response.ok || !matches()) return null;
              const body = await response.text();
              if (!matches() || body.length > 2*1024*1024) return null;
              return payload(parseCaptionBody(body));
            } catch (_) { return null; } finally { clearTimeout(timeout); }
          };
          const readWebPlaybackSettings = () => {
            const videoID = new URL(location.href).searchParams.get('v') || '';
            const video = document.querySelector('.html5-video-player video');
            const player = document.querySelector('.html5-video-player');
            if (!videoID || !video || window.__rayNativePiPOwner ||
                player?.classList.contains('ad-showing')) return null;
            return {videoID, playbackRate:readPlaybackRate(video),
              captions:readCaptionSettings(videoID), audioChoices:audioChoicesForVideo(videoID)};
          };
          let webCaptionOffVideoID = '';
          const observedWebCaptionTracks = new WeakSet();
          const disableShowingWebTextTracks = (player) => {
            for (const track of player?.querySelector?.('video')?.textTracks || []) {
              if (track.mode === 'showing') track.mode = 'disabled';
            }
          };
          const setWebCaptionOverlayHidden = (player, hidden) => {
            if (!document.getElementById('ray-caption-overlay-style')) {
              const style = document.createElement('style');
              style.id = 'ray-caption-overlay-style';
              style.textContent = 'html.ray-captions-off .ytp-caption-window-container, html.ray-captions-off .caption-window, html.ray-captions-off .ytp-caption-segment {visibility:hidden!important}';
              (document.head || document.documentElement).appendChild(style);
            }
            const rootClasses = document.documentElement.classList;
            if (rootClasses.contains('ray-captions-off') !== hidden)
              rootClasses.toggle('ray-captions-off', hidden);
            if (player?.classList.contains('ray-captions-off') !== hidden)
              player?.classList.toggle('ray-captions-off', hidden);
          };
          const syncWebCaptionOverlay = (player, videoID) => {
            if (!player || !videoID) return;
            if (webCaptionOffVideoID && webCaptionOffVideoID !== videoID) webCaptionOffVideoID = '';
            const button = player?.querySelector?.('.ytp-subtitles-button');
            const hidden = webCaptionOffVideoID === videoID ||
              button?.getAttribute('aria-pressed') === 'false';
            setWebCaptionOverlayHidden(player, hidden);
            const video = player.querySelector('video');
            const tracks = video?.textTracks;
            if (tracks && !observedWebCaptionTracks.has(tracks)) {
              observedWebCaptionTracks.add(tracks);
              tracks.addEventListener?.('change', () => {
                const currentID = new URL(location.href).searchParams.get('v') || '';
                const currentPlayer = document.querySelector('.html5-video-player');
                if (!currentID || window.__rayNativePiPOwner ||
                    currentPlayer?.querySelector('video') !== video) return;
                syncWebCaptionOverlay(currentPlayer, currentID);
              });
            }
            if (hidden) disableShowingWebTextTracks(player);
          };
          const disableWebCaptions = (player, videoID) => {
            webCaptionOffVideoID = videoID;
            setWebCaptionOverlayHidden(player, true);
            const button = player?.querySelector?.('.ytp-subtitles-button');
            try { if (button?.getAttribute('aria-pressed') === 'true') button.click(); } catch (_) {}
            try { player?.setOption?.('captions','track',{}); } catch (_) {}
            try { player?.unloadModule?.('captions'); } catch (_) {}
            syncWebCaptionOverlay(player, videoID);
          };
          const enableWebCaptions = (player, track) => {
            webCaptionOffVideoID = '';
            setWebCaptionOverlayHidden(player, false);
            player?.loadModule?.('captions');
            const button = player?.querySelector?.('.ytp-subtitles-button');
            if (button?.getAttribute('aria-pressed') === 'false') button.click();
            player?.setOption?.('captions','track',track);
          };
          const applyWebPlaybackSetting = (videoID, rate = null, captionID = null) => {
            const settings = readWebPlaybackSettings();
            if (!settings || settings.videoID !== videoID) return false;
            const video = document.querySelector('.html5-video-player video');
            const player = document.getElementById('movie_player');
            if (rate !== null) {
              if (!Number.isFinite(rate) || rate < 0.25 || rate > 2) return false;
              try { player?.setPlaybackRate?.(rate); } catch (_) {}
              video.playbackRate = rate;
            }
            if (captionID !== null) {
              const tracks = captionTracksForVideo(videoID);
              const index = tracks.findIndex((t,i) => captionTrackID(t,i) === captionID);
              if (captionID && index < 0) return false;
              try {
                if (captionID) {
                  enableWebCaptions(player,tracks[index]);
                } else disableWebCaptions(player,videoID);
              } catch (_) { return false; }
            }
            return true;
          };
          window.__raySetNativePlaybackRate = (videoID, rate) => {
            const video = window.__rayNativePiPVideo;
            if (window.__rayNativePiPOwner !== videoID ||
                new URL(location.href).searchParams.get('v') !== videoID ||
                document.querySelector('.html5-video-player video') !== video ||
                !Number.isFinite(rate) || rate < 0.25 || rate > 4) return false;
            try { document.getElementById('movie_player')?.setPlaybackRate?.(rate); } catch (_) {}
            video.playbackRate = rate;
            return true;
          };
          window.__rayNativePiPOwner = '';
          window.__rayNativePiPVideo = null;
          window.__rayNativePiPMetadata = null;
          window.__rayResetPiPButton = () => {
            const pipButton = document.querySelector('.ray-pip-button');
            if (pipButton) { pipButton.disabled = false; pipButton.title = '画中画 / 后台播放'; }
            const audioButton = document.querySelector('.ray-audio-button');
            if (audioButton) { audioButton.disabled = false; audioButton.title = '点击切换后台播放'; }
          };
          window.__rayPauseForNativePiP = (videoID, automaticSource = '', expectedAudioKey = '') => {
            if (new URL(location.href).searchParams.get('v') !== videoID ||
                document.querySelector('.html5-video-player')?.classList.contains('ad-showing')) return null;
            const video = document.querySelector('.html5-video-player video');
            if (!video || !Number.isFinite(video.currentTime)) return null;
            if (automaticSource) {
              const response = document.getElementById('movie_player')?.getPlayerResponse?.();
              if (video.paused || video.ended || window.__rayNativePiPOwner ||
                  response?.videoDetails?.videoId !== videoID ||
                  video.currentSrc !== automaticSource) return null;
            }
            const audio = readAudioTrack();
            if (!audio.known || !expectedAudioKey || audio.key !== expectedAudioKey) return null;
            window.__rayHideWebSettings?.();
            const wasPlaying = !video.paused;
            const playbackRate = readPlaybackRate(video);
            const captions = readCaptionSettings(videoID);
            window.__rayNativePiPOwner = videoID;
            window.__rayNativePiPVideo = video;
            window.__rayNativePiPMetadata = navigator.mediaSession?.metadata || null;
            video.pause();
            try {
              navigator.mediaSession.playbackState = 'none';
              navigator.mediaSession.metadata = null;
            } catch (_) {}
            return {videoID, audioKey:audio.key, currentTime:video.currentTime, playbackRate, captions, wasPlaying, paused:video.paused};
          };
          window.__rayRestoreAfterNativePiP = (videoID, time, play, rate, captionID = null) => {
            window.__rayResetPiPButton();
            if (window.__rayNativePiPOwner !== videoID) return false;
            const video = window.__rayNativePiPVideo;
            const metadata = window.__rayNativePiPMetadata;
            window.__rayNativePiPOwner = '';
            window.__rayNativePiPVideo = null;
            window.__rayNativePiPMetadata = null;
            if (new URL(location.href).searchParams.get('v') !== videoID || !video?.isConnected ||
                document.querySelector('.html5-video-player video') !== video) return false;
            video.pause();
            try { video.currentTime = Math.max(0, Math.min(time, Number.isFinite(video.duration) ? video.duration : time)); } catch (_) {}
            const player = document.getElementById('movie_player');
            const playbackRate = Number.isFinite(rate) && rate >= 0.25 && rate <= 4 ? rate : readPlaybackRate(video);
            try { player?.setPlaybackRate?.(playbackRate); } catch (_) {}
            video.playbackRate = playbackRate;
            if (captionID !== null) {
              try {
                if (!captionID) {
                  disableWebCaptions(player,videoID);
                } else {
                  const tracks = captionTracksForVideo(videoID);
                  const index = tracks.findIndex((t,i) => captionTrackID(t,i) === captionID);
                  if (index >= 0) {
                    enableWebCaptions(player,tracks[index]);
                  }
                }
              } catch (_) {}
            }
            try { navigator.mediaSession.metadata = metadata; } catch (_) {}
            window.__rayRefreshWebSettings?.();
            if (play) video.play()?.catch?.(() => post({kind:'nativeRestoreFailed'}));
            return true;
          };

          const adSkipSelectors = [
            '.ytp-skip-ad-button',
            '.ytp-ad-skip-button',
            '.ytp-ad-skip-button-modern',
            'button[id^="skip-button"]'
          ];

          const findVisibleSkipButton = () => {
            const player = document.querySelector('.html5-video-player');
            if (!player?.classList.contains('ad-showing')) return null;
            for (const selector of adSkipSelectors) {
              for (const button of player.querySelectorAll(selector)) {
                if (!(button instanceof HTMLElement)) continue;
                const rect = button.getBoundingClientRect();
                const style = getComputedStyle(button);
                if (rect.width < 2 || rect.height < 2) continue;
                if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) <= 0) continue;
                return button;
              }
            }
            return null;
          };

          let lastAdSkipText = '';
          let lastAdSkipRequestAt = 0;
          const scanForSkippableAd = () => {
            const button = findVisibleSkipButton();
            if (!button) return;

            const rawText = String(button.innerText || button.textContent || button.getAttribute('aria-label') || '');
            const text = rawText.replace(/\s+/g, ' ').trim();
            if (!text) return;

            const now = Date.now();
            if (text === lastAdSkipText && now - lastAdSkipRequestAt < 1200) return;
            lastAdSkipText = text;
            lastAdSkipRequestAt = now;

            post({kind:'adSkipDetected', text, id:button.id || '', cls:String(button.className || '').slice(0,180)});
            try { window.webkit?.messageHandlers?.adSkip?.postMessage({text}); } catch (_) {}
          };

          for (const type of ['mousedown', 'mouseup', 'click']) {
            document.addEventListener(type, (event) => {
              const target = event.target instanceof Element ? event.target : null;
              const button = target?.closest?.(adSkipSelectors.join(','));
              if (!button) return;
              post({
                kind:'adSkipEvent',
                type,
                isTrusted:!!event.isTrusted,
                text:String(button.innerText || button.textContent || '').replace(/\s+/g, ' ').trim()
              });
            }, true);
          }

          const reportMediaState = (event = 'snapshot') => {
            const sourceResponse = scanPlayerSources();
            const videos = Array.from(document.querySelectorAll('video'));
            const pipVideo = videos.find(v => v.webkitPresentationMode === 'picture-in-picture' ||
              document.pictureInPictureElement === v);
            const video = pipVideo || document.querySelector('.html5-video-player video') || videos[0];
            let transport = 'unknown';
            try {
              const data = document.getElementById('movie_player')?.getPlayerResponse?.()?.streamingData;
              transport = data?.serverAbrStreamingUrl ? 'SABR' : (data ? 'adaptive' : 'unknown');
            } catch (_) {}
            post({
              kind:'mediaState', event, pip:!!pipVideo,
              audioTrack:readAudioTrack(), videoHeight:video?.videoHeight || 1080,
              videoID:new URL(location.href).searchParams.get('v') || '',
              ad:!!document.querySelector('.html5-video-player')?.classList.contains('ad-showing'),
              transport,
              sourceKind:video?.currentSrc?.startsWith('blob:') ? 'MSE' :
                (video?.currentSrc?.startsWith('https:') ? 'URL' : 'none'),
              sourceDuration:Number(sourceResponse?.videoDetails?.lengthSeconds) || 0,
              paused:video ? !!video.paused : true,
              ended:video ? !!video.ended : false,
              currentTime:video ? video.currentTime : 0,
              playbackRate:readPlaybackRate(video),
              readyState:video ? video.readyState : 0,
              muted:video ? !!video.muted : false,
              volume:video ? video.volume : 0,
              duration:video && Number.isFinite(video.duration) ? video.duration : 0,
              title:String(navigator.mediaSession?.metadata?.title ||
                document.querySelector('h1.ytd-watch-metadata')?.textContent || document.title || '').trim(),
              artist:String(navigator.mediaSession?.metadata?.artist ||
                document.querySelector('ytd-watch-metadata #channel-name')?.textContent || '').trim(),
              mode:video ? String(video.webkitPresentationMode || 'inline') : 'none',
              visibility:document.visibilityState
            });
          };

          const forceInline = (video) => {
            if (!(video instanceof HTMLVideoElement)) return;
            if (!video.hasAttribute('playsinline')) video.setAttribute('playsinline', '');
            if (!video.hasAttribute('webkit-playsinline')) video.setAttribute('webkit-playsinline', '');
            if (!video.playsInline) video.playsInline = true;
            try { video.removeAttribute('disablepictureinpicture'); } catch (_) {}
            try { if ('disablePictureInPicture' in video) video.disablePictureInPicture = false; } catch (_) {}
          };

          const forceInlineInNode = (node) => {
            if (!(node instanceof Element)) return;
            if (node.matches('video')) forceInline(node);
            node.querySelectorAll?.('video').forEach(forceInline);
          };

          const forceAllInline = () => document.querySelectorAll('video').forEach(forceInline);

          const ensurePhoneLayoutFix = () => {
            if (document.getElementById('ray-phone-layout-fix')) return;
            const style = document.createElement('style');
            style.id = 'ray-phone-layout-fix';
            style.textContent = `
              ytd-mini-guide-renderer,
              #guide-spacer,
              #mini-guide-background {
                display: none !important;
                width: 0 !important;
                min-width: 0 !important;
                max-width: 0 !important;
                margin: 0 !important;
                padding: 0 !important;
              }

              /* Keep YouTube's real guide drawer alive so the hamburger
                 button can still open the overlay menu. Only the persistent
                 mini-guide above is suppressed for the phone layout. */
              tp-yt-app-drawer#guide,
              tp-yt-app-drawer#guide ytd-guide-renderer,
              tp-yt-app-drawer#guide #guide-content,
              tp-yt-app-drawer#guide #guide-inner-content {
                box-sizing: border-box !important;
              }

              ytd-app,
              ytd-page-manager,
              #page-manager,
              ytd-app[mini-guide-visible] ytd-page-manager,
              ytd-app[guide-persistent-and-visible] ytd-page-manager,
              #content.ytd-app,
              #contentContainer.tp-yt-app-drawer {
                margin-left: 0 !important;
                padding-left: 0 !important;
                left: 0 !important;
              }

              ytd-app[mini-guide-visible] {
                --ytd-mini-guide-width: 0px !important;
              }

              ytd-watch-flexy,
              ytd-watch-flexy #columns,
              ytd-watch-flexy #primary,
              ytd-watch-flexy #primary-inner,
              ytd-watch-flexy #below,
              ytd-watch-flexy #player,
              ytd-watch-flexy #player-container-outer,
              ytd-watch-flexy #player-container-inner {
                margin-left: 0 !important;
                padding-left: 0 !important;
                left: 0 !important;
                transform: none !important;
                box-sizing: border-box !important;
                max-width: 100% !important;
              }

              ytd-watch-flexy #columns,
              ytd-watch-flexy #primary,
              ytd-watch-flexy #primary-inner,
              ytd-watch-flexy #below,
              ytd-watch-flexy #player,
              ytd-watch-flexy #player-container-outer,
              ytd-watch-flexy #player-container-inner {
                width: 100% !important;
                min-width: 0 !important;
              }

              ytd-watch-flexy #below {
                padding-left: 16px !important;
                padding-right: 16px !important;
              }

              html, body {
                overflow-x: hidden !important;
              }
            `;
            (document.head || document.documentElement).appendChild(style);
          };

          const updateChannelPageClass = () => {
            const path = String(location.pathname || '');
            const isChannelPage = /^\/@[^/]+(?:\/|$)/.test(path) ||
              /^\/channel\//.test(path) ||
              /^\/c\//.test(path) ||
              /^\/user\//.test(path);
            document.documentElement.classList.toggle('ray-channel-page', isChannelPage);
          };

          const ensureChannelLayoutFix = () => {
            if (document.getElementById('ray-channel-layout-fix')) return;
            const style = document.createElement('style');
            style.id = 'ray-channel-layout-fix';
            style.textContent = `
              html.ray-channel-page,
              html.ray-channel-page body,
              html.ray-channel-page ytd-app,
              html.ray-channel-page ytd-page-manager,
              html.ray-channel-page #page-manager,
              html.ray-channel-page ytd-browse,
              html.ray-channel-page ytd-two-column-browse-results-renderer,
              html.ray-channel-page ytd-two-column-browse-results-renderer #primary,
              html.ray-channel-page ytd-two-column-browse-results-renderer #contents,
              html.ray-channel-page ytd-rich-grid-renderer,
              html.ray-channel-page ytd-grid-renderer,
              html.ray-channel-page ytd-c4-tabbed-header-renderer,
              html.ray-channel-page ytd-tabbed-page-header,
              html.ray-channel-page #channel-container,
              html.ray-channel-page #tabsContent {
                width: 100% !important;
                max-width: 100vw !important;
                min-width: 0 !important;
                margin-left: 0 !important;
                margin-right: 0 !important;
                box-sizing: border-box !important;
              }

              html.ray-channel-page body,
              html.ray-channel-page #page-manager,
              html.ray-channel-page ytd-browse {
                overflow-x: hidden !important;
              }

              html.ray-channel-page ytd-browse #primary,
              html.ray-channel-page ytd-browse #contents,
              html.ray-channel-page ytd-browse #tabsContent {
                padding-left: 8px !important;
                padding-right: 8px !important;
                box-sizing: border-box !important;
              }

              html.ray-channel-page ytd-rich-grid-renderer {
                --ytd-rich-grid-items-per-row: 2 !important;
                --ytd-rich-grid-posts-per-row: 2 !important;
                --ytd-rich-grid-item-margin: 6px !important;
                --ytd-rich-grid-row-margin: 14px !important;
              }

              html.ray-channel-page ytd-rich-grid-row,
              html.ray-channel-page ytd-rich-grid-row #contents,
              html.ray-channel-page ytd-grid-renderer #items {
                width: 100% !important;
                max-width: 100% !important;
                min-width: 0 !important;
                box-sizing: border-box !important;
              }

              html.ray-channel-page ytd-rich-grid-row #contents,
              html.ray-channel-page ytd-grid-renderer #items {
                display: grid !important;
                grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
                gap: 14px 10px !important;
                align-items: start !important;
              }

              html.ray-channel-page ytd-rich-item-renderer,
              html.ray-channel-page ytd-grid-video-renderer {
                width: auto !important;
                min-width: 0 !important;
                max-width: 100% !important;
                margin: 0 !important;
                box-sizing: border-box !important;
              }

              html.ray-channel-page ytd-rich-item-renderer #content,
              html.ray-channel-page ytd-grid-video-renderer #dismissible,
              html.ray-channel-page ytd-thumbnail,
              html.ray-channel-page ytd-thumbnail a,
              html.ray-channel-page ytd-thumbnail yt-image,
              html.ray-channel-page ytd-thumbnail img {
                width: 100% !important;
                max-width: 100% !important;
                min-width: 0 !important;
                box-sizing: border-box !important;
              }

              html.ray-channel-page ytd-rich-item-renderer #video-title,
              html.ray-channel-page ytd-grid-video-renderer #video-title {
                max-width: 100% !important;
                overflow: hidden !important;
                display: -webkit-box !important;
                -webkit-line-clamp: 2 !important;
                -webkit-box-orient: vertical !important;
              }

              html.ray-channel-page tp-yt-paper-tabs,
              html.ray-channel-page #tabsContainer,
              html.ray-channel-page #tabsContent {
                width: 100% !important;
                max-width: 100vw !important;
                min-width: 0 !important;
              }

              html.ray-channel-page tp-yt-paper-tabs {
                overflow-x: auto !important;
                overflow-y: hidden !important;
                scrollbar-width: none !important;
              }

              html.ray-channel-page tp-yt-paper-tabs::-webkit-scrollbar {
                display: none !important;
              }

              html.ray-channel-page tp-yt-paper-tab,
              html.ray-channel-page yt-tab-shape {
                flex: 0 0 auto !important;
                min-width: max-content !important;
              }
            `;
            (document.head || document.documentElement).appendChild(style);
          };

          const ensureFullscreenOverride = () => {
            const player = document.querySelector('.html5-video-player');
            const button = player?.querySelector('.ytp-fullscreen-button');
            if (!player || !button || button.dataset.rayFullscreenBound === '1') return;
            button.dataset.rayFullscreenBound = '1';

            button.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopImmediatePropagation();

              const video = player.querySelector('video') || document.querySelector('video');
              if (!(video instanceof HTMLVideoElement)) {
                post({kind:'fullscreenRequest', ok:false, reason:'no-video'});
                return;
              }

              try {
                const supported = typeof video.webkitSupportsPresentationMode === 'function' &&
                  typeof video.webkitSetPresentationMode === 'function' &&
                  !!video.webkitSupportsPresentationMode('fullscreen');
                if (supported) video.webkitSetPresentationMode('fullscreen');
                post({kind:'fullscreenRequest', ok:supported, mode:String(video.webkitPresentationMode || '')});
              } catch (error) {
                post({kind:'fullscreenError', error:String(error)});
              }
            }, true);
          };

          const ensurePiPButton = () => {
            const player = document.querySelector('.html5-video-player');
            if (!player || player.querySelector('.ray-pip-button')) return;

            const fullscreen = player.querySelector('.ytp-fullscreen-button');
            const controls = fullscreen?.parentElement ||
              player.querySelector('.ytp-right-controls') ||
              player.querySelector('.ytp-chrome-controls') ||
              player.querySelector('.ytp-chrome-bottom');
            if (!controls) return;

            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'ytp-button ray-pip-button';
            button.setAttribute('aria-label', '画中画 / 后台播放');
            button.setAttribute('title', '画中画 / 后台播放');
            button.style.width = '48px';
            button.style.padding = '0 8px';
            button.innerHTML = '<svg viewBox="0 0 36 36" width="100%" height="100%" aria-hidden="true"><path fill="currentColor" d="M6 8h24v20H6V8zm2.5 2.5v15h19v-15h-19zM18 17h7v6h-7v-6z"></path></svg>';

            button.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopPropagation();

              const video = player.querySelector('video') || document.querySelector('video');
              if (!(video instanceof HTMLVideoElement)) {
                post({kind:'pipRequest', ok:false, reason:'no-video'});
                return;
              }

              forceInline(video);
              const videoID = new URL(location.href).searchParams.get('v') || '';
              if (!videoID || player.classList.contains('ad-showing')) {
                post({kind:'pipError', message:'请在视频内容开始播放后进入画中画。'});
                return;
              }
              const rect = video.getBoundingClientRect();
              button.disabled = true;
              button.title = '正在准备画中画';
              reportMediaState('nativePiPRequest');
              post({kind:'nativePiPRequest', videoID, ad:false,
                rect:{x:rect.x/innerWidth, y:rect.y/innerHeight,
                      width:rect.width/innerWidth, height:rect.height/innerHeight}});
            }, true);

            if (fullscreen && fullscreen.parentElement === controls) {
              controls.insertBefore(button, fullscreen);
            } else {
              controls.appendChild(button);
            }
          };

          const ensureAudioButton = () => {
            const player = document.querySelector('.html5-video-player');
            const pipButton = player?.querySelector('.ray-pip-button');
            if (!player || !pipButton || player.querySelector('.ray-audio-button')) return;
            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'ytp-button ray-audio-button';
            button.setAttribute('aria-label', '点击切换后台播放');
            button.setAttribute('title', '点击切换后台播放');
            button.style.width = '48px';
            button.style.padding = '0 8px';
            button.innerHTML = '<svg viewBox="0 0 36 36" width="100%" height="100%" aria-hidden="true"><path fill="currentColor" d="M18 7a11 11 0 0 0-11 11v9h7V16h-4a8 8 0 0 1 16 0h-4v11h7v-9A11 11 0 0 0 18 7z"></path></svg>';
            button.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopPropagation();
              const video = player.querySelector('video');
              const videoID = new URL(location.href).searchParams.get('v') || '';
              if (!(video instanceof HTMLVideoElement) || !videoID ||
                  player.classList.contains('ad-showing')) {
                post({kind:'pipError', message:'请在视频内容开始播放后开启后台音频。'});
                return;
              }
              forceInline(video);
              const rect = video.getBoundingClientRect();
              button.disabled = true;
              pipButton.disabled = true;
              button.title = '正在准备后台音频';
              reportMediaState('nativeAudioRequest');
              post({kind:'nativeAudioRequest', playbackMode:'audio', videoID, ad:false,
                rect:{x:rect.x/innerWidth, y:rect.y/innerHeight,
                      width:rect.width/innerWidth, height:rect.height/innerHeight}});
            }, true);
            pipButton.parentElement.insertBefore(button, pipButton);
          };

          let refreshPending = false;
          let webSettingsHost = null, webSettingsPanel = null;
          const closeWebSettings = () => {
            webSettingsPanel?.remove();
            webSettingsPanel = null;
            webSettingsHost?.setAttribute('aria-expanded','false');
          };
          const requestWebAudioChoice = (videoID, audioID) => {
            const current = readWebPlaybackSettings();
            const choice = current?.audioChoices.find(t => t.id === audioID);
            const video = document.querySelector('.html5-video-player video');
            const audio = readAudioTrack();
            if (!choice || current.videoID !== videoID || !video || !audio.known || !audio.key) return false;
            const rect = video.getBoundingClientRect();
            closeWebSettings();
            post({kind:'nativeAudioTrackRequest', videoID, audioKey:audio.key,
              audioID:choice.id, audioXtags:choice.xtags, audioName:choice.name,
              playbackMode:'audio', ad:false,
              rect:{x:rect.x/innerWidth, y:rect.y/innerHeight,
                    width:rect.width/innerWidth, height:rect.height/innerHeight}});
            return true;
          };
          const ensureWebPlaybackSettings = () => {
            const player = document.querySelector('.html5-video-player');
            const settings = readWebPlaybackSettings();
            if (!player || !settings) {
              if (webSettingsHost) webSettingsHost.style.display = 'none';
              closeWebSettings();
              return;
            }
            syncWebCaptionOverlay(player, settings.videoID);
            if (!webSettingsHost || webSettingsHost.parentElement !== player) {
              webSettingsHost?.remove();
              closeWebSettings();
              const button = document.createElement('button');
              button.id = 'ray-web-playback-settings';
              button.type = 'button';
              button.setAttribute('aria-label','播放设置，倍速、字幕和音轨');
              button.setAttribute('aria-expanded','false');
              button.style.cssText = 'position:absolute;right:8px;bottom:48px;z-index:2147483000;min-width:76px;min-height:44px;padding:8px 12px;border:0;border-radius:8px;background:rgba(0,0,0,.75);color:white;font:16px -apple-system,sans-serif;cursor:pointer;pointer-events:auto;';
              for (const type of ['pointerdown','pointerup','touchstart','touchend'])
                button.addEventListener(type,event => event.stopPropagation());
              button.addEventListener('click',event => {
                event.preventDefault();event.stopPropagation();
                if (webSettingsPanel) { closeWebSettings(); return; }
                const current = readWebPlaybackSettings();
                if (!current) return;
                const panel = document.createElement('div');
                panel.id = 'ray-web-playback-settings-panel';
                panel.setAttribute('role','dialog');
                panel.setAttribute('aria-label','播放设置');
                const rect = button.getBoundingClientRect();
                panel.style.cssText = 'position:fixed;z-index:2147483647;width:230px;max-height:calc(100vh - 16px);overflow-y:auto;box-sizing:border-box;padding:12px;border-radius:12px;background:#252525;color:white;font:16px -apple-system,sans-serif;box-shadow:0 4px 20px #0008;';
                panel.style.right = Math.max(8,innerWidth-rect.right)+'px';
                panel.style.top = Math.max(8,Math.min(rect.top-260,innerHeight-280))+'px';
                panel.addEventListener('click',e => e.stopPropagation());
                const addSelect = (title,options,value,onChange,disabled=false,customChange=null) => {
                  const label = document.createElement('label');
                  label.style.cssText = 'display:block;margin:0 0 8px;font-size:14px;color:white;';
                  label.appendChild(document.createTextNode(title));
                  const select = document.createElement('select');
                  select.setAttribute('aria-label',title);
                  select.style.cssText = 'display:block;box-sizing:border-box;width:100%;height:44px;margin-top:4px;padding:8px;border:1px solid #777;border-radius:6px;background:#333;color:white;font:16px -apple-system,sans-serif;';
                  for (const [key,text] of options) {
                    const option = document.createElement('option');
                    option.value=key;option.textContent=text;select.appendChild(option);
                  }
                  select.value=value;select.disabled=disabled;
                  select.addEventListener('change',() => {
                    if (customChange) {
                      if (!customChange(select.value)) closeWebSettings();
                      return;
                    }
                    if (!applyWebPlaybackSetting(current.videoID,...onChange(select.value))) {
                      closeWebSettings();return;
                    }
                    reportMediaState('settings');
                    ensureWebPlaybackSettings();
                  });
                  label.appendChild(select);panel.appendChild(label);
                };
                const rates=[0.25,0.5,0.75,1,1.25,1.5,1.75,2];
                if (!rates.includes(current.playbackRate) && current.playbackRate<=2)
                  rates.push(current.playbackRate);
                addSelect('播放速度',rates.sort((a,b)=>a-b).map(r=>[String(r),r+'×']),
                  String(current.playbackRate),value=>[Number(value),null]);
                const tracks=current.captions.tracks;
                addSelect('字幕',tracks.length ? [['','关闭'],...tracks.map(t=>[t.id,t.name])] : [['','此视频暂无可用字幕']],
                  current.captions.enabled ? current.captions.selectedID : '',value=>[null,value],!tracks.length);
                if (current.audioChoices.length > 1) {
                  const audioOptions = [['','网页当前音轨'],...current.audioChoices.map(t=>[t.id,t.name])];
                  addSelect('音轨（切换至原生播放）',audioOptions,'',null,false,
                    value=>value ? requestWebAudioChoice(current.videoID,value) : true);
                }
                document.body.appendChild(panel);
                webSettingsPanel=panel;button.setAttribute('aria-expanded','true');
              });
              player.appendChild(button);
              webSettingsHost=button;
            }
            const text='⚙ '+settings.playbackRate+'×';
            if (webSettingsHost.textContent!==text) webSettingsHost.textContent=text;
            webSettingsHost.style.display='';
          };
          window.__rayHideWebSettings = () => {
            closeWebSettings();
            if (webSettingsHost) webSettingsHost.style.display='none';
          };
          window.__rayRefreshWebSettings = ensureWebPlaybackSettings;
          document.addEventListener('click',event => {
            if (!webSettingsHost?.contains(event.target) && !webSettingsPanel?.contains(event.target))
              closeWebSettings();
          },true);
          window.addEventListener('scroll',closeWebSettings,true);
          window.addEventListener('resize',closeWebSettings);
          window.__rayWebSettingsProbe = () => ({
            visible:!!webSettingsHost?.isConnected && webSettingsHost.style.display !== 'none',
            panel:!!webSettingsPanel, tracks:readWebPlaybackSettings()?.captions.tracks.length ?? -1,
            rate:readWebPlaybackSettings()?.playbackRate ?? 0
          });

          const refresh = () => {
            ensurePhoneLayoutFix();
            ensureChannelLayoutFix();
            updateChannelPageClass();
            forceAllInline();
            ensurePiPButton();
            ensureAudioButton();
            ensureFullscreenOverride();
            ensureWebPlaybackSettings();
          };

          const scheduleRefresh = () => {
            if (refreshPending) return;
            refreshPending = true;
            setTimeout(() => {
              refreshPending = false;
              refresh();
            }, 120);
          };

          const start = () => {
            refresh();
            scanForSkippableAd();

            new MutationObserver((mutations) => {
              for (const mutation of mutations) {
                for (const node of mutation.addedNodes) forceInlineInNode(node);
              }
              scheduleRefresh();
              scanForSkippableAd();
            }).observe(document.documentElement, {childList:true, subtree:true});

            setInterval(scanForSkippableAd, 350);
            setInterval(scanPlayerSources, 2000);
            document.addEventListener('yt-navigate-start', () => {
              closeWebSettings();
              if (webSettingsHost) webSettingsHost.style.display='none';
              webCaptionOffVideoID = '';
              setWebCaptionOverlayHidden(document.querySelector('.html5-video-player'), false);
              post({kind:'nativeNavigation'});
              sourceVideoID = '';
              captionCuesCache.clear();
              seenSources.clear();
              lastSourceInventory = '';
              window.__rayNativePiPOwner = '';
              window.__rayNativePiPVideo = null;
              window.__rayNativePiPMetadata = null;
              window.__rayResetPiPButton();
            }, true);

            document.addEventListener('yt-navigate-finish', () => {
              scheduleRefresh();
              reportMediaState('navigation');
            }, true);
            document.addEventListener('click', event => {
              const button = event.target instanceof Element ? event.target.closest('.ytp-subtitles-button') : null;
              if (!event.isTrusted || !button) return;
              webCaptionOffVideoID = '';
              setTimeout(() => syncWebCaptionOverlay(button.closest('.html5-video-player'),
                new URL(location.href).searchParams.get('v') || ''), 0);
            }, true);
            for (const type of ['play', 'playing', 'pause', 'ended', 'waiting', 'error',
                                'volumechange', 'ratechange', 'enterpictureinpicture', 'leavepictureinpicture']) {
              document.addEventListener(type, (event) => {
                if (!(event.target instanceof HTMLVideoElement)) return;
                if ((type === 'play' || type === 'playing') &&
                    window.__rayNativePiPOwner && window.__rayNativePiPVideo === event.target) {
                  event.target.pause();
                }
                reportMediaState(type);
                ensureWebPlaybackSettings();
              }, true);
            }
            document.addEventListener('visibilitychange', () => reportMediaState('visibility'), true);
            let lastProgressLogAt = 0;
            document.addEventListener('timeupdate', (event) => {
              if (!(event.target instanceof HTMLVideoElement)) return;
              const currentID = new URL(location.href).searchParams.get('v') || '';
              const player = document.querySelector('.html5-video-player');
              if (currentID && !window.__rayNativePiPOwner &&
                  player?.querySelector('video') === event.target)
                syncWebCaptionOverlay(player, currentID);
              const now = Date.now();
              const interval = event.target.webkitPresentationMode === 'picture-in-picture' ? 15000 : 5000;
              if (now - lastProgressLogAt < interval) return;
              lastProgressLogAt = now;
              reportMediaState('progress');
            }, true);
            document.addEventListener('yt-page-data-updated', scheduleRefresh, true);
            window.addEventListener('popstate', scheduleRefresh, true);
            document.addEventListener('play', (event) => forceInline(event.target), true);
            document.addEventListener('loadedmetadata', (event) => forceInline(event.target), true);
            document.addEventListener('webkitpresentationmodechanged', (event) => {
              const video = event.target;
              if (video instanceof HTMLVideoElement) {
                post({kind:'presentationMode', mode:String(video.webkitPresentationMode || '')});
                reportMediaState('presentation');
              }
            }, true);
          };

          document.documentElement ? start() : document.addEventListener('DOMContentLoaded', start, {once:true});
        })();
        """#

        config.userContentController.addUserScript(
            WKUserScript(source: pageTweaks, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
        nativePlayback.webView = webView
        nativeAudioProbe.onCompatible = { [weak self] id, webpageSource, audioKey, asset, player in
            self?.nativePlayback.prepare(videoID: id, webpageSourceURL: webpageSource, audioKey: audioKey, asset: asset, verifiedPlayer: player)
        }
        nativePlayback.onError = { [weak self] message in
            guard let self, UIApplication.shared.applicationState == .active,
                  self.presentedViewController == nil else { return }
            let alert = UIAlertController(title: "播放", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            self.present(alert, animated: true)
        }
        nativePlayback.onReady = { [weak self] id in
            guard let self else { return }
            self.nativePlayback.primeAudioPosition(self.lastMediaState)
            #if DEBUG
            if ProcessInfo.processInfo.environment["YOUTUBE_PLAYBACK_SETTINGS_SMOKE"] == "1",
               !self.didRunNativeSmokeTest, self.lastMediaState["videoID"] as? String == id {
                self.didRunNativeSmokeTest = true
                let script = #"""
                (() => {
                  const video = document.querySelector('.html5-video-player video');
                  if (!video) return false;
                  try { document.getElementById('movie_player')?.setPlaybackRate?.(1.5); } catch (_) {}
                  video.playbackRate = 1.5;
                  return true;
                })()
                """#
                self.webView.evaluateJavaScript(script) { [weak self] _, _ in
                    guard let self else { return }
                    // Let the webpage's rate change settle before testing the handoff.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, UIApplication.shared.applicationState == .active,
                              self.lastMediaState["videoID"] as? String == id else { return }
                        self.nativePlayback.requestAutomatic(self.lastMediaState, foreground: true)
                    }
                }
                return
            }
            guard !self.didRunNativeSmokeTest,
                  (ProcessInfo.processInfo.environment["YOUTUBE_NATIVE_PIP_SMOKE"] == "1" ||
                   ProcessInfo.processInfo.environment["YOUTUBE_NATIVE_AUDIO_SMOKE"] == "1" ||
                   ProcessInfo.processInfo.environment["YOUTUBE_AUTOMATIC_HANDOFF_SMOKE"] == "1"),
                  self.lastMediaState["videoID"] as? String == id,
                  !self.nativePlayback.ownsPlayback else { return }
            self.didRunNativeSmokeTest = true
            var request = self.lastMediaState
            if ProcessInfo.processInfo.environment["YOUTUBE_NATIVE_AUDIO_SMOKE"] == "1" {
                request["playbackMode"] = "audio"
            }
            if ProcessInfo.processInfo.environment["YOUTUBE_AUTOMATIC_HANDOFF_SMOKE"] == "1" {
                // Exercises the same request/snapshot; not evidence of real lock timing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    self.nativePlayback.requestAutomatic(self.lastMediaState)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, UIApplication.shared.applicationState == .active else { return }
                    PlaybackAudioSession.shared.log("AUTO_HANDOFF debug foreground return check")
                    self.nativePlayback.applicationBecameActive()
                }
            } else {
                self.nativePlayback.request(request)
            }
            #endif
        }
        scriptBridge.onAdSkipRequest = { [weak self] text in
            self?.requestNativeAdSkipClick(matching: text)
        }
        scriptBridge.onDiagnostic = { [weak self] body in
            guard
                let self,
                let dictionary = body as? [String: Any],
                let kind = dictionary["kind"] as? String
            else { return }
            if kind.hasPrefix("adSkip") {
                self.appendAdSkipLog("JS \(dictionary)")
            } else if kind == "nativeSource" {
                self.nativeAudioProbe.receive(dictionary)
            } else if kind == "nativeSourceInventory" {
                PlaybackAudioSession.shared.log("NATIVE_SOURCE inventory \(dictionary)")
            } else if kind == "nativePiPRequest" || kind == "nativeAudioRequest" {
                var request = self.lastMediaState
                request.merge(dictionary) { _, new in new }
                self.nativePlayback.request(request)
            } else if kind == "nativeAudioTrackRequest" {
                guard let id = dictionary["videoID"] as? String,
                      let key = dictionary["audioKey"] as? String,
                      let audioID = dictionary["audioID"] as? String,
                      let xtags = dictionary["audioXtags"] as? String,
                      self.lastMediaState["videoID"] as? String == id,
                      (self.lastMediaState["audioTrack"] as? [String: Any])?["key"] as? String == key,
                      !self.nativePlayback.ownsPlayback else { return }
                guard self.nativeAudioProbe.selectAudio(videoID: id, webpageAudioKey: key,
                                                        audioID: audioID, xtags: xtags) else {
                    self.nativePlayback.onError?("音轨来源尚未准备好，请播放片刻后重试。")
                    return
                }
                var request = self.lastMediaState
                request.merge(dictionary) { _, new in new }
                self.nativePlayback.requestSelectedAudio(request)
            } else if kind == "nativeNavigation" {
                self.lastMediaState = [:]
                self.nativePlayback.navigationWillChange()
                self.nativeAudioProbe.update([:])
            } else if kind == "pipError", let message = dictionary["message"] as? String {
                self.nativePlayback.onError?(message)
            } else if kind == "nativeRestoreFailed" {
                PlaybackAudioSession.shared.log("native PiP returned, webpage play failed")
            } else if kind == "mediaState" {
                self.handleMediaState(dictionary)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        let container = UIView(frame: UIScreen.main.bounds)
        container.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor)
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.navigationDelegate = self
        let selector = NSSelectorFromString("_simulateClickOverFirstMatchingTextInViewportWithUserInteraction:completionHandler:")
        PlaybackAudioSession.shared.log("native HLS PiP enabled; inline playback remains WebKit")
        let available = webView.responds(to: selector)
        print("[YouTubeDesktop][AdSkip] private click SPI available=\(available)")
        appendAdSkipLog("SPI available=\(available)")
        var initialURL = URL(string: "https://www.youtube.com/")!
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["YOUTUBE_SOURCE_PROBE_VIDEO"],
           id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            initialURL = URL(string: "https://www.youtube.com/watch?v=\(id)")!
            PlaybackAudioSession.shared.log("NATIVE_SOURCE foreground diagnostic launch")
        }
        #endif
        webView.load(URLRequest(url: initialURL))
    }

    func applicationBecameActive() {
        nativePlayback.applicationBecameActive()
        nativeAudioProbe.update(lastMediaState)
    }

    private func handleMediaState(_ state: [String: Any]) {
        lastMediaState = state
        nativePlayback.updateAudioState(state)
        nativeAudioProbe.update(state)
        nativePlayback.primeAudioPosition(state)
        if !nativePlayback.ownsPlayback {
            PlaybackAudioSession.shared.update(playing: !(state["paused"] as? Bool ?? true),
                                               pip: state["pip"] as? Bool ?? false)
        }
        PlaybackAudioSession.shared.log("JS \(state)")
        #if DEBUG
        probeCaptionAndAudio(state)
        #endif
    }

    #if DEBUG
    private func probeCaptionAndAudio(_ state: [String: Any]) {
        guard UIApplication.shared.applicationState == .active, !nativePlayback.ownsPlayback,
              let event = state["event"] as? String,
              ["settings", "playing", "navigation", "progress"].contains(event) else { return }
        let now = Date()
        if event != "settings" && now.timeIntervalSince(lastCaptionProbeAt) < 4 { return }
        lastCaptionProbeAt = now
        let script = #"""
        (() => {
          const player = document.getElementById('movie_player');
          const video = player?.querySelector('video');
          const button = player?.querySelector('.ytp-subtitles-button');
          const nodes = [...document.querySelectorAll('[class*="caption"],[class*="subtitle"]')].slice(0,200);
          const visible = node => {
            const style = getComputedStyle(node);
            const rect = node.getBoundingClientRect();
            return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
          };
          const safeClass = node => String(node.className || '').replace(/[^A-Za-z0-9 _-]/g,'').slice(0,80);
          const samples = nodes.filter(visible).slice(-12).map(node => ({cls:safeClass(node),inside:!!player?.contains(node),y:Math.round(node.getBoundingClientRect().y)}));
          const hash = value => { let h=0; for (const c of String(value || '')) h=(Math.imul(h,31)+c.charCodeAt(0))|0; return h.toString(16); };
          const videos = [...document.querySelectorAll('video')].slice(0,8).map(v => ({playing:!v.paused,muted:v.muted,time:Math.round(v.currentTime || 0),source:hash(v.currentSrc)}));
          let internalCC = null, audioID = '';
          try { internalCC = player?.isSubtitlesOn?.() ?? null; audioID = String(player?.getAudioTrack?.()?.id || '').slice(0,40); } catch (_) {}
          return JSON.stringify({videoTime:Math.round(video?.currentTime || 0),button:button?.getAttribute('aria-pressed') ?? 'missing',internalCC,
            playerOff:!!player?.classList.contains('ray-captions-off'),rootOff:document.documentElement.classList.contains('ray-captions-off'),
            style:!!document.getElementById('ray-caption-overlay-style'),nodes:nodes.length,samples,
            textTracks:[...(video?.textTracks || [])].map(t => t.mode).slice(0,8),audioID,videos});
        })()
        """#
        webView.evaluateJavaScript(script) { value, error in
            if let payload = value as? String {
                PlaybackAudioSession.shared.log("CAPTION_AUDIO_PROBE event=\(event) \(payload)")
            } else if error != nil {
                PlaybackAudioSession.shared.log("CAPTION_AUDIO_PROBE event=\(event) unavailable")
            }
        }
    }
    #endif

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        lastMediaState = [:]
        nativeAudioProbe.update([:])
        PlaybackAudioSession.shared.log("WebContent terminated; nativePlaybackActive=\(nativePlayback.ownsPlayback)")
    }

    private func appendAdSkipLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"

        guard let data = line.data(using: .utf8) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("adskip.log")

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            print("[YouTubeDesktop][AdSkip] persistent log error=\(error)")
        }
    }

    private func requestNativeAdSkipClick(matching text: String) {
        let now = Date()
        guard !adSkipClickInFlight else { return }
        guard now.timeIntervalSince(lastAdSkipClickAt) >= 0.8 else { return }

        let selector = NSSelectorFromString("_simulateClickOverFirstMatchingTextInViewportWithUserInteraction:completionHandler:")
        guard webView.responds(to: selector) else {
            print("[YouTubeDesktop][AdSkip] private click SPI unavailable")
            appendAdSkipLog("SPI unavailable text=\(text)")
            return
        }

        adSkipClickInFlight = true
        lastAdSkipClickAt = now

        typealias CompletionBlock = @convention(block) (Bool) -> Void
        typealias PrivateClickIMP = @convention(c) (AnyObject, Selector, NSString, CompletionBlock) -> Void

        let completion: CompletionBlock = { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.adSkipClickInFlight = false
                print("[YouTubeDesktop][AdSkip] private click completed success=\(success) text=\(text)")
                self.appendAdSkipLog("SPI completion success=\(success) text=\(text)")
            }
        }

        guard let implementation = webView.method(for: selector) else {
            adSkipClickInFlight = false
            print("[YouTubeDesktop][AdSkip] method implementation unavailable")
            appendAdSkipLog("method implementation unavailable text=\(text)")
            return
        }

        let function = unsafeBitCast(implementation, to: PrivateClickIMP.self)
        print("[YouTubeDesktop][AdSkip] invoking private click text=\(text)")
        appendAdSkipLog("SPI invoke text=\(text)")
        function(webView, selector, text as NSString, completion)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastMediaState = [:]
        nativePlayback.navigationWillChange()
        nativeAudioProbe.update([:])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["YOUTUBE_WEB_SETTINGS_SMOKE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.webView.evaluateJavaScript(#"""
                (() => {
                  window.__rayRefreshWebSettings?.();
                  const before=window.__rayWebSettingsProbe?.();
                  document.getElementById('ray-web-playback-settings')?.click();
                  const panel=document.getElementById('ray-web-playback-settings-panel');
                  const speed=panel?.querySelector('select[aria-label="播放速度"]');
                  if (speed) { speed.value='1.5';speed.dispatchEvent(new Event('change',{bubbles:true})); }
                  return {before,after:window.__rayWebSettingsProbe?.(),
                    subtitleDisabled:panel?.querySelector('select[aria-label="字幕"]')?.disabled ?? null};
                })()
                """#) { value, error in
                    PlaybackAudioSession.shared.log("WEB_SETTINGS_SMOKE result=\(String(describing: value)) error=\(error != nil)")
                }
            }
        }
        #endif
        webView.evaluateJavaScript("({url:location.href,ua:navigator.userAgent,title:document.title})") { value, error in
            print("[YouTubeDesktop] page=\(String(describing: value)) error=\(String(describing: error))")
        }
    }
}
