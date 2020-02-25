//
//  ViewController.swift
//  DEV-Simple
//
//  Created by Ben Halpern on 11/1/18.
//  Copyright © 2018 DEV. All rights reserved.
//

import UIKit
import WebKit
import AVFoundation
import UserNotifications
import PushNotifications
import NotificationBanner

struct UserData: Codable {
    enum CodingKeys: String, CodingKey {
        case userID = "id"
        case configBodyClass = "config_body_class"
    }
    var userID: Int
    var configBodyClass: String
}

class ViewController: UIViewController {

    @IBOutlet weak var backButton: UIBarButtonItem!
    @IBOutlet weak var forwardButton: UIBarButtonItem!
    @IBOutlet lazy var webView: WKWebView! = {

        if !UIAccessibility.isInvertColorsEnabled {
            return WKWebView()
        }

        guard let path = Bundle.main.path(forResource: "invertedImages", ofType: "css") else {
            return WKWebView()
        }

        let cssString = try? String(contentsOfFile: path).components(separatedBy: .newlines).joined()
        let source = """
        var style = document.createElement('style');
        style.innerHTML = '\(cssString)';
        document.head.appendChild(style);
        """

        let userScript = WKUserScript(source: source,
                                      injectionTime: .atDocumentEnd,
                                      forMainFrameOnly: true)

        let userContentController = WKUserContentController()
        userContentController.addUserScript(userScript)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero,
                                configuration: configuration)

