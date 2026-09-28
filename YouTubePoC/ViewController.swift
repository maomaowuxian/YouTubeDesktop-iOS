import UIKit
import WebKit
import MediaPlayer

final class ScriptBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "diag" else { return }
        print("[PoC][JS] \(message.body)")
    }
}

final class ViewController: UIViewController, WKNavigationDelegate {
    private let scriptBridge = ScriptBridge()
    private let webView: WKWebView

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.userContentController.add(scriptBridge, name: "diag")

        let autoSkip = #"""
        (() => {
          if (window.__ytAutoSkipInstalled) return;
          window.__ytAutoSkipInstalled = true;

          const stripPlayerAds = (value) => {
            if (!value || typeof value !== 'object') return value;
            try {
              delete value.adPlacements;
              delete value.playerAds;
              delete value.adSlots;
              delete value.adBreakHeartbeatParams;
            } catch (_) {}
            return value;
          };

          try {
            let initialPlayerResponse;
            Object.defineProperty(window, 'ytInitialPlayerResponse', {
              configurable: true,
              enumerable: true,
              get() { return initialPlayerResponse; },
              set(value) { initialPlayerResponse = stripPlayerAds(value); }
            });
          } catch (_) {}

          try {
            const nativeFetch = window.fetch;
            if (typeof nativeFetch === 'function') {
              window.fetch = async function(...args) {
                const response = await nativeFetch.apply(this, args);
                try {
                  const requestURL = typeof args[0] === 'string'
                    ? args[0]
                    : String(args[0]?.url || response.url || '');
                  if (!requestURL.includes('/youtubei/v1/player')) return response;

                  const text = await response.clone().text();
                  const data = stripPlayerAds(JSON.parse(text));
                  const headers = new Headers(response.headers);
                  headers.delete('content-length');

                  window.webkit?.messageHandlers?.diag?.postMessage({
                    kind:'playerResponseFiltered',
                    url:requestURL.slice(0,220)
                  });

                  return new Response(JSON.stringify(data), {
                    status: response.status,
                    statusText: response.statusText,
                    headers
                  });
                } catch (_) {
                  return response;
                }
              };
            }
          } catch (_) {}

          const __rayClickListeners = new WeakMap();
          const __rayAddEventListener = EventTarget.prototype.addEventListener;
          EventTarget.prototype.addEventListener = function(type, listener, options) {
            if (type === 'click' && listener) {
              try {
                let list = __rayClickListeners.get(this);
                if (!list) {
                  list = [];
                  __rayClickListeners.set(this, list);
                }
                list.push({listener, options});
              } catch (_) {}
            }
            return __rayAddEventListener.call(this, type, listener, options);
          };

          let clickHandlerReported = false;
          const reportSkipClickHandlers = (button) => {
            if (clickHandlerReported || !button) return;
            const chain = [];
            let node = button;
            for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
              const listeners = __rayClickListeners.get(node) || [];
              if (!listeners.length) continue;
              chain.push({
                depth,
                tag:node.tagName || '',
                id:node.id || '',
                cls:String(node.className || '').slice(0,160),
                listeners:listeners.slice(0,16).map((entry) => {
                  let source = '';
                  try {
                    source = typeof entry.listener === 'function'
                      ? Function.prototype.toString.call(entry.listener)
                      : String(entry.listener?.handleEvent || entry.listener);
                  } catch (_) {}
                  return source.replace(/\s+/g,' ').slice(0,700);
                })
              });
            }

            const protoDescriptor = (() => {
              try {
                const d = Object.getOwnPropertyDescriptor(Event.prototype, 'isTrusted');
                return d ? {configurable:!!d.configurable, enumerable:!!d.enumerable, hasGetter:typeof d.get === 'function'} : null;
              } catch (_) { return null; }
            })();

            let syntheticTrusted = null;
            let overrideError = '';
            try {
              const e = new MouseEvent('click', {bubbles:true, cancelable:true});
              const before = e.isTrusted;
              try { Object.defineProperty(e, 'isTrusted', {value:true}); } catch (err) { overrideError = String(err); }
              syntheticTrusted = {before, after:e.isTrusted};
            } catch (err) { overrideError = String(err); }

            clickHandlerReported = true;
            window.webkit?.messageHandlers?.diag?.postMessage({
              kind:'skipClickHandlers',
              chain,
              protoDescriptor,
              syntheticTrusted,
              overrideError
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
              ytd-guide-renderer,
              tp-yt-app-drawer#guide,
              #guide,
              #guide-content,
              #guide-inner-content,
              #guide-spacer,
              #mini-guide-background {
                display: none !important;
                width: 0 !important;
                min-width: 0 !important;
                max-width: 0 !important;
                margin: 0 !important;
                padding: 0 !important;
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
                window.webkit?.messageHandlers?.diag?.postMessage({kind:'fullscreenRequest', ok:false, reason:'no-video'});
                return;
              }

              let supported = false;
              try {
                supported = typeof video.webkitSupportsPresentationMode === 'function' &&
                  typeof video.webkitSetPresentationMode === 'function' &&
                  !!video.webkitSupportsPresentationMode('fullscreen');
                if (supported) {
                  video.webkitSetPresentationMode('fullscreen');
                }
                window.webkit?.messageHandlers?.diag?.postMessage({
                  kind:'fullscreenRequest',
                  ok:supported,
                  before:String(video.webkitPresentationMode || '')
                });
              } catch (error) {
                window.webkit?.messageHandlers?.diag?.postMessage({kind:'fullscreenError', error:String(error)});
              }

              setTimeout(() => {
                window.webkit?.messageHandlers?.diag?.postMessage({
                  kind:'fullscreenResult',
                  mode:String(video.webkitPresentationMode || '')
                });
              }, 500);
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
            button.setAttribute('aria-label', '画中画');
            button.setAttribute('title', '画中画');
            button.style.width = '48px';
            button.style.padding = '0 8px';
            button.innerHTML = '<svg viewBox="0 0 36 36" width="100%" height="100%" aria-hidden="true"><path fill="currentColor" d="M6 8h24v20H6V8zm2.5 2.5v15h19v-15h-19zM18 17h7v6h-7v-6z"></path></svg>';

            button.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopPropagation();

              const video = player.querySelector('video') || document.querySelector('video');
              if (!(video instanceof HTMLVideoElement)) {
                window.webkit?.messageHandlers?.diag?.postMessage({kind:'pipRequest', ok:false, reason:'no-video'});
                return;
              }

              forceInline(video);
              const before = String(video.webkitPresentationMode || '');
              let method = 'none';

              try {
                if (typeof video.webkitSupportsPresentationMode === 'function' &&
                    typeof video.webkitSetPresentationMode === 'function' &&
                    video.webkitSupportsPresentationMode('picture-in-picture')) {
                  method = 'webkitSetPresentationMode';
                  video.webkitSetPresentationMode('picture-in-picture');
                } else if (document.pictureInPictureEnabled && typeof video.requestPictureInPicture === 'function') {
                  method = 'requestPictureInPicture';
                  const result = video.requestPictureInPicture();
                  if (result && typeof result.catch === 'function') {
                    result.catch((error) => {
                      window.webkit?.messageHandlers?.diag?.postMessage({kind:'pipError', method, error:String(error)});
                    });
                  }
                }

                window.webkit?.messageHandlers?.diag?.postMessage({
                  kind:'pipRequest',
                  ok:method !== 'none',
                  method,
                  before,
                  supportsWebKit:typeof video.webkitSupportsPresentationMode === 'function' ? !!video.webkitSupportsPresentationMode('picture-in-picture') : null,
                  documentPiP:!!document.pictureInPictureEnabled
                });

                setTimeout(() => {
                  window.webkit?.messageHandlers?.diag?.postMessage({
                    kind:'pipResult',
                    method,
                    mode:String(video.webkitPresentationMode || ''),
                    standardActive:document.pictureInPictureElement === video
                  });
                }, 500);
              } catch (error) {
                window.webkit?.messageHandlers?.diag?.postMessage({kind:'pipError', method, error:String(error)});
              }
            }, true);

            if (fullscreen && fullscreen.parentElement === controls) {
              controls.insertBefore(button, fullscreen);
            } else {
              controls.appendChild(button);
            }
          };

