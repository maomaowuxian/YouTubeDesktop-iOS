import UIKit
import WebKit

final class ScriptBridge: NSObject, WKScriptMessageHandler {
    var onAdSkipRequest: ((String) -> Void)?
    var onDiagnostic: ((Any) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "diag":
            print("[YouTubeDesktop][JS] \(message.body)")
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
    private var adSkipClickInFlight = false
    private var lastAdSkipClickAt = Date.distantPast

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.userContentController.add(scriptBridge, name: "diag")
        config.userContentController.add(scriptBridge, name: "adSkip")

        let pageTweaks = #"""
        (() => {
          if (window.__rayYouTubeDesktopInstalled) return;
          window.__rayYouTubeDesktopInstalled = true;

          const post = (body) => {
            try { window.webkit?.messageHandlers?.diag?.postMessage(body); } catch (_) {}
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
            ensureChannelLayoutFix();
            updateChannelPageClass();
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
            scanForSkippableAd();

            new MutationObserver((mutations) => {
              for (const mutation of mutations) {
                for (const node of mutation.addedNodes) forceInlineInNode(node);
              }
              scheduleRefresh();
              scanForSkippableAd();
            }).observe(document.documentElement, {childList:true, subtree:true});

            setInterval(scanForSkippableAd, 350);

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
        scriptBridge.onAdSkipRequest = { [weak self] text in
            self?.requestNativeAdSkipClick(matching: text)
        }
        scriptBridge.onDiagnostic = { [weak self] body in
            guard
                let self,
                let dictionary = body as? [String: Any],
                let kind = dictionary["kind"] as? String,
                kind.hasPrefix("adSkip")
            else { return }
            self.appendAdSkipLog("JS \(dictionary)")
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
        let available = webView.responds(to: selector)
        print("[YouTubeDesktop][AdSkip] private click SPI available=\(available)")
        appendAdSkipLog("SPI available=\(available)")
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("({url:location.href,ua:navigator.userAgent,title:document.title})") { value, error in
            print("[YouTubeDesktop] page=\(String(describing: value)) error=\(String(describing: error))")
        }
    }
}