        webView.accessibilityIgnoresInvertColors = true
        return webView
    }()

    @IBOutlet weak var safariButton: UIBarButtonItem!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var navigationToolBar: UIToolbar!

    var avPlayer: AVPlayer?
    var currentPodcast: AVPlayerItem?
    var currentPodcastURL: String?

    var lightAlpha = CGFloat(0.2)
    var useDarkMode = false
    let darkBackgroundColor = UIColor(red: 13/255, green: 18/255, blue: 25/255, alpha: 1)

    let pushNotifications = PushNotifications.shared
    lazy var errorBanner: NotificationBanner = {
        let banner = NotificationBanner(title: "Network not reachable", style: .danger)
        banner.autoDismiss = false
        banner.dismissOnTap = true
        return banner
    }()

    var devToURL = "https://dev.to"

    override func viewDidLoad() {
        super.viewDidLoad()
        activityIndicator.hidesWhenStopped = true
        backButton.isEnabled = false
        forwardButton.isEnabled = false
        webView.navigationDelegate = self
        webView.customUserAgent = "DEV-Native-ios"
        webView.scrollView.scrollIndicatorInsets.top = view.safeAreaInsets.top + 50
        if let developmentURL = ProcessInfo.processInfo.environment["DEV_URL"] {
            devToURL = developmentURL
        }
        webView.load(devToURL)
        webView.configuration.allowsInlineMediaPlayback = true
        webView.configuration.userContentController.add(self, name: "haptic")
        webView.configuration.userContentController.add(self, name: "podcast")
        webView.allowsBackForwardNavigationGestures = true
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.canGoBack), options: [.new, .old], context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.canGoForward), options: [.new, .old], context: nil)
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.url), options: [.new, .old], context: nil)
        addShellShadow()
        let notificationName = Notification.Name("updateWebView")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateWebView),
            name: notificationName,
            object: nil)

        }

    override func viewWillAppear(_ animated: Bool) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reachabilityChanged),
            name: .flagsChanged,
            object: Network.reachability)
    }

    // MARK: - Reachability
    @objc private func reachabilityChanged(note: Notification) {
        guard let reachability = note.object as? Reachability else {
            return
        }

        switch reachability.status {
        case .wifi:
            if errorBanner.isDisplaying {
                errorBanner.dismiss()
            }
        case .wwan:
            if errorBanner.isDisplaying {
                errorBanner.dismiss()
            }
        default:
            break
        }
    }

    // MARK: - IBActions
    @IBAction func backButtonTapped(_ sender: Any) {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    @IBAction func forwardButtonTapped(_ sender: Any) {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    @IBAction func refreshButtonTapped(_ sender: Any) {
        webView.reload()
    }

    @IBAction func safariButtonTapped(_ sender: Any) {
        openInBrowser()
    }

    // MARK: - Observers
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey:Any]?,
                               context: UnsafeMutableRawPointer?) {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        if let url = webView.url {
             webView.scrollView.isScrollEnabled = !(url.path.hasPrefix("/connect")) //Remove scroll if /connect view
        }
        modifyShellDesign()
    }

    @objc func updateWebView() {
        let appDelegate = UIApplication.shared.delegate as? AppDelegate
        let serverURL = appDelegate?.serverURL
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else {
                return
            }

            // Wait a split second if first launch (Hack, probably a race condition)
            self.webView.load(serverURL ?? "https://dev.to")
        }
    }

    func openURL(_ url: URL) {
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    // MARK: - External Safari call
    func openInBrowser() {
        if let url = webView.url {
            UIApplication.shared.open(url, options: [:])
        }
    }

    // MARK: - Auth
    func isAuthLink(_ url: URL) -> Bool {
        if url.absoluteString.hasPrefix("https://github.com/login") {
            return true
        }
        if url.absoluteString.hasPrefix("https://api.twitter.com/oauth") {
            return true
        }
        return false
    }

    func populateUserData() {
        let javascript = "document.getElementsByTagName('body')[0].getAttribute('data-user')"
        webView.evaluateJavaScript(javascript) { result, error in

            if let error = error {
                print("Error getting user data: \(error)")
                return
            }

            if let jsonString = result as? String {
                do {
                    let user = try JSONDecoder().decode(UserData.self, from: Data(jsonString.utf8))
                    let notificationSubscription = "user-notifications-\(String(user.userID))"
                    try? self.pushNotifications.addDeviceInterest(interest: notificationSubscription)
                    if user.configBodyClass.contains("night-theme") {
                        self.applyDarkTheme()
                    }
                } catch {
                    print("Error info: \(error)")
                }
            }
        }
    }

    private func applyDarkTheme() {
        useDarkMode = true
        setNeedsStatusBarAppearanceUpdate()
        navigationToolBar.isTranslucent = false
        navigationToolBar.barTintColor = darkBackgroundColor
        safariButton.tintColor = UIColor.white
        backButton.tintColor = UIColor.white
        forwardButton.tintColor = UIColor.white
        view.backgroundColor = darkBackgroundColor
        activityIndicator.color = UIColor.white
    }

    func modifyShellDesign() {
        let javascript = "document.getElementById('page-content').getAttribute('data-current-page')"
        webView.evaluateJavaScript(javascript) { [weak self] result, error in

            guard let self = self else {
                return
            }

            if let error = error {
                print("Error getting user data: \(error)")
            }

            if result as? String == "stories-show" {
                self.removeShellShadow()
            } else {
                self.addShellShadow()
            }
        }
    }

    // MARK: - Theme configs
    func addShellShadow() {
        webView.layer.shadowColor = UIColor.gray.cgColor
        webView.layer.shadowOffset = CGSize(width: 0.0, height: 0.9)
        webView.layer.shadowOpacity = 0.5
        webView.layer.shadowRadius = 0.0
        navigationToolBar.clipsToBounds = false
    }

    func removeShellShadow() {
        webView.layer.shadowOpacity = 0.0
        navigationToolBar.clipsToBounds = true
    }

    // MARK: - Notifications Functions
    func askForNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        center.requestAuthorization(options: options) { [weak self] granted, _  in

            guard let self = self else {
                return
            }

            guard granted else { return }
            self.getNotificationSettings()
        }
    }

    func getNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { (settings) in
            print("Notification settings: \(settings)")
            guard settings.authorizationStatus == .authorized else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // MARK: - Navegation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == DoAction.openExternalURL {
            if let externalPage = segue.destination as? BrowserViewController {
                externalPage.destinationUrl = sender as? URL
            }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return useDarkMode ? .lightContent : .default
    }

    // MARK: - Podcast bridge method

    func sendPodcastMessage(name: String, parameter: String?) {
        var message = name
        if let parameter = parameter {
            message += ";\(parameter)"
        }
        let javascript = "document.getElementById('audiocontent').setAttribute('data-podcast', '\(message)')"
        webView.evaluateJavaScript(javascript) { _, error in
            if let error = error {
                print("Error sending Podcast message (\(message)): \(error.localizedDescription)")
            }
        }
    }

    func handlePodcastMessage(action: String?, parameter: String?) {
        guard let action = action else { return }

        switch action {
        case "play":
            guard let parameter = parameter, let seconds = Double(parameter) else { return }
            guard avPlayer?.timeControlStatus != .playing else { return }
            avPlayer?.seek(to: CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
            avPlayer?.play()
        case "pause":
            avPlayer?.pause()
        case "load":
            guard let audioUrl = parameter, currentPodcastURL != audioUrl else { return }
            guard let url = NSURL(string: audioUrl) else { return }
            currentPodcastURL = audioUrl
            currentPodcast = AVPlayerItem.init(url: url as URL)
            avPlayer = AVPlayer.init(playerItem: currentPodcast)
            avPlayer?.volume = 1.0
            let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            avPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
                let currentTime = String(format: "%.4f", time.seconds)
                self?.sendPodcastMessage(name: "time", parameter: currentTime)

                guard let duration = self?.currentPodcast?.duration.seconds else { return }
                self?.sendPodcastMessage(name: "duration", parameter: String(format: "%.4f", duration))
            }
        case "seek":
            guard let parameter = parameter, let seconds = Double(parameter) else { return }
            avPlayer?.seek(to: CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        case "rate":
            guard let parameter = parameter, let rate = Float(parameter) else { return }
            avPlayer?.rate = rate
        case "muted":
            avPlayer?.isMuted = parameter == "true"
        case "terminate":
            avPlayer?.pause()
        default:
            print("ERROR: Unknown action")
        }
    }
}

