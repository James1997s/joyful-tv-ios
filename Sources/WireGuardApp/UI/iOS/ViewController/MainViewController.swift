// Joyful TV iOS port. WireGuardKit/WireGuardNetworkExtension remain under their upstream MIT license.
import UIKit
import WebKit
import MobileVLCKit
import CryptoKit
import Security
import NetworkExtension

@MainActor
final class MainViewController: UIViewController, WKNavigationDelegate, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, TunnelsManagerActivationDelegate {
    var tunnelsManager: TunnelsManager?

    private let navy = UIColor(red: 15/255, green: 17/255, blue: 43/255, alpha: 1)
    private let accent = UIColor(red: 38/255, green: 210/255, blue: 232/255, alpha: 1)
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let actionButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let searchBar = UISearchBar()
    private let categoryButton = UIButton(type: .system)
    private let favoritesButton = UIButton(type: .system)
    private let refreshButton = UIButton(type: .system)
    private let warpToggleButton = UIButton(type: .system)
    private let streamModeButton = UIButton(type: .system)
    private let renewButton = UIButton(type: .system)
    private let mailTmAttributionButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let hiddenWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    private let header = UIStackView()
    private let controls = UIStackView()
    private let content = UIStackView()
    private var selectedCategory = ""
    private var showingFavorites = false
    private var searchText = ""
    private var categories: [(id: String, name: String)] = []
    private var channels: [JoyfulChannel] = []
    private var visibleChannels: [JoyfulChannel] = []
    private var favoriteIDs = Set<String>()
    private var epgCache: [String: String] = [:]
    private var credentials: JoyfulCredentials?
    private var currentStream = "m3u8"
    private weak var playbackController: VLCPlayerViewController?
    private let warpTunnelName = "JoyfulWARP"
    private var didStart = false
    private var warpStartInProgress = false
    private var warpStopInProgress = false
    private var warpReady = false
        private var forceTrialAfterWARP = false
        private var trialGeneration = 0
        private var trialStage: TrialStage = .idle
    private var temporaryMailbox: TrialMailbox?
    private var mailboxAddress = ""
    private var firstMessageID = ""
    private var signupStartedAt = Date()
    private var gateTask: Task<Void, Never>?
    private var trialTask: Task<Void, Never>?
    private var epgTask: Task<Void, Never>?

    private enum TrialStage: Equatable { case idle, openingForm, submitting, waitingForVerification, confirming, waitingForCredentials }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = navy
        hiddenWebView.navigationDelegate = self
        buildInterface()
        NotificationCenter.default.addObserver(self, selector: #selector(vpnStatusChanged), name: .NEVPNStatusDidChange, object: nil)
        // WARP starts on launch. Saved IPTV access may continue without it; signup,
        // mailbox polling, and new-credential requests wait for verified WARP.
        beginStartupGate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        gateTask?.cancel()
        trialTask?.cancel()
        epgTask?.cancel()
    }

