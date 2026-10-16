// Joyful TV iOS port. WireGuardKit/WireGuardNetworkExtension remain under their upstream MIT license.
import UIKit
import WebKit
import AVKit
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
    private let warpTunnelName = "JoyfulWARP"
    private var didStart = false
    private var warpStartInProgress = false
    private var warpReady = false
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
        // No signup, mailbox, or IPTV request is allowed until the profile is connected.
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

        statusLabel.text = "Preparing secure connection…"
        statusLabel.textColor = UIColor(white: 0.86, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityLabel = "Connection and app status"

        progressView.progressTintColor = accent
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.16)
        progressView.isHidden = true

        configureButton(actionButton, title: "Request TV login", action: #selector(primaryAction))
        configureButton(retryButton, title: "Retry secure connection", action: #selector(retryStartup))
        configureButton(categoryButton, title: "All channels  ▾", action: #selector(chooseCategory))
        configureButton(favoritesButton, title: "My Channels", action: #selector(toggleFavorites))
        configureButton(refreshButton, title: "Refresh", action: #selector(refreshCatalog))
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
        renewButton.isHidden = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = navy
        tableView.separatorColor = UIColor.white.withAlphaComponent(0.12)
        tableView.rowHeight = 68
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityLabel = "Live TV channels"
        tableView.isHidden = true

        header.axis = .vertical
        header.spacing = 9
        header.alignment = .fill
        header.addArrangedSubview(title)
        header.addArrangedSubview(statusLabel)
        header.addArrangedSubview(progressView)
        header.addArrangedSubview(actionButton)
        header.addArrangedSubview(retryButton)
        header.addArrangedSubview(renewButton)
        header.addArrangedSubview(mailTmAttributionButton)

        controls.axis = .horizontal
        controls.spacing = 7
        controls.distribution = .fillEqually
        controls.addArrangedSubview(categoryButton)
        controls.addArrangedSubview(favoritesButton)
        controls.addArrangedSubview(refreshButton)

        content.axis = .vertical
        content.spacing = 8
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
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            tableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
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

    // MARK: WARP gate

    private func beginStartupGate() {
        guard !warpStartInProgress else { return }
        warpStartInProgress = true
        didStart = false
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
        gateTask?.cancel()
        statusLabel.text = message
        progressView.isHidden = true
        actionButton.isHidden = true
        retryButton.isHidden = false
        tableView.isHidden = true
        searchBar.isHidden = true
        categoryButton.isHidden = true
        favoritesButton.isHidden = true
        refreshButton.isHidden = true
        trialTask?.cancel()
    }

    @objc private func retryStartup() { beginStartupGate() }

    @objc private func vpnStatusChanged() {
        guard let manager = tunnelsManager else { return }
        manager.refreshStatuses()
        if manager.tunnel(named: warpTunnelName)?.status == .inactive, warpReady {
            warpReady = false
            trialTask?.cancel()
            warpStartFailed("WARP disconnected. Further credential and IPTV requests are blocked until it reconnects.")
        }
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
            warpStartFailed("WARP is not connected. No mailbox or IPTV credentials were requested.")
            return
        }
        trialTask?.cancel()
        discardMailbox()
        trialStage = .idle
        progressView.isHidden = false
        progressView.setProgress(0.38, animated: true)
        actionButton.isHidden = true
        retryButton.isHidden = true
        statusLabel.text = "WARP is on. Creating your temporary mailbox…"
        trialTask = Task { [weak self] in
            guard let self else { return }
            var createdMailbox: TrialMailbox?
            do {
                let mailbox = try await MailTm.createMailbox()
                createdMailbox = mailbox
                self.temporaryMailbox = mailbox
                try Task.checkCancellation()
                guard self.warpReady else { throw JoyfulError.warpLost }
                self.mailboxAddress = mailbox.address
                self.trialStage = .openingForm
                self.statusLabel.text = "WARP is on. Opening the trial form for \(mailbox.address)…"
                self.hiddenWebView.load(URLRequest(url: URL(string: "https://joyful.watch/trial/")!))
            } catch is CancellationError {
                if let createdMailbox {
                    if self.temporaryMailbox?.id == createdMailbox.id { self.discardMailbox() }
                    else { Task { await MailTm.deleteMailbox(createdMailbox) } }
                }
            } catch {
                if let createdMailbox {
                    if self.temporaryMailbox?.id == createdMailbox.id { self.discardMailbox() }
                    else { Task { await MailTm.deleteMailbox(createdMailbox) } }
                }
                self.showTrialFailure("Could not create the temporary inbox: \(error.localizedDescription)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch trialStage {
        case .openingForm:
            guard warpReady else { warpStartFailed("WARP disconnected before the signup. No credentials were requested."); return }
            submitTrialForm(in: webView)
        case .confirming:
            guard warpReady else { warpStartFailed("WARP disconnected before credentials were fetched."); return }
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
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else { return }
            guard self.warpReady else { self.warpStartFailed("WARP disconnected before credentials were fetched."); return }
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
        guard warpReady else { warpStartFailed("WARP disconnected. No credentials were fetched."); return }
        trialTask?.cancel()
        guard let mailbox = temporaryMailbox else {
            showTrialFailure("The temporary mailbox is no longer available. Please try again.")
            return
        }
        trialTask = Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await MailTm.waitForMessage(mailbox: mailbox, excluding: excludedID, label: label, warpIsReady: { self.warpReady }, progress: { [weak self] text in
                    DispatchQueue.main.async { self?.statusLabel.text = text }
                })
                try Task.checkCancellation()
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
        Task { await MailTm.deleteMailbox(mailbox) }
    }

    private func showTrialFailure(_ message: String) {
        progressView.isHidden = true
        statusLabel.text = "\(message)\nWARP must remain connected before trying again."
        actionButton.setTitle("Try again", for: .normal)
        actionButton.isHidden = false
        retryButton.isHidden = true
    }

    @objc private func primaryAction() {
        guard warpReady else { beginStartupGate(); return }
        actionButton.setTitle("Request TV login", for: .normal)
        startTrial()
    }
    @objc private func renewLogin() { startTrial() }
    @objc private func openMailTmWebsite() {
        guard let url = URL(string: "https://mail.tm") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: IPTV

    private func loadCatalog() async {
        guard warpReady else { warpStartFailed("WARP disconnected. IPTV requests were stopped."); return }
        guard let credentials else { return }
        progressView.isHidden = false
        progressView.setProgress(0.55, animated: true)
        statusLabel.text = "WARP is on. Loading live channels…"
        do {
            let result = try await XtreamClient(portal: credentials.portal, username: credentials.username, password: credentials.password).loadLiveCatalog()
            guard warpReady else { throw JoyfulError.warpLost }
            categories = result.categories
            channels = result.channels
            favoriteIDs = JoyfulFavorites.load(account: credentials)
            applyFilters()
            tableView.isHidden = false
            searchBar.isHidden = false
            categoryButton.isHidden = false
            favoritesButton.isHidden = false
            refreshButton.isHidden = false
            renewButton.isHidden = false
            actionButton.isHidden = true
            retryButton.isHidden = true
            statusLabel.text = "WARP is on · \(channels.count) live channels · Login expires \(Self.expiryText(credentials.expiresAt))"
            progressView.setProgress(1, animated: true)
            progressView.isHidden = true
        } catch {
            progressView.isHidden = true
            let networkError = error as NSError
            if networkError.domain == NSURLErrorDomain && [-1022, -1200, -1201, -1202].contains(networkError.code) {
                let portalURL = URLComponents(string: credentials.portal)
                let portalHost = portalURL?.host ?? "the IPTV portal"
                if portalURL?.scheme?.lowercased() == "http" {
                    statusLabel.text = "Could not connect to \(portalHost) over HTTPS. The account email supplied an HTTP portal; iOS blocks HTTP login connections. The app tried HTTPS. If this host is HTTP-only, send its hostname for a one-host exception."
                } else {
                    statusLabel.text = "Could not establish a secure connection to \(portalHost). Ask the provider for a working HTTPS portal."
                }
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

    @objc private func refreshCatalog() {
        guard warpReady else { warpStartFailed("WARP must be connected before refreshing Live TV."); return }
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
        guard warpReady, let credentials else { warpStartFailed("WARP disconnected. Playback was blocked."); return }
        let channel = visibleChannels[indexPath.row]
        guard let streamURL = XtreamClient(portal: credentials.portal, username: credentials.username, password: credentials.password).streamURL(for: channel, extension: currentStream) else {
            statusLabel.text = "Channel has no playable stream URL."; return
        }
        fetchEpg(for: channel)
        let player = AVPlayer(url: streamURL)
        let controller = AVPlayerViewController()
        controller.player = player
        controller.title = channel.name
        controller.entersFullScreenWhenPlaybackBegins = true
        controller.exitsFullScreenWhenPlaybackEnds = true
        present(controller, animated: true) { player.play() }
    }

    private func fetchEpg(for channel: JoyfulChannel) {
        guard warpReady, let credentials else { return }
        epgTask?.cancel()
        if let cached = epgCache[channel.identity] { statusLabel.text = "WARP is on · Now: \(cached)"; return }
        epgTask = Task {
            do {
                let title = try await XtreamClient(portal: credentials.portal, username: credentials.username, password: credentials.password).nowNext(streamID: channel.streamID)
                guard warpReady else { throw JoyfulError.warpLost }
                if let title { epgCache[channel.identity] = title; statusLabel.text = "WARP is on · Now: \(title)"; tableView.reloadData() }
            } catch { /* Guide metadata is optional; playback continues. */ }
        }
    }

    // MARK: Orientation / helper methods

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.width > view.bounds.height, view.bounds.width > 600 {
            controls.axis = .vertical
            controls.distribution = .fill
        } else {
            controls.axis = .horizontal
            controls.distribution = .fillEqually
        }
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
            return JoyfulChannel(streamID: id, identity: id, name: name, categoryID: category, number: row["num"].map(String.init(describing:)) ?? "", streamIcon: row["stream_icon"] as? String ?? "", xmltvID: row["epg_channel_id"] as? String ?? row["xmltv_id"] as? String ?? "")
        }
        return XtreamCatalog(categories: cats, channels: items)
    }
    func streamURL(for channel: JoyfulChannel, extension ext: String) -> URL? {
        let pathCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encodedUser = username.addingPercentEncoding(withAllowedCharacters: pathCharacters),
              let encodedPass = password.addingPercentEncoding(withAllowedCharacters: pathCharacters) else { return nil }
        return URL(string: "\(base)/live/\(encodedUser)/\(encodedPass)/\(channel.streamID).\(ext)")
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