          let lastDiagSignature = '';
          let lastDiagAt = 0;

          const reportAdControls = () => {
            const player = document.querySelector('.html5-video-player');
            if (!player) return;

            const adActive = player.classList.contains('ad-showing') ||
              !!player.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
            if (!adActive) return;

            const now = Date.now();
            if (now - lastDiagAt < 900) return;

            const nodes = [...player.querySelectorAll('button, [role="button"], [class*="skip"], [aria-label*="Skip" i], [aria-label*="跳"]')]
              .filter((el) => {
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0;
              })
              .slice(0, 24)
              .map((el) => ({
                tag: el.tagName,
                id: el.id || '',
                cls: String(el.className || '').slice(0, 180),
                text: String(el.innerText || '').trim().replace(/\s+/g, ' ').slice(0, 120),
                aria: String(el.getAttribute('aria-label') || '').slice(0, 120),
                title: String(el.getAttribute('title') || '').slice(0, 120),
                disabled: !!el.disabled
              }));

            const signature = JSON.stringify(nodes);
            if (!nodes.length || signature === lastDiagSignature) return;
            lastDiagSignature = signature;
            lastDiagAt = now;
            window.webkit?.messageHandlers?.diag?.postMessage({kind:'adControls', nodes});
          };

          let playerApiReported = false;
          let adPlayerApiReported = false;
          let lastInternalSkipAt = 0;