    private func buildInterface() {
        let title = UILabel()
        title.text = "JOYFUL TV"
        title.font = .systemFont(ofSize: 25, weight: .heavy)
        title.textColor = .white
        title.accessibilityTraits = .header

        let titleRow = UIStackView()
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.distribution = .fill
        titleRow.spacing = 8
        titleRow.addArrangedSubview(title)
        titleRow.addArrangedSubview(warpToggleButton)

        statusLabel.text = "Preparing secure connection…"
        statusLabel.textColor = UIColor(white: 0.86, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityLabel = "Connection and app status"

        progressView.progressTintColor = accent
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.16)
        progressView.isHidden = true

        configureButton(actionButton, title: "Request TV login", action: #selector(primaryAction))
        configureButton(retryButton, title: "Retry secure connection", action: #selector(retryStartup))
        configureCompactButton(categoryButton, title: "All channels ▾", action: #selector(chooseCategory))
        configureCompactButton(favoritesButton, title: "My Channels", action: #selector(toggleFavorites))
        configureCompactButton(refreshButton, title: "Refresh", action: #selector(refreshCatalog))
        configureCompactButton(streamModeButton, title: "Video: HLS", action: #selector(toggleStreamMode))
        configureWarpToggleButton(warpToggleButton)
        configureButton(renewButton, title: "Renew login", action: #selector(renewLogin))
        mailTmAttributionButton.setTitle("Temporary email by Mail.tm", for: .normal)
        mailTmAttributionButton.setTitleColor(UIColor.white.withAlphaComponent(0.72), for: .normal)
        mailTmAttributionButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        mailTmAttributionButton.contentHorizontalAlignment = .leading
        mailTmAttributionButton.addTarget(self, action: #selector(openMailTmWebsite), for: .touchUpInside)
        retryButton.isHidden = true
        actionButton.isHidden = true
        searchBar.delegate = self
        searchBar.placeholder = "Search live channels"
        searchBar.searchBarStyle = .minimal
        searchBar.tintColor = accent
        searchBar.isHidden = true
        categoryButton.isHidden = true
        favoritesButton.isHidden = true
        refreshButton.isHidden = true
        streamModeButton.isHidden = true
        renewButton.isHidden = true
        mailTmAttributionButton.isHidden = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = navy
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.12)
        tableView.rowHeight = 56
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityLabel = "Live TV channels"
        tableView.isHidden = true

        header.axis = .vertical
        header.spacing = 4
        header.alignment = .fill
        header.addArrangedSubview(titleRow)
        header.addArrangedSubview(statusLabel)
        header.addArrangedSubview(progressView)
        header.addArrangedSubview(actionButton)
        header.addArrangedSubview(retryButton)
        header.addArrangedSubview(renewButton)
        header.addArrangedSubview(mailTmAttributionButton)

        controls.axis = .horizontal
        controls.spacing = 4
        controls.distribution = .fillEqually
        controls.addArrangedSubview(categoryButton)
        controls.addArrangedSubview(favoritesButton)
        controls.addArrangedSubview(refreshButton)
        controls.addArrangedSubview(streamModeButton)

        content.axis = .vertical
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(header)
        content.addArrangedSubview(controls)
        content.addArrangedSubview(searchBar)
        content.addArrangedSubview(tableView)
        view.addSubview(content)
        hiddenWebView.alpha = 0
        hiddenWebView.isUserInteractionEnabled = false
        view.addSubview(hiddenWebView)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            searchBar.heightAnchor.constraint(lessThanOrEqualToConstant: 44)
        ])
        updateWarpToggle()
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(navy, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        button.backgroundColor = accent
        button.layer.cornerRadius = 11
        button.contentEdgeInsets = UIEdgeInsets(top: 13, left: 12, bottom: 13, right: 12)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func configureCompactButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(navy, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.72
        button.backgroundColor = accent
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func configureWarpToggleButton(_ button: UIButton) {
        button.setTitleColor(navy, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .heavy)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.layer.cornerRadius = 11
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        button.widthAnchor.constraint(equalToConstant: 92).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: #selector(toggleWARP), for: .touchUpInside)
    }

    // MARK: WARP gate

    private func beginStartupGate() {
        guard !warpStartInProgress, !warpStopInProgress else { return }
        warpStartInProgress = true
        didStart = false
        updateWarpToggle()
        retryButton.isHidden = true
        actionButton.isHidden = true
        statusLabel.text = "Starting WARP. Approve the iOS VPN prompt if it appears…"
        progressView.isHidden = false
        progressView.setProgress(0.08, animated: true)
        TunnelsManager.create { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.warpStartFailed("Could not load the iOS VPN configuration: \(Self.tunnelErrorDetails(error))")
                case .success(let manager):
                    self.tunnelsManager = manager
                    manager.activationDelegate = self
                    self.installOrStartWARP(using: manager)
                }
            }
        }
    }

    private func installOrStartWARP(using manager: TunnelsManager) {
        if let tunnel = manager.tunnel(named: warpTunnelName) {
            if tunnel.status == .active {
                waitForConnectedWARP(using: manager)
            } else {
                statusLabel.text = "Connecting WARP. Confirm the iOS VPN request…"
                manager.startActivation(of: tunnel)
                waitForConnectedWARP(using: manager)
            }
            return
        }
        guard let profileURL = Bundle.main.url(forResource: "warp_profile", withExtension: "conf"),
              let profile = try? String(contentsOf: profileURL, encoding: .utf8), !profile.isEmpty else {
            warpStartFailed("WARP profile is missing from this build. No credentials will be requested.")
            return
        }
        do {
            let configuration = try TunnelConfiguration(fromWgQuickConfig: profile, called: warpTunnelName)
            statusLabel.text = "Adding WARP to iOS VPN settings…"
            manager.add(tunnelConfiguration: configuration) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.warpStartFailed("Could not install the WARP tunnel: \(Self.tunnelErrorDetails(error))")
                    case .success(let tunnel):
                        self.statusLabel.text = "Connecting WARP. Confirm the iOS VPN request…"
                        manager.startActivation(of: tunnel)
                        self.waitForConnectedWARP(using: manager)
                    }
                }
            }
        } catch {
            warpStartFailed("The WARP profile could not be read. No credentials will be requested.")
        }
    }

    private func waitForConnectedWARP(using manager: TunnelsManager) {
        gateTask?.cancel()
        gateTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<90 {
                if Task.isCancelled { return }
                let tunnel = manager.tunnel(named: self.warpTunnelName)
                if tunnel?.status == .active {
                    let verified = await self.verifyCloudflareWARP()
                    guard verified, manager.tunnel(named: self.warpTunnelName)?.status == .active else {
                        self.warpStartFailed("The tunnel connected, but Cloudflare did not verify WARP routing. No mailbox or IPTV credentials were requested.")
                        return
                    }
                    self.warpReady = true
                    self.warpStartInProgress = false
                    self.warpStopInProgress = false
                    self.updateWarpToggle()
                    self.progressView.setProgress(0.35, animated: true)
                    self.statusLabel.text = "WARP connected and verified."
                    await self.continueOnlyAfterWARP()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self.warpStartInProgress = false
            self.warpReady = false
            self.warpStartFailed("WARP did not connect. Approve the VPN prompt and retry. No mailbox or IPTV credentials were requested.")
        }
    }

    private func continueOnlyAfterWARP() async {
        guard warpReady, !didStart else { return }
        didStart = true
        if forceTrialAfterWARP {
            forceTrialAfterWARP = false
            startTrial()
            return
        }
        if let saved = SecureCredentialVault.load(), saved.expiresAt > Date() {
            credentials = saved
            await loadCatalog()
        } else {
            statusLabel.text = "WARP is on. Preparing your temporary mailbox…"
            startTrial()
        }
    }

    private func warpStartFailed(_ message: String) {
        warpReady = false
        warpStartInProgress = false
        warpStopInProgress = false
        gateTask?.cancel()
        updateWarpToggle()
        if let saved = SecureCredentialVault.load(), saved.expiresAt > Date() {
            credentials = saved
            progressView.isHidden = true
            actionButton.isHidden = true
            retryButton.isHidden = true
            mailTmAttributionButton.isHidden = true
            statusLabel.text = "WARP is off. Live TV works without it; connect WARP to request new credentials."
            Task { await loadCatalog() }
            return
        }
        statusLabel.text = message
        progressView.isHidden = true
        actionButton.isHidden = true
        retryButton.isHidden = false
        tableView.isHidden = true
        searchBar.isHidden = true
        categoryButton.isHidden = true
        favoritesButton.isHidden = true
        refreshButton.isHidden = true
        streamModeButton.isHidden = true
        renewButton.isHidden = true
        mailTmAttributionButton.isHidden = true
        trialTask?.cancel()
    }

    @objc private func retryStartup() { beginStartupGate() }

    @objc private func toggleWARP() {
        guard !warpStartInProgress, !warpStopInProgress else { return }
        if warpReady {
            guard let manager = tunnelsManager, let tunnel = manager.tunnel(named: warpTunnelName) else {
                warpReady = false
                updateWarpToggle()
                statusLabel.text = "WARP is off. Live TV can continue; connect WARP to request new credentials."
                return
            }
            warpReady = false
            warpStopInProgress = true
            trialGeneration &+= 1
            if trialStage != .idle || temporaryMailbox != nil {
                trialTask?.cancel()
                trialTask = nil
                trialStage = .idle
                temporaryMailbox = nil
                progressView.isHidden = true
                statusLabel.text = "WARP turned off. Credential requests stopped; Live TV can continue."
            } else {
                statusLabel.text = "Turning WARP off. Live TV traffic can continue."
            }
            updateWarpToggle()
            manager.startDeactivation(of: tunnel)
        } else {
            beginStartupGate()
        }
    }

    @objc private func vpnStatusChanged() {
        guard let manager = tunnelsManager else { return }
        manager.refreshStatuses()
        if manager.tunnel(named: warpTunnelName)?.status == .inactive {
            let wasReady = warpReady
            warpReady = false
            warpStopInProgress = false
            trialGeneration &+= 1
            if trialStage != .idle || temporaryMailbox != nil {
                trialTask?.cancel()
                trialTask = nil
                trialStage = .idle
                temporaryMailbox = nil
                progressView.isHidden = true
                statusLabel.text = "WARP disconnected. Credential requests stopped; saved Live TV can continue."
            } else if wasReady {
                statusLabel.text = "WARP is off · Live TV continues. Connect WARP to request new credentials."
            }
            updateWarpToggle()
        }
    }

    private func updateWarpToggle() {
        let transitioning = warpStartInProgress || warpStopInProgress
        let title = transitioning ? "WARP …" : (warpReady ? "WARP ON" : "WARP OFF")
        warpToggleButton.setTitle(title, for: .normal)
        warpToggleButton.backgroundColor = warpReady ? accent : UIColor(white: 0.78, alpha: 1)
        warpToggleButton.isEnabled = !transitioning
        warpToggleButton.accessibilityLabel = transitioning ? "WARP changing state" : (warpReady ? "WARP connected; tap to disconnect" : "WARP disconnected; tap to connect")
        playbackController?.setWARPState(isOn: warpReady, isChanging: transitioning)
    }

    private func verifyCloudflareWARP() async -> Bool {
        guard let url = URL(string: "https://cloudflare.com/cdn-cgi/trace") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for attempt in 0..<4 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let trace = String(data: data, encoding: .utf8),
                   trace.components(separatedBy: .newlines).contains(where: { $0 == "warp=on" || $0 == "warp=plus" }) { return true }
            } catch { }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        return false
    }

    private static func tunnelErrorDetails(_ error: TunnelsManagerError) -> String {
        let underlying: Error
        switch error {
        case .systemErrorOnListingTunnels(let value),
             .systemErrorOnAddTunnel(let value),
             .systemErrorOnModifyTunnel(let value),
             .systemErrorOnRemoveTunnel(let value):
            underlying = value
        case .tunnelNameEmpty:
            return "Tunnel name is empty."
        case .tunnelAlreadyExistsWithThatName:
            return "A tunnel with this name already exists."
        }
        let system = underlying as NSError
        return "\(system.domain) (code \(system.code)): \(system.localizedDescription)"
    }

    func tunnelActivationAttemptFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationAttemptError) {
        if tunnel.name == warpTunnelName { warpStartFailed("WARP could not start: \(error.localizedDescription). No credentials were requested.") }
    }
    func tunnelActivationAttemptSucceeded(tunnel: TunnelContainer) { }
    func tunnelActivationFailed(tunnel: TunnelContainer, error: TunnelsManagerActivationError) {
        if tunnel.name == warpTunnelName { warpStartFailed("WARP failed to connect: \(error.localizedDescription). No credentials were requested.") }
    }
    func tunnelActivationSucceeded(tunnel: TunnelContainer) {
        if tunnel.name == warpTunnelName { vpnStatusChanged() }
    }

    // Methods retained for the existing WireGuard iOS application delegate.
    func refreshTunnelConnectionStatuses() { tunnelsManager?.refreshStatuses() }
    func allTunnelNames() -> [String]? { tunnelsManager?.mapTunnels { $0.name } }
    func showTunnelDetailForTunnel(named name: String, animated: Bool, shouldToggleStatus: Bool) {
        guard shouldToggleStatus, let manager = tunnelsManager, let tunnel = manager.tunnel(named: name) else { return }
        if tunnel.status == .inactive { manager.startActivation(of: tunnel) }
        else if tunnel.status == .active { manager.startDeactivation(of: tunnel) }
    }
    func importFromDisposableFile(url: URL) { }

    // MARK: Mail.tm trial flow

    private func startTrial() {
        guard warpReady else {
            forceTrialAfterWARP = true
            statusLabel.text = "WARP is required for new credentials. Connecting before starting the email flow…"
            beginStartupGate()
            return
        }
        forceTrialAfterWARP = false
        trialGeneration &+= 1
        let generation = trialGeneration
        trialTask?.cancel()
        discardMailbox()
        trialStage = .openingForm
        progressView.isHidden = false
        progressView.setProgress(0.38, animated: true)
        actionButton.isHidden = true
        retryButton.isHidden = true
        mailTmAttributionButton.isHidden = false
        statusLabel.text = "WARP is on. Creating your temporary mailbox…"
        trialTask = Task { [weak self] in
            guard let self else { return }
            var createdMailbox: TrialMailbox?
            do {
                let mailbox = try await MailTm.createMailbox()
                createdMailbox = mailbox
                try Task.checkCancellation()
                guard self.trialGeneration == generation else { throw CancellationError() }
                self.temporaryMailbox = mailbox
                guard self.warpReady else { throw JoyfulError.warpLost }
                self.mailboxAddress = mailbox.address
                self.trialStage = .openingForm
                self.statusLabel.text = "WARP is on. Opening the trial form for \(mailbox.address)…"
                self.hiddenWebView.load(URLRequest(url: URL(string: "https://joyful.watch/trial/")!))
            } catch is CancellationError {
                if let createdMailbox {
                    if self.temporaryMailbox?.id == createdMailbox.id { self.discardMailbox() }
                    else if self.warpReady { Task { await MailTm.deleteMailbox(createdMailbox) } }
                }
            } catch {
                if let createdMailbox {
                    if self.temporaryMailbox?.id == createdMailbox.id { self.discardMailbox() }
                    else if self.warpReady { Task { await MailTm.deleteMailbox(createdMailbox) } }
                }
                self.showTrialFailure("Could not create the temporary inbox: \(error.localizedDescription)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch trialStage {
        case .openingForm:
            guard warpReady else { showTrialFailure("WARP disconnected before the signup. No new credentials were requested."); return }
            submitTrialForm(in: webView)
        case .confirming:
            guard warpReady else { showTrialFailure("WARP disconnected before the account email was fetched."); return }
            trialStage = .waitingForCredentials
            statusLabel.text = "Email confirmed. Waiting for your IPTV login…"
            pollMailbox(excluding: firstMessageID, label: "account details")
        default: break
        }
    }

    private func submitTrialForm(in webView: WKWebView) {
        guard trialStage == .openingForm else { return }
        trialStage = .submitting
        let script = """
        (function(){
          var f=document.querySelector('#mc4wp-form-1');
          if(!f)return JSON.stringify({ok:false,error:'Trial form not found'});
          var n=f.querySelector('input[name=FNAME]'),e=f.querySelector('input[name=EMAIL]'),h=f.querySelector('input[name=_mc4wp_honeypot]');
          if(!n||!e)return JSON.stringify({ok:false,error:'Expected trial fields not found'});
          function set(x,v){x.value=v;x.dispatchEvent(new Event('input',{bubbles:true}));x.dispatchEvent(new Event('change',{bubbles:true}));}
          set(n,'QA Test');set(e,\(Self.jsQuote(mailboxAddress)));if(h)h.value='';
          if(!f.checkValidity())return JSON.stringify({ok:false,error:'Trial form validation failed'});
          if(f.requestSubmit)f.requestSubmit();else f.querySelector('button[type=submit],input[type=submit]').click();
          return JSON.stringify({ok:true});
        })()
        """
        let generation = trialGeneration
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            guard self.trialGeneration == generation else { return }
            guard self.warpReady else { self.showTrialFailure("WARP disconnected before the account email was fetched."); return }
            let raw = result as? String ?? ""
            if error != nil || !raw.contains("\"ok\":true") {
                self.showTrialFailure("The trial form could not be submitted. Check the form and retry.")
                return
            }
            self.signupStartedAt = Date()
            self.trialStage = .waitingForVerification
            self.statusLabel.text = "Trial form submitted securely. Waiting for the verification email…"
            self.pollMailbox(excluding: "", label: "verification email")
        }
    }

    private func pollMailbox(excluding excludedID: String, label: String) {
        guard warpReady else { showTrialFailure("WARP disconnected. No account credentials were fetched."); return }
        trialTask?.cancel()
        guard let mailbox = temporaryMailbox else {
            showTrialFailure("The temporary mailbox is no longer available. Please try again.")
            return
        }
        let generation = trialGeneration
        trialTask = Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await MailTm.waitForMessage(mailbox: mailbox, excluding: excludedID, label: label, warpIsReady: { self.warpReady }, progress: { [weak self] text in
                    DispatchQueue.main.async { self?.statusLabel.text = text }
                })
                try Task.checkCancellation()
                guard self.trialGeneration == generation else { return }
                guard self.temporaryMailbox?.id == mailbox.id else { return }
                guard self.warpReady else { throw JoyfulError.warpLost }
                if self.trialStage == .waitingForVerification {
                    guard let verifyURL = MailTm.verificationURL(from: message) else {
                        throw JoyfulError.message("Verification email did not contain a recognized confirmation link.")
                    }
                    self.firstMessageID = message["id"] as? String ?? message["message_id"] as? String ?? ""
                    self.trialStage = .confirming
                    self.statusLabel.text = "WARP is on. Confirming the email…"
                    self.hiddenWebView.load(URLRequest(url: verifyURL))
                } else {
                    let text = MailTm.messageText(message)
                    let details = try MailTm.extractCredentials(text)
                    guard self.warpReady else { throw JoyfulError.warpLost }
                    let saved = JoyfulCredentials(portal: details.portal, username: details.username, password: details.password, expiresAt: self.signupStartedAt.addingTimeInterval(24 * 60 * 60))
                    try SecureCredentialVault.save(saved)
                    self.credentials = saved
                    self.discardMailbox()
                    self.trialStage = .idle
                    self.trialGeneration &+= 1
                    self.statusLabel.text = "WARP is on. Account details saved securely for 24 hours."
                    self.progressView.setProgress(1, animated: true)
                    await self.loadCatalog()
                }
            } catch is CancellationError {
                if self.temporaryMailbox?.id == mailbox.id { self.discardMailbox() }
            } catch {
                if self.temporaryMailbox?.id == mailbox.id {
                    self.showTrialFailure(error.localizedDescription)
                }
            }
        }
    }

    private func discardMailbox() {
        guard let mailbox = temporaryMailbox else { return }
        temporaryMailbox = nil
        guard warpReady else { return }
        Task { await MailTm.deleteMailbox(mailbox) }
    }

    private func showTrialFailure(_ message: String) {
        trialGeneration &+= 1
        trialStage = .idle
        progressView.isHidden = true
        statusLabel.text = "\(message)\nWARP must remain connected before trying again."
        actionButton.setTitle("Try again", for: .normal)
        actionButton.isHidden = false
        retryButton.isHidden = true
    }

    @objc private func primaryAction() {
        guard warpReady else {
            if actionButton.title(for: .normal) != "Retry loading channels" { forceTrialAfterWARP = true }
            beginStartupGate()
            return
        }
        actionButton.setTitle("Request TV login", for: .normal)
        startTrial()
    }
    @objc private func renewLogin() {
        forceTrialAfterWARP = true
        startTrial()
    }
    @objc private func openMailTmWebsite() {
        guard let url = URL(string: "https://mail.tm") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: IPTV

    private func loadCatalog() async {
        guard let credentials else { return }
        progressView.isHidden = false
        progressView.setProgress(0.55, animated: true)
        statusLabel.text = "\(warpReady ? "WARP is on" : "WARP is off") · Loading live channels…"
        do {
            let result = try await XtreamClient(portal: credentials.portal, username: credentials.username, password: credentials.password).loadLiveCatalog()
            categories = result.categories
            channels = result.channels
            favoriteIDs = JoyfulFavorites.load(account: credentials)
            applyFilters()
            tableView.isHidden = false
            searchBar.isHidden = false
            categoryButton.isHidden = false
            favoritesButton.isHidden = false
            refreshButton.isHidden = false
            streamModeButton.isHidden = false
            streamModeButton.setTitle(currentStream == "m3u8" ? "Video: HLS" : "Video: TS", for: .normal)
            renewButton.isHidden = false
            mailTmAttributionButton.isHidden = true
            actionButton.isHidden = true
            retryButton.isHidden = true
            statusLabel.text = "\(warpReady ? "WARP is on" : "WARP is off") · \(channels.count) live channels · Login expires \(Self.expiryText(credentials.expiresAt))"
            progressView.setProgress(1, animated: true)
            progressView.isHidden = true
        } catch {
            progressView.isHidden = true
            let networkError = error as NSError
            if networkError.domain == NSURLErrorDomain && networkError.code == -1022 {
                let portalURL = URLComponents(string: credentials.portal)
                let portalHost = portalURL?.host ?? "the IPTV portal"
                statusLabel.text = "iOS blocked an HTTP redirect from \(portalHost). Cleartext HTTP is allowed only for kytv.xyz; the portal may have redirected to another host."
            } else if networkError.domain == NSURLErrorDomain && [-1200, -1201, -1202].contains(networkError.code) {
                let portalHost = URLComponents(string: credentials.portal)?.host ?? "the IPTV portal"
                statusLabel.text = "Could not establish a secure connection to \(portalHost). Check that the portal server is available."
            } else {
                statusLabel.text = "Could not load Live TV: \(error.localizedDescription)"
            }
            actionButton.setTitle("Retry loading channels", for: .normal)
            actionButton.isHidden = false
        }
    }

    private func applyFilters() {
        visibleChannels = channels.filter { channel in
            let categoryOK = selectedCategory.isEmpty || channel.categoryID == selectedCategory
            let favoriteOK = !showingFavorites || favoriteIDs.contains(channel.identity)
            let searchOK = searchText.isEmpty || channel.name.localizedCaseInsensitiveContains(searchText)
            return categoryOK && favoriteOK && searchOK
        }
        tableView.reloadData()
    }

    @objc private func chooseCategory() {
        let sheet = UIAlertController(title: "Channel category", message: nil, preferredStyle: .actionSheet)
        let choices = [("", "All channels")] + categories.map { ($0.id, $0.name) }
        for (id, name) in choices.prefix(30) {
            sheet.addAction(UIAlertAction(title: name, style: .default) { [weak self] _ in
                self?.selectedCategory = id
                self?.showingFavorites = false
                self?.categoryButton.setTitle("\(name)  ▾", for: .normal)
                self?.applyFilters()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController { pop.sourceView = categoryButton; pop.sourceRect = categoryButton.bounds }
        present(sheet, animated: true)
    }

    @objc private func toggleFavorites() {
        showingFavorites.toggle()
        selectedCategory = ""
        categoryButton.setTitle(showingFavorites ? "My Channels  ▾" : "All channels  ▾", for: .normal)
        applyFilters()
    }

    @objc private func toggleStreamMode() {
        currentStream = currentStream == "m3u8" ? "ts" : "m3u8"
        streamModeButton.setTitle(currentStream == "m3u8" ? "Video: HLS" : "Video: TS", for: .normal)
        statusLabel.text = currentStream == "m3u8"
            ? "Standard mode selected. HLS is tried first; alternate formats retry automatically."
            : "Compatibility mode selected. TS is tried first; alternate formats retry automatically."
    }

    @objc private func refreshCatalog() {
        Task { await loadCatalog() }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        self.searchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        applyFilters()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visibleChannels.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "channel") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "channel")
        let channel = visibleChannels[indexPath.row]
        cell.backgroundColor = navy
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        cell.detailTextLabel?.textColor = UIColor(white: 0.72, alpha: 1)
        cell.detailTextLabel?.font = .systemFont(ofSize: 12)
        let number = channel.number.isEmpty ? "" : "\(channel.number)  ·  "
        cell.textLabel?.text = "\(number)\(channel.name)"
        cell.detailTextLabel?.text = epgCache[channel.identity] ?? "Tap to watch · Use the star to save"
        let star = UIButton(type: .system)
        star.tag = indexPath.row
        star.setTitle(favoriteIDs.contains(channel.identity) ? "★" : "☆", for: .normal)
        star.titleLabel?.font = .systemFont(ofSize: 25, weight: .bold)
        star.setTitleColor(accent, for: .normal)
        star.accessibilityLabel = favoriteIDs.contains(channel.identity) ? "Remove from My Channels" : "Add to My Channels"
        star.addTarget(self, action: #selector(toggleFavoriteButton(_:)), for: .touchUpInside)
        star.frame = CGRect(x: 0, y: 0, width: 50, height: 48)
        cell.accessoryView = star
        cell.accessoryType = .none
        cell.selectionStyle = .default
        return cell
    }

    @objc private func toggleFavoriteButton(_ sender: UIButton) {
        guard visibleChannels.indices.contains(sender.tag), let credentials else { return }
        let identity = visibleChannels[sender.tag].identity
        if favoriteIDs.contains(identity) { favoriteIDs.remove(identity) } else { favoriteIDs.insert(identity) }
        JoyfulFavorites.save(favoriteIDs, account: credentials)
        applyFilters()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let credentials else { statusLabel.text = "Load or request a TV login before playing channels."; return }
        let channel = visibleChannels[indexPath.row]
        let urls = XtreamClient(portal: credentials.portal, username: credentials.username, password: credentials.password).streamURLs(for: channel, preferredExtension: currentStream)
        guard !urls.isEmpty else {
            statusLabel.text = "Channel has no playable stream URL."; return
        }
        fetchEpg(for: channel)
        let controller = VLCPlayerViewController(channelTitle: channel.name, urls: urls, warpIsOn: warpReady) { [weak self] in
            self?.toggleWARP()
        }
        playbackController = controller
        present(controller, animated: true)
    }

    private func fetchEpg(for channel: JoyfulChannel) {
        guard let credentials else { return }
        epgTask?.cancel()
        if let cached = epgCache[channel.identity] { statusLabel.text = "\(warpReady ? "WARP is on" : "WARP is off") · Now: \(cached)"; return }
        epgTask = Task {
            do {
                let title = try await XtreamClient(portal: credentials.portal, username: credentials.username, password: credentials.password).nowNext(streamID: channel.streamID)
                if let title { epgCache[channel.identity] = title; statusLabel.text = "\(warpReady ? "WARP is on" : "WARP is off") · Now: \(title)"; tableView.reloadData() }
            } catch { /* Guide metadata is optional; playback continues. */ }
        }
    }

    // MARK: Orientation / helper methods

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        controls.axis = .horizontal
        controls.distribution = .fillEqually
    }

    private static func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func jsQuote(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              let array = String(data: data, encoding: .utf8), array.count >= 2 else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }
}

@MainActor
private final class VLCPlayerViewController: UIViewController {
    private let navy = UIColor(red: 15/255, green: 17/255, blue: 43/255, alpha: 1)
    private let accent = UIColor(red: 38/255, green: 210/255, blue: 232/255, alpha: 1)
    private let channelTitle: String
    private let urls: [URL]
    private let onWarpToggle: () -> Void
    private let player = VLCMediaPlayer()
    private let videoSurface = UIView()
    private let topBar = UIStackView()
    private let bottomBar = UIStackView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    private let warpButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let audioTrackButton = UIButton(type: .system)
    private let videoTrackButton = UIButton(type: .system)
    private var stateTimer: Timer?
    private var controlsHideTimer: Timer?
    private var controlsHidden = false
    private var wasPlaying = false
    private var audioTrackDisabled = false
    private var videoTrackDisabled = false
    private var audioTrackStateInitialized = false
    private var videoTrackStateInitialized = false
    private var audioTrackIndexToRestore: Int32?
    private var videoTrackIndexToRestore: Int32?
    private var attemptIndex = 0
    private var retryCount = 0
    private var attemptStartedAt = Date()
    private var retryScheduled = false
    private var isClosing = false

    init(channelTitle: String, urls: [URL], warpIsOn: Bool, onWarpToggle: @escaping () -> Void) {
        self.channelTitle = channelTitle
        self.urls = urls
        self.onWarpToggle = onWarpToggle
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        setWARPState(isOn: warpIsOn, isChanging: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildPlayerInterface()
        player.drawable = videoSurface
        attemptIndex = 0
        startAttempt()
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshPlaybackState()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            stopPlayer()
        }
    }

    func setWARPState(isOn: Bool, isChanging: Bool) {
        warpButton.setTitle(isChanging ? "WARP …" : (isOn ? "WARP ON" : "WARP OFF"), for: .normal)
        warpButton.backgroundColor = isOn ? accent : UIColor(white: 0.78, alpha: 1)
        warpButton.isEnabled = !isChanging
        warpButton.accessibilityLabel = isChanging ? "WARP changing state" : (isOn ? "WARP connected; tap to disconnect" : "WARP disconnected; tap to connect")
        if isChanging {
            cancelControlsAutoHide()
            setControlsHidden(false)
        } else if wasPlaying {
            scheduleControlsAutoHide()
        }
    }

    private func buildPlayerInterface() {
        videoSurface.translatesAutoresizingMaskIntoConstraints = false
        videoSurface.backgroundColor = .black
        videoSurface.isUserInteractionEnabled = true
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        tapGesture.cancelsTouchesInView = false
        videoSurface.addGestureRecognizer(tapGesture)
        view.addSubview(videoSurface)

        topBar.axis = .horizontal
        topBar.alignment = .center
        topBar.spacing = 8
        topBar.isLayoutMarginsRelativeArrangement = true
        topBar.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        topBar.backgroundColor = UIColor.black.withAlphaComponent(0.65)

        let closeButton = makePlayerButton(title: "Close")
        closeButton.accessibilityLabel = "Close player"
        closeButton.widthAnchor.constraint(equalToConstant: 58).isActive = true
        closeButton.addTarget(self, action: #selector(closePlayer), for: .touchUpInside)
        titleLabel.text = channelTitle
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        warpButton.setTitleColor(navy, for: .normal)
        warpButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .heavy)
        warpButton.layer.cornerRadius = 10
        warpButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        warpButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        warpButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        warpButton.addTarget(self, action: #selector(toggleWARP), for: .touchUpInside)
        topBar.addArrangedSubview(closeButton)
        topBar.addArrangedSubview(titleLabel)
        topBar.addArrangedSubview(warpButton)
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        statusLabel.text = "Connecting to channel…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        activityIndicator.color = accent
        activityIndicator.startAnimating()

        bottomBar.axis = .vertical
        bottomBar.alignment = .fill
        bottomBar.spacing = 8
        bottomBar.isLayoutMarginsRelativeArrangement = true
        bottomBar.layoutMargins = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        bottomBar.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        bottomBar.addArrangedSubview(statusLabel)

        let controls = UIStackView()
        controls.axis = .horizontal
        controls.alignment = .center
        controls.distribution = .fillEqually
        controls.spacing = 10
        playPauseButton.setTitle("Pause", for: .normal)
        playPauseButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        retryButton.setTitle("Retry", for: .normal)
        retryButton.accessibilityLabel = "Retry channel"
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryChannel), for: .touchUpInside)
        audioTrackButton.setTitle("Audio off", for: .normal)
        audioTrackButton.addTarget(self, action: #selector(toggleAudioTrack), for: .touchUpInside)
        videoTrackButton.setTitle("Video off", for: .normal)
        videoTrackButton.addTarget(self, action: #selector(toggleVideoTrack), for: .touchUpInside)
        for button in [playPauseButton, audioTrackButton, videoTrackButton, retryButton] {
            button.setTitleColor(navy, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
            button.backgroundColor = accent
            button.layer.cornerRadius = 11
            button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        }
        audioTrackButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        videoTrackButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        audioTrackButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 4, bottom: 12, right: 4)
        videoTrackButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 4, bottom: 12, right: 4)
        controls.addArrangedSubview(playPauseButton)
        controls.addArrangedSubview(audioTrackButton)
        controls.addArrangedSubview(videoTrackButton)
        controls.addArrangedSubview(retryButton)
        bottomBar.addArrangedSubview(controls)
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            videoSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoSurface.topAnchor.constraint(equalTo: view.topAnchor),
            videoSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func scheduleControlsAutoHide() {
        cancelControlsAutoHide()
        guard player.state == .playing, !isClosing else { return }
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, self.player.state == .playing else { return }
            self.setControlsHidden(true)
            self.controlsHideTimer = nil
        }
    }

    private func cancelControlsAutoHide() {
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
    }

    private func setControlsHidden(_ hidden: Bool) {
        guard controlsHidden != hidden else { return }
        controlsHidden = hidden
        topBar.isUserInteractionEnabled = !hidden
        bottomBar.isUserInteractionEnabled = !hidden
        topBar.accessibilityElementsHidden = hidden
        bottomBar.accessibilityElementsHidden = hidden
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.topBar.alpha = hidden ? 0 : 1
            self.bottomBar.alpha = hidden ? 0 : 1
        }
    }

    @objc private func toggleControls() {
        let shouldHide = !controlsHidden && player.state == .playing
        cancelControlsAutoHide()
        setControlsHidden(shouldHide)
        if !shouldHide, player.state == .playing { scheduleControlsAutoHide() }
    }

    private func makePlayerButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(navy, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .bold)
        button.backgroundColor = accent
        button.layer.cornerRadius = 10
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    private func updateTrackButtons() {
        let canToggle = !isClosing && (player.state == .playing || player.state == .paused)
        let audioIDs = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value ?? ($0 as? Int32) }.filter { $0 >= 0 }
        let videoIDs = player.videoTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value ?? ($0 as? Int32) }.filter { $0 >= 0 }

        if canToggle && !audioTrackStateInitialized && !audioIDs.isEmpty {
            let current = player.currentAudioTrackIndex
            audioTrackDisabled = current < 0
            audioTrackIndexToRestore = current >= 0 ? current : audioIDs.first
            audioTrackStateInitialized = true
        }
        if canToggle && !videoTrackStateInitialized && !videoIDs.isEmpty {
            let current = player.currentVideoTrackIndex
            videoTrackDisabled = current < 0
            videoTrackIndexToRestore = current >= 0 ? current : videoIDs.first
            videoTrackStateInitialized = true
        }

        audioTrackButton.isEnabled = canToggle && !audioIDs.isEmpty
        audioTrackButton.setTitle(audioIDs.isEmpty ? "No audio" : (audioTrackDisabled ? "Audio on" : "Audio off"), for: .normal)
        audioTrackButton.accessibilityLabel = audioIDs.isEmpty ? "No audio track available" : (audioTrackDisabled ? "Turn audio track on" : "Turn audio track off")
        videoTrackButton.isEnabled = canToggle && !videoIDs.isEmpty
        videoTrackButton.setTitle(videoIDs.isEmpty ? "No video" : (videoTrackDisabled ? "Video on" : "Video off"), for: .normal)
        videoTrackButton.accessibilityLabel = videoIDs.isEmpty ? "No video track available" : (videoTrackDisabled ? "Turn video track on" : "Turn video track off")
    }