extension ViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let reachability = Network.reachability
        guard let isNetworkReachable = reachability?.isReachable, isNetworkReachable else {
            errorBanner.show()
            return
        }

        activityIndicator.startAnimating()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let javascript = "document.getElementsByTagName('body')[0].getAttribute('data-user-status')"
        webView.evaluateJavaScript(javascript) { [weak self] result, error in

            guard let self = self else {
                return
            }

            if let error = error {
                print("Error getting user data: \(error)")
            }
            if let jsonString = result as? String {
                self.modifyShellDesign()
                if jsonString == "logged-in" {
                    self.populateUserData()
                }
            }
        }

        activityIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Swift.Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let policy = navigationPolicy(url: url, navigationType: navigationAction.navigationType)
        decisionHandler(policy)
    }

    // MARK: - Action Policy
    func navigationPolicy(url: URL, navigationType: WKNavigationType) -> WKNavigationActionPolicy {
        if url.scheme == "mailto" {
            openURL(url)
            return .cancel
        } else if url.absoluteString == "about:blank" {
            return .allow
        } else if isAuthLink(url) {
            return .allow
        } else if url.host != "dev.to" && navigationType.rawValue == 0 {
            performSegue(withIdentifier: DoAction.openExternalURL, sender: url)
            return .cancel
        } else {
            return .allow
        }
    }
}

extension ViewController: WKScriptMessageHandler {

    // MARK: - webkit messagehandler protocol
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "haptic", let hapticType = message.body as? String {
            switch hapticType {
            case "heavy":
                let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
                heavyImpact.impactOccurred()
            case "light":
                let lightImpact = UIImpactFeedbackGenerator(style: .light)
                lightImpact.impactOccurred()
            case "medium":
                let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
                mediumImpact.impactOccurred()
            default:
                let notification = UINotificationFeedbackGenerator()
                notification.notificationOccurred(.success)
            }
        }

        if message.name == "podcast", let message = message.body as? String {
            var action, parameter: String?
            if let separatorIndex = message.firstIndex(of: ";") {
                action = String(message[..<separatorIndex])
                parameter = String(message[message.index(after: separatorIndex)...])
            } else {
                action = message
            }
            handlePodcastMessage(action: action, parameter: parameter)
        }
    }
}