          const trySeekSkip = (player) => {
            const video = player.querySelector('video') || document.querySelector('video');
            if (!(video instanceof HTMLVideoElement)) return false;

            const duration = Number(video.duration);
            const currentTime = Number(video.currentTime);
            if (!Number.isFinite(duration) || duration <= 0 || !Number.isFinite(currentTime)) {
              window.webkit?.messageHandlers?.diag?.postMessage({
                kind:'seekSkipAttempt',
                ok:false,
                reason:'invalid-duration',
                duration:String(video.duration),
                currentTime:String(video.currentTime)
              });
              return false;
            }

            const target = Math.max(0, duration - 0.05);
            let error = '';
            try {
              video.currentTime = target;
            } catch (e) {
              error = String(e);
            }

            window.webkit?.messageHandlers?.diag?.postMessage({
              kind:'seekSkipAttempt',
              ok:!error,
              duration,
              before:currentTime,
              target,
              after:Number(video.currentTime),
              error
            });

            setTimeout(() => {
              const p = document.getElementById('movie_player') || player;
              const stillAd = !!p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'));
              const stillSkip = !!p?.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-slot button');
              window.webkit?.messageHandlers?.diag?.postMessage({
                kind:'seekSkipResult',
                adShowing:stillAd,
                skipStillVisible:stillSkip,
                currentTime:Number(video.currentTime),
                duration:Number(video.duration)
              });
            }, 700);

            return !error;
          };

