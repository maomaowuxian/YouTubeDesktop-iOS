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
              if (sourceVideoID !== videoID) { sourceVideoID = videoID; seenSources.clear(); }
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
                post({kind:'nativeSource', videoID, url:url.toString(), mime:'application/vnd.apple.mpegurl'});
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
              post({kind:'nativeSource', videoID, url:url.toString(), mime});
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
          window.__rayNativePiPOwner = '';
          window.__rayNativePiPVideo = null;
          window.__rayNativePiPMetadata = null;
          window.__rayResetPiPButton = () => {
            const pipButton = document.querySelector('.ray-pip-button');
            if (pipButton) { pipButton.disabled = false; pipButton.title = '画中画 / 后台播放'; }
            const audioButton = document.querySelector('.ray-audio-button');
            if (audioButton) { audioButton.disabled = false; audioButton.title = '后台音频'; }
          };
          window.__rayPauseForNativePiP = (videoID, automaticSource = '') => {
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
            const wasPlaying = !video.paused;
            window.__rayNativePiPOwner = videoID;
            window.__rayNativePiPVideo = video;
            window.__rayNativePiPMetadata = navigator.mediaSession?.metadata || null;
            video.pause();
            try {
              navigator.mediaSession.playbackState = 'none';
              navigator.mediaSession.metadata = null;
            } catch (_) {}
            return {videoID, currentTime:video.currentTime, wasPlaying, paused:video.paused};
          };
          window.__rayRestoreAfterNativePiP = (videoID, time, play) => {
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
            try { navigator.mediaSession.metadata = metadata; } catch (_) {}
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
              videoID:new URL(location.href).searchParams.get('v') || '',
              ad:!!document.querySelector('.html5-video-player')?.classList.contains('ad-showing'),
              transport,
              sourceKind:video?.currentSrc?.startsWith('blob:') ? 'MSE' :
                (video?.currentSrc?.startsWith('https:') ? 'URL' : 'none'),
              sourceDuration:Number(sourceResponse?.videoDetails?.lengthSeconds) || 0,
              paused:video ? !!video.paused : true,
              ended:video ? !!video.ended : false,
              currentTime:video ? video.currentTime : 0,
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
            button.setAttribute('aria-label', '后台音频');
            button.setAttribute('title', '后台音频');
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
          const refresh = () => {
            ensurePhoneLayoutFix();
            ensureChannelLayoutFix();
            updateChannelPageClass();
            forceAllInline();
            ensurePiPButton();
            ensureAudioButton();
            ensureFullscreenOverride();
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
              post({kind:'nativeNavigation'});
              sourceVideoID = '';
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
            for (const type of ['play', 'playing', 'pause', 'ended', 'waiting', 'error',
                                'volumechange', 'enterpictureinpicture', 'leavepictureinpicture']) {
              document.addEventListener(type, (event) => {
                if (!(event.target instanceof HTMLVideoElement)) return;
                if ((type === 'play' || type === 'playing') &&
                    window.__rayNativePiPOwner && window.__rayNativePiPVideo === event.target) {
                  event.target.pause();
                }
                reportMediaState(type);
              }, true);
            }
            document.addEventListener('visibilitychange', () => reportMediaState('visibility'), true);
            let lastProgressLogAt = 0;
            document.addEventListener('timeupdate', (event) => {
              if (!(event.target instanceof HTMLVideoElement)) return;
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
        nativeAudioProbe.onCompatible = { [weak self] id, asset, player in
            self?.nativePlayback.prepare(videoID: id, asset: asset, verifiedPlayer: player)
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
            self.maybeAutomaticallyTakeOver()
            #if DEBUG
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

    private func maybeAutomaticallyTakeOver() {
        guard UIApplication.shared.applicationState == .active,
              presentedViewController == nil, !nativePlayback.ownsPlayback else { return }
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if ["YOUTUBE_NATIVE_PIP_SMOKE", "YOUTUBE_NATIVE_AUDIO_SMOKE",
            "YOUTUBE_AUTOMATIC_HANDOFF_SMOKE", "YOUTUBE_WEB_ONLY_DIAGNOSTIC"].contains(where: { env[$0] == "1" }) {
            return
        }
        #endif
        // Complete the audible handoff while foreground. Locking only detaches
        // the video surface; it no longer depends on a late WebKit snapshot.
        nativePlayback.requestAutomatic(lastMediaState, foreground: true)
    }

    func applicationWillResignActive() {
        nativePlayback.requestAutomatic(lastMediaState)
    }

    func applicationBecameActive() {
        nativePlayback.applicationBecameActive()
        nativeAudioProbe.update(lastMediaState)
        maybeAutomaticallyTakeOver()
    }

    private func handleMediaState(_ state: [String: Any]) {
        lastMediaState = state
        nativeAudioProbe.update(state)
        nativePlayback.primeAudioPosition(state)
        maybeAutomaticallyTakeOver()
        if !nativePlayback.ownsPlayback {
            PlaybackAudioSession.shared.update(playing: !(state["paused"] as? Bool ?? true),
                                               pip: state["pip"] as? Bool ?? false)
        }
        PlaybackAudioSession.shared.log("JS \(state)")
    }

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
        webView.evaluateJavaScript("({url:location.href,ua:navigator.userAgent,title:document.title})") { value, error in
            print("[YouTubeDesktop] page=\(String(describing: value)) error=\(String(describing: error))")
        }
    }
}