    @objc private func toggleAudioTrack() {
        let ids = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value ?? ($0 as? Int32) }.filter { $0 >= 0 }
        guard !ids.isEmpty, player.state == .playing || player.state == .paused else { return }
        if audioTrackDisabled {
            guard let target = audioTrackIndexToRestore.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first else { return }
            player.currentAudioTrackIndex = target
            audioTrackDisabled = false
            audioTrackIndexToRestore = target
        } else {
            let current = player.currentAudioTrackIndex
            audioTrackIndexToRestore = current >= 0 ? current : ids.first
            player.currentAudioTrackIndex = -1
            audioTrackDisabled = true
        }
        updateTrackButtons()
    }

    @objc private func toggleVideoTrack() {
        let ids = player.videoTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value ?? ($0 as? Int32) }.filter { $0 >= 0 }
        guard !ids.isEmpty, player.state == .playing || player.state == .paused else { return }
        if videoTrackDisabled {
            guard let target = videoTrackIndexToRestore.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first else { return }
            player.currentVideoTrackIndex = target
            videoTrackDisabled = false
            videoTrackIndexToRestore = target
        } else {
            let current = player.currentVideoTrackIndex
            videoTrackIndexToRestore = current >= 0 ? current : ids.first
            player.currentVideoTrackIndex = -1
            videoTrackDisabled = true
        }
        updateTrackButtons()
    }

    private func startAttempt() {
        guard urls.indices.contains(attemptIndex), !isClosing else { return }
        retryScheduled = false
        audioTrackDisabled = false
        videoTrackDisabled = false
        audioTrackStateInitialized = false
        videoTrackStateInitialized = false
        audioTrackIndexToRestore = nil
        videoTrackIndexToRestore = nil
        wasPlaying = false
        cancelControlsAutoHide()
        setControlsHidden(false)
        attemptStartedAt = Date()
        statusLabel.isHidden = false
        statusLabel.text = "Connecting to channel…"
        activityIndicator.startAnimating()
        retryButton.isHidden = true
        playPauseButton.setTitle("Pause", for: .normal)
        player.stop()
        player.drawable = videoSurface
        player.media = VLCMedia(url: urls[attemptIndex])
        player.play()
        updateTrackButtons()
    }

    private func refreshPlaybackState() {
        guard !isClosing else { return }
        updateTrackButtons()
        switch player.state {
        case .playing:
            retryScheduled = false
            retryCount = 0
            statusLabel.isHidden = true
            activityIndicator.stopAnimating()
            playPauseButton.setTitle("Pause", for: .normal)
            if !wasPlaying {
                wasPlaying = true
                setControlsHidden(false)
                scheduleControlsAutoHide()
            }
        case .paused:
            wasPlaying = false
            cancelControlsAutoHide()
            setControlsHidden(false)
            statusLabel.isHidden = false
            statusLabel.text = "Playback paused"
            activityIndicator.stopAnimating()
            playPauseButton.setTitle("Resume", for: .normal)
        case .error, .ended:
            wasPlaying = false
            cancelControlsAutoHide()
            setControlsHidden(false)
            tryFallbackOrRetry()
        case .opening, .buffering:
            wasPlaying = false
            cancelControlsAutoHide()
            setControlsHidden(false)
            statusLabel.isHidden = false
            statusLabel.text = "Loading \(channelTitle)…"
            if Date().timeIntervalSince(attemptStartedAt) > 20 { tryFallbackOrRetry() }
        case .stopped:
            wasPlaying = false
            cancelControlsAutoHide()
            setControlsHidden(false)
            if Date().timeIntervalSince(attemptStartedAt) > 20 { tryFallbackOrRetry() }
        default:
            break
        }
    }

    private func tryFallbackOrRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        wasPlaying = false
        cancelControlsAutoHide()
        setControlsHidden(false)
        activityIndicator.stopAnimating()
        if attemptIndex + 1 < urls.count {
            attemptIndex += 1
            statusLabel.isHidden = false
            statusLabel.text = "Trying an alternate stream format…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startAttempt() }
            return
        }
        if retryCount < 3 {
            let delay = min(pow(2.0, Double(retryCount)), 8.0)
            retryCount += 1
            attemptIndex = 0
            statusLabel.isHidden = false
            statusLabel.text = "Stream interrupted. Retrying in \(Int(delay)) seconds…"
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startAttempt() }
            return
        }
        statusLabel.isHidden = false
        statusLabel.text = "This channel could not start. Try another channel or check the provider stream."
        retryButton.isHidden = false
    }

    private func stopPlayer() {
        guard !isClosing else { return }
        isClosing = true
        stateTimer?.invalidate()
        stateTimer = nil
        cancelControlsAutoHide()
        player.stop()
        player.drawable = nil
    }

    @objc private func closePlayer() {
        stopPlayer()
        dismiss(animated: true)
    }

    @objc private func toggleWARP() { onWarpToggle() }

    @objc private func togglePlayback() {
        if player.state == .playing || player.state == .buffering {
            player.pause()
        } else {
            player.play()
        }
        refreshPlaybackState()
    }

    @objc private func retryChannel() {
        retryCount = 0
        attemptIndex = 0
        startAttempt()
    }
}