          const scanPlayerAPI = (player, phase) => {
            const levels = [];
            let object = player;
            for (let depth = 0; object && depth < 8; depth++, object = Object.getPrototypeOf(object)) {
              let names = [];
              try { names = Object.getOwnPropertyNames(object); } catch (_) {}
              const matches = [];
              for (const name of names) {
                if (!/(skip|ad)/i.test(name)) continue;
                let type = 'unknown';
                try {
                  const descriptor = Object.getOwnPropertyDescriptor(object, name);
                  if (descriptor && 'value' in descriptor) type = typeof descriptor.value;
                  else if (descriptor?.get) type = 'getter';
                } catch (_) {}
                matches.push({name, type});
              }
              if (matches.length) levels.push({depth, matches:matches.slice(0, 120)});
            }

            let direct = [];
            for (const name of ['skipAd','getAdState','isAdShowing','getPlayerState','getVideoData']) {
              try { direct.push({name, type:typeof player[name]}); } catch (_) { direct.push({name, type:'error'}); }
            }

            const sources = [];
            for (const name of ['getAdState','onAdUxClicked','isLifaAdPlaying','logImaAdEvent']) {
              try {
                const fn = player[name];
                if (typeof fn === 'function') {
                  sources.push({
                    name,
                    source:String(Function.prototype.toString.call(fn)).replace(/\s+/g, ' ').slice(0, 900)
                  });
                }
              } catch (e) {
                sources.push({name, source:'<error ' + String(e) + '>'});
              }
            }

            let adState = null;
            try { if (typeof player.getAdState === 'function') adState = player.getAdState(); } catch (_) {}

            let apiInterfaceMatches = [];
            try {
              if (typeof player.getApiInterface === 'function') {
                const api = player.getApiInterface();
                if (Array.isArray(api)) {
                  apiInterfaceMatches = api.filter((name) => /(skip|ad)/i.test(String(name))).slice(0, 120);
                }
              }
            } catch (_) {}

            const nested = [];
            let inspected = 0;
            let rootNames = [];
            try { rootNames = Object.getOwnPropertyNames(player); } catch (_) {}
            for (const rootName of rootNames) {
              if (inspected >= 160 || nested.length >= 180) break;
              let value;
              try {
                const descriptor = Object.getOwnPropertyDescriptor(player, rootName);
                if (!descriptor || !('value' in descriptor)) continue;
                value = descriptor.value;
              } catch (_) { continue; }
              if (!value || (typeof value !== 'object' && typeof value !== 'function')) continue;
              if (value === window || value === document || value instanceof Element) continue;
              inspected++;
              let childNames = [];
              try { childNames = Object.getOwnPropertyNames(value); } catch (_) { continue; }
              for (const childName of childNames) {
                if (!/(skip|ad)/i.test(childName)) continue;
                let type = 'unknown';
                try {
                  const d = Object.getOwnPropertyDescriptor(value, childName);
                  if (d && 'value' in d) type = typeof d.value;
                  else if (d?.get) type = 'getter';
                } catch (_) {}
                nested.push({path:rootName + '.' + childName, type});
                if (nested.length >= 180) break;
              }
            }

            window.webkit?.messageHandlers?.diag?.postMessage({kind:'playerAPI', phase, levels, direct, sources, adState, apiInterfaceMatches, nested});
          };

          const maybeReportPlayerAPI = (player, adPhase = false) => {
            if (!player) return;
            if (!playerApiReported) {
              playerApiReported = true;
              scanPlayerAPI(player, 'initial');
            }
            if (adPhase && !adPlayerApiReported) {
              adPlayerApiReported = true;
              scanPlayerAPI(player, 'ad-skip-visible');
            }
          };

          const tryInternalSkip = (player) => {
            const skipButton = player.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-slot button');
            const adShowing = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
            if (!adShowing || !skipButton) return false;

            const rect = skipButton.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) return false;

            maybeReportPlayerAPI(player, true);
            reportSkipClickHandlers(skipButton);

            const now = Date.now();
            if (now - lastInternalSkipAt < 1500) return false;
            lastInternalSkipAt = now;

            let method = '';
            let error = '';
            try {
              if (typeof player.skipAd === 'function') {
                method = 'player.skipAd';
                player.skipAd();
              }
            } catch (e) {
              error = String(e);
            }

            if (!method && !error) {
              const seekStarted = trySeekSkip(player);
              if (seekStarted) method = 'video.currentTime';
            }

