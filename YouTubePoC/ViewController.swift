import UIKit
import WebKit

final class ScriptBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "diag" else { return }
        print("[YouTubeDesktop][JS] \(message.body)")
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

        let pageTweaks = #"""
        (() => {
          if (window.__rayYouTubeDesktopInstalled) return;
          window.__rayYouTubeDesktopInstalled = true;

          const post = (body) => {
            try { window.webkit?.messageHandlers?.diag?.postMessage(body); } catch (_) {}
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
              let method = 'none';
              try {
                if (typeof video.webkitSupportsPresentationMode === 'function' &&
                    typeof video.webkitSetPresentationMode === 'function' &&
                    video.webkitSupportsPresentationMode('picture-in-picture')) {
                  method = 'webkitSetPresentationMode';
                  video.webkitSetPresentationMode('picture-in-picture');
                } else if (document.pictureInPictureEnabled && typeof video.requestPictureInPicture === 'function') {
                  method = 'requestPictureInPicture';
                  video.requestPictureInPicture()?.catch?.((error) => {
                    post({kind:'pipError', method, error:String(error)});
                  });
                }
                post({kind:'pipRequest', ok:method !== 'none', method});
              } catch (error) {
                post({kind:'pipError', method, error:String(error)});
              }
            }, true);

            if (fullscreen && fullscreen.parentElement === controls) {
              controls.insertBefore(button, fullscreen);
            } else {
              controls.appendChild(button);
            }
          };

          let refreshPending = false;
          const refresh = () => {
            ensurePhoneLayoutFix();
            forceAllInline();
            ensurePiPButton();
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

            new MutationObserver((mutations) => {
              for (const mutation of mutations) {
                for (const node of mutation.addedNodes) forceInlineInNode(node);
              }
              scheduleRefresh();
            }).observe(document.documentElement, {childList:true, subtree:true});

            document.addEventListener('yt-navigate-finish', scheduleRefresh, true);
            document.addEventListener('yt-page-data-updated', scheduleRefresh, true);
            window.addEventListener('popstate', scheduleRefresh, true);
            document.addEventListener('play', (event) => forceInline(event.target), true);
            document.addEventListener('loadedmetadata', (event) => forceInline(event.target), true);
            document.addEventListener('webkitpresentationmodechanged', (event) => {
              const video = event.target;
              if (video instanceof HTMLVideoElement) {
                post({kind:'presentationMode', mode:String(video.webkitPresentationMode || '')});
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
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("({url:location.href,ua:navigator.userAgent,title:document.title})") { value, error in
            print("[YouTubeDesktop] page=\(String(describing: value)) error=\(String(describing: error))")
        }
    }
}