private struct JoyfulCredentials: Codable {
    let portal: String
    let username: String
    let password: String
    let expiresAt: Date
}

private enum SecureCredentialVault {
    private static let service = "com.joyful.tv.account"
    private static let account = "trial-login-v1"
    static func load() -> JoyfulCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let details = try? JSONDecoder().decode(JoyfulCredentials.self, from: data), details.expiresAt > Date() else {
            clear(); return nil
        }
        return details
    }
    static func save(_ credentials: JoyfulCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw JoyfulError.message("Could not save the account securely (\(added)).") }
        } else if status != errSecSuccess { throw JoyfulError.message("Could not update the secure account store (\(status)).") }
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

private enum JoyfulFavorites {
    static func key(account: JoyfulCredentials) -> String {
        let value = "\(account.portal.lowercased())\n\(account.username)\n\(account.password)"
        return "joyful.favorites." + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func load(account: JoyfulCredentials) -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key(account: account)) ?? []) }
    static func save(_ favorites: Set<String>, account: JoyfulCredentials) { UserDefaults.standard.set(Array(favorites), forKey: key(account: account)) }
}

private struct JoyfulChannel {
    let streamID: String
    let identity: String
    let name: String
    let categoryID: String
    let number: String
    let streamIcon: String
    let xmltvID: String
    let containerExtension: String
    let directSource: String
}