            window.webkit?.messageHandlers?.diag?.postMessage({
              kind:'internalSkipAttempt',
              method:method || 'none',
              error,
              adShowingBefore:adShowing,
              skipVisibleBefore:true
            });

            setTimeout(() => {
              const p = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
              const stillAd = !!p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'));
              const stillSkip = !!p?.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-slot button');
              window.webkit?.messageHandlers?.diag?.postMessage({
                kind:'internalSkipResult',
                method:method || 'none',
                adShowing:stillAd,
                skipStillVisible:stillSkip
              });
            }, 600);

            return method !== '';
          };

          const trySkip = () => {
            const player = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
            if (!player) return false;

            maybeReportPlayerAPI(player, false);
            reportAdControls();
            return tryInternalSkip(player);
          };

          const start = () => {
            ensurePhoneLayoutFix();
            forceAllInline();
            trySkip();
            ensurePiPButton();
            ensureFullscreenOverride();

            let scanPending = false;
            const scheduleScan = () => {
              if (scanPending) return;
              scanPending = true;
              setTimeout(() => {
                scanPending = false;
                trySkip();
                reportAdControls();
                ensurePiPButton();
                ensureFullscreenOverride();
              }, 120);
            };

            new MutationObserver((mutations) => {
              for (const mutation of mutations) {
                for (const node of mutation.addedNodes) forceInlineInNode(node);
              }
              scheduleScan();
            }).observe(document.documentElement, {
              childList: true,
              subtree: true
            });

            document.addEventListener('play', (event) => {
              forceInline(event.target);
              const v = event.target;
              if (v instanceof HTMLVideoElement) {
                window.webkit?.messageHandlers?.diag?.postMessage({
                  kind:'videoCaps',
                  webkitPresentationMode:String(v.webkitPresentationMode || ''),
                  supportsPiP:typeof v.webkitSupportsPresentationMode === 'function' ? !!v.webkitSupportsPresentationMode('picture-in-picture') : null,
                  documentPiP:!!document.pictureInPictureEnabled
                });
              }
            }, true);
            document.addEventListener('loadedmetadata', (event) => forceInline(event.target), true);
            document.addEventListener('webkitpresentationmodechanged', (event) => {
              const v = event.target;
              if (v instanceof HTMLVideoElement) {
                window.webkit?.messageHandlers?.diag?.postMessage({
                  kind:'presentationMode',
                  mode:String(v.webkitPresentationMode || '')
                });
              }
            }, true);

            setInterval(() => {
              trySkip();
              reportAdControls();
              ensurePiPButton();
              ensureFullscreenOverride();
            }, 900);
          };

          document.documentElement ? start() : document.addEventListener('DOMContentLoaded', start, {once:true});
        })();
        """#
        config.userContentController.addUserScript(
            WKUserScript(source: autoSkip, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
        setupRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "YouTube iOS PoC"]
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("({url:location.href,ua:navigator.userAgent,title:document.title})") { value, error in
            print("[PoC] page=\(String(describing: value)) error=\(String(describing: error))")
        }
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            print("[PoC] remote play")
            self?.js("(()=>{let v=document.querySelector('video');if(!v)return 'no-video';v.play();return 'play-issued'})()", label: "remote-play")
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            print("[PoC] remote pause")
            self?.js("(()=>{let v=document.querySelector('video');if(!v)return 'no-video';v.pause();return 'pause-issued'})()", label: "remote-pause")
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            print("[PoC] remote toggle")
            self?.js("(()=>{let v=document.querySelector('video');if(!v)return 'no-video';if(v.paused){v.play();return 'play-issued'}else{v.pause();return 'pause-issued'}})()", label: "remote-toggle")
            return .success
        }
    }

    private func js(_ script: String, label: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(script) { value, error in
                if let label {
                    print("[PoC] \(label) result=\(String(describing: value)) error=\(String(describing: error))")
                }
            }
        }
    }
}