private struct TrialMailbox: Sendable {
    let id: String
    let address: String
    let token: String
}

private enum JoyfulError: LocalizedError {
    case warpLost
    case message(String)
    var errorDescription: String? {
        switch self {
        case .warpLost: return "WARP disconnected; the credential request was stopped."
        case .message(let text): return text
        }
    }
}

private enum MailTm {
    private static let root = URL(string: "https://api.mail.tm")!
    private static let pathCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func createMailbox() async throws -> TrialMailbox {
        let response = try await request(path: "/domains")
        guard let rows = collectionRows(from: response) else {
            throw JoyfulError.message("Mail.tm returned an unexpected domain list.")
        }
        let domains = rows.compactMap { row -> String? in
            guard row["isActive"] as? Bool == true, row["isPrivate"] as? Bool != true else { return nil }
            return row["domain"] as? String
        }
        guard let domain = domains.first else { throw JoyfulError.message("Mail.tm has no active public domains available right now.") }

        let localPart = "joyful" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let address = "\(localPart)@\(domain)"
        let password = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let body = ["address": address, "password": password]

        let accountResponse = try await request(path: "/accounts", method: "POST", body: body)
        guard let account = accountResponse as? [String: Any], let accountID = account["id"] as? String else {
            throw JoyfulError.message("Mail.tm created an account but returned no account ID.")
        }
        let tokenResponse = try await request(path: "/token", method: "POST", body: body)
        guard let token = (tokenResponse as? [String: Any])?["token"] as? String, !token.isEmpty else {
            throw JoyfulError.message("Mail.tm did not return an access token.")
        }
        return TrialMailbox(id: accountID, address: address, token: token)
    }

    static func deleteMailbox(_ mailbox: TrialMailbox) async {
        guard let id = mailbox.id.addingPercentEncoding(withAllowedCharacters: pathCharacters) else { return }
        _ = try? await request(path: "/accounts/\(id)", method: "DELETE", token: mailbox.token, timeout: 8)
    }

    static func waitForMessage(mailbox: TrialMailbox, excluding: String, label: String, warpIsReady: () -> Bool, progress: @escaping (String) -> Void) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            guard warpIsReady() else { throw JoyfulError.warpLost }
            let response = try await request(path: "/messages", token: mailbox.token)
            guard let rows = collectionRows(from: response) else {
                throw JoyfulError.message("Mail.tm returned an unexpected message list.")
            }
            for summary in rows {
                try Task.checkCancellation()
                guard warpIsReady() else { throw JoyfulError.warpLost }
                let id = summary["id"] as? String ?? ""
                guard !id.isEmpty, id != excluding,
                      let escaped = id.addingPercentEncoding(withAllowedCharacters: pathCharacters) else { continue }
                let full = try await request(path: "/messages/\(escaped)", token: mailbox.token)
                guard var object = full as? [String: Any] else { throw JoyfulError.message("Mail.tm returned an invalid email message.") }
                if object["id"] == nil { object["id"] = id }
                return object
            }
            progress("WARP is on · Waiting for \(label)…")
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw JoyfulError.message("No \(label) arrived within five minutes.")
    }

    private static func collectionRows(from response: Any) -> [[String: Any]]? {
        if let object = response as? [String: Any], let members = object["hydra:member"] as? [Any] {
            return members.compactMap { $0 as? [String: Any] }
        }
        if let array = response as? [Any] {
            return array.compactMap { $0 as? [String: Any] }
        }
        return nil
    }

    static func verificationURL(from message: [String: Any]) -> URL? {
        let html = htmlBody(from: message)
        let text = message["text"] as? String ?? ""
        let pattern = #"https?://[^\s<>\"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let value = html + "\n" + text
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: range) {
            guard let matchRange = Range(match.range, in: value), let url = URL(string: String(value[matchRange]).replacingOccurrences(of: "&amp;", with: "&")), let host = url.host?.lowercased() else { continue }
            let validHost = host == "joyful.watch" || host.hasSuffix(".joyful.watch") || host == "list-manage.com" || host.hasSuffix(".list-manage.com") || host == "mailchi.mp" || host.hasSuffix(".mailchi.mp")
            let lower = url.absoluteString.lowercased()
            if validHost && ["verify", "confirm", "activate", "validation", "verification"].contains(where: lower.contains) { return url }
        }
        return nil
    }

    static func messageText(_ message: [String: Any]) -> String {
        if let text = message["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        let html = htmlBody(from: message)
        let withCellSeparators = html.replacingOccurrences(of: #"(?i)</td>\s*<td[^>]*>"#, with: "\t", options: .regularExpression)
        let withLineBreaks = withCellSeparators.replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|tr|li|h[1-6])>"#, with: "\n", options: .regularExpression)
        let plain = withLineBreaks.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return plain.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    static func extractCredentials(_ text: String) throws -> (portal: String, username: String, password: String) {
        let usernameLabels = "(?:username|user\\s*name|user\\s*id|user|login(?:\\s*(?:name|id))?|account(?:\\s*(?:name|id))?)"
        let passwordLabels = "(?:password|pass\\s*word|passcode)"
        let portalLabels = "(?:portal\\s*(?:url|link)|portalurl)"
        let allLabels = "(?:\(usernameLabels)|\(passwordLabels)|\(portalLabels))"
        let user = extractLabeledValue(text, labels: usernameLabels, allLabels: allLabels)
        let password = extractLabeledValue(text, labels: passwordLabels, allLabels: allLabels)
        let portal = extractLabeledValue(text, labels: portalLabels, allLabels: allLabels)
        guard let user, let password, let portal, let url = URL(string: portal), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw JoyfulError.message("The account email did not contain a complete portal, username, and password.") }
        return (portal, user, password)
    }

    private static func extractLabeledValue(_ body: String, labels: String, allLabels: String) -> String? {
        guard !body.isEmpty else { return nil }
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let linePattern = "(?im)^\\s*\\**\\s*(?:your\\s+)?" + labels + "\\s*\\**\\s*(?::|=|\\bis\\b|\\t+)\\s*([^\\r\\n]+)"
        var extracted: String?
        if let regex = try? NSRegularExpression(pattern: linePattern), let match = regex.firstMatch(in: body, range: range), let valueRange = Range(match.range(at: 1), in: body) {
            extracted = String(body[valueRange])
        } else {
            let compactPattern = "(?is)\\**\\s*(?:your\\s+)?" + labels + "\\**\\s*(?::|=|\\bis\\b|\\t+)\\s*(.+?)(?=\\s+(?:your\\s+)?" + allLabels + "\\s*\\**\\s*(?::|=|\\bis\\b|\\t+)|$)"
            if let regex = try? NSRegularExpression(pattern: compactPattern), let match = regex.firstMatch(in: body, range: range), let valueRange = Range(match.range(at: 1), in: body) {
                extracted = String(body[valueRange])
            }
        }
        guard var value = extracted else { return nil }
        value = value.replacingOccurrences(of: #"^[\s*]+|[\s*]+$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2 && ((value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("`") && value.hasSuffix("`"))) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.replacingOccurrences(of: #"(?i)\s+(?=(?:username|user\s*name|user\s*id|user|password|pass\s*word|passcode|portal\s*(?:url|link)|portalurl)\s*[:=]).*$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func htmlBody(from message: [String: Any]) -> String {
        if let html = message["html"] as? String { return html }
        if let htmlParts = message["html"] as? [String] { return htmlParts.joined(separator: "\n") }
        return ""
    }

    private static func request(path: String, method: String = "GET", token: String? = nil, body: [String: String]? = nil, timeout: TimeInterval = 25) async throws -> Any {
        guard let url = URL(string: path, relativeTo: root)?.absoluteURL, url.host == root.host else { throw JoyfulError.message("Invalid Mail.tm endpoint.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json, application/ld+json", forHTTPHeaderField: "Accept")
        request.setValue("JoyfulTV-iOS/2.32", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JoyfulError.message("Mail.tm returned a non-HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 { throw JoyfulError.message("Mail.tm rate limit reached. Please wait briefly, then retry.") }
            throw JoyfulError.message("Mail.tm API returned HTTP \(http.statusCode). Check network access and try again.")
        }
        guard data.count <= 10 * 1024 * 1024 else { throw JoyfulError.message("Mail.tm response was too large to process safely.") }
        if data.isEmpty { return NSNull() }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

private struct XtreamCatalog { let categories: [(id: String, name: String)]; let channels: [JoyfulChannel] }

private struct XtreamClient {
    let portal: String
    let username: String
    let password: String

    private var base: String {
        var value = portal.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"(?i)/player_api\.php/?$"#, with: "", options: .regularExpression)
        while value.hasSuffix("/") { value.removeLast() }
        guard var components = URLComponents(string: value), components.scheme?.lowercased() == "http" else { return value }
        if components.host?.lowercased() == "kytv.xyz" { return value }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.string ?? value
    }
    private func endpoint(action: String? = nil, streamID: String? = nil) throws -> URL {
        guard var components = URLComponents(string: base + "/player_api.php") else { throw JoyfulError.message("Invalid IPTV portal URL.") }
        var items = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        if let streamID { items.append(URLQueryItem(name: "stream_id", value: streamID)); items.append(URLQueryItem(name: "limit", value: "2")) }
        components.queryItems = items
        guard let url = components.url else { throw JoyfulError.message("Invalid IPTV request URL.") }
        return url
    }
    func loadLiveCatalog() async throws -> XtreamCatalog {
        let auth = try await getJSON(endpoint()) as? [String: Any]
        guard let userInfo = auth?["user_info"] as? [String: Any], (userInfo["auth"].map(String.init(describing:)) ?? "1") != "0" else { throw JoyfulError.message("The IPTV account was not accepted by the portal.") }
        guard let categoryRows = try await getJSON(endpoint(action: "get_live_categories")) as? [[String: Any]], let streamRows = try await getJSON(endpoint(action: "get_live_streams")) as? [[String: Any]] else { throw JoyfulError.message("The IPTV portal returned an invalid Live TV catalog.") }
        let cats = categoryRows.compactMap { row -> (id: String, name: String)? in
            guard let rawID = row["category_id"], let name = row["category_name"] as? String else { return nil }
            return (String(describing: rawID), name)
        }
        let items = streamRows.compactMap { row -> JoyfulChannel? in
            guard let rawID = row["stream_id"] ?? row["id"] else { return nil }
            let id = String(describing: rawID)
            guard !id.isEmpty else { return nil }
            let name = row["name"] as? String ?? "Channel \(id)"
            let category = row["category_id"].map(String.init(describing:)) ?? ""
            return JoyfulChannel(streamID: id, identity: id, name: name, categoryID: category, number: row["num"].map(String.init(describing:)) ?? "", streamIcon: row["stream_icon"] as? String ?? "", xmltvID: row["epg_channel_id"] as? String ?? row["xmltv_id"] as? String ?? "", containerExtension: row["container_extension"] as? String ?? "", directSource: row["direct_source"] as? String ?? "")
        }
        return XtreamCatalog(categories: cats, channels: items)
    }
    func streamURLs(for channel: JoyfulChannel, preferredExtension: String) -> [URL] {
        let pathCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedUser = username.addingPercentEncoding(withAllowedCharacters: pathCharacters),
              let encodedPass = password.addingPercentEncoding(withAllowedCharacters: pathCharacters) else { return [] }
        var urls: [URL] = []
        if let direct = normalizedDirectSource(channel.directSource) { urls.append(direct) }
        let alternate = preferredExtension.lowercased() == "ts" ? "m3u8" : "ts"
        let candidates = [preferredExtension, channel.containerExtension, alternate, "m3u8", "ts"]
        var seenExtensions = Set<String>()
        for candidate in candidates {
            let ext = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ext.range(of: #"^[a-z0-9]{2,8}$"#, options: .regularExpression) != nil,
                  seenExtensions.insert(ext).inserted,
                  let url = URL(string: "\(base)/live/\(encodedUser)/\(encodedPass)/\(channel.streamID).\(ext)"),
                  !urls.contains(where: { $0.absoluteString == url.absoluteString }) else { continue }
            urls.append(url)
        }
        return urls
    }

    private func normalizedDirectSource(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        if components.scheme?.lowercased() == "http" && host != "kytv.xyz" {
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
        }
        return components.url
    }
    func nowNext(streamID: String) async throws -> String? {
        let response = try await getJSON(endpoint(action: "get_short_epg", streamID: streamID))
        let rows = (response as? [String: Any])?["epg_listings"] as? [[String: Any]] ?? response as? [[String: Any]] ?? []
        guard let first = rows.first else { return nil }
        let value = first["title"] as? String ?? ""
        return value.isEmpty ? nil : value
    }
    private func getJSON(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw JoyfulError.message("The IPTV provider request failed.") }
        guard data.count <= 32 * 1024 * 1024 else { throw JoyfulError.message("The IPTV catalog response was too large.") }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
