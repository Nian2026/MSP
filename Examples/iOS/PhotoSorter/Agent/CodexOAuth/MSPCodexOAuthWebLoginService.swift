#if os(iOS)
import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
import UIKit
#else
import Foundation
#endif

struct MSPCodexOAuthLoginResult: Hashable, Sendable {
    var configuration: MSPCodexOAuthConfiguration
    var message: String
}

enum MSPCodexOAuthLoginError: LocalizedError {
    case invalidAuthorizeURL
    case webAuthenticationDidNotStart
    case missingCallbackURL
    case missingAuthorizationCode
    case stateMismatch
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case missingRefreshToken
    case callbackServerUnavailable
    case callbackServerFailed(String)
    case oauthCallbackError(String, String?)
    case loginCanceled

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizeURL:
            return "Codex OAuth 登录地址无效。"
        case .webAuthenticationDidNotStart:
            return "无法启动系统登录页面。"
        case .missingCallbackURL:
            return "登录页面没有返回回调地址。"
        case .missingAuthorizationCode:
            return "登录回调缺少 authorization code。"
        case .stateMismatch:
            return "登录回调校验失败，请重新登录。"
        case .invalidHTTPResponse:
            return "Codex OAuth 接口返回了无效 HTTP 响应。"
        case let .httpStatus(status, message):
            return message.isEmpty ? "Codex OAuth 接口返回 HTTP \(status)。" : message
        case .missingRefreshToken:
            return "当前 Codex OAuth 会话没有 refresh token，请重新登录。"
        case .callbackServerUnavailable:
            return "无法启动 Codex OAuth 本地回调服务。"
        case let .callbackServerFailed(message):
            return message.isEmpty ? "Codex OAuth 本地回调服务异常。" : message
        case let .oauthCallbackError(code, description):
            if let description, !description.isEmpty {
                return "Codex OAuth 登录失败：\(description)"
            }
            return "Codex OAuth 登录失败：\(code)"
        case .loginCanceled:
            return "已取消 Codex OAuth 登录。"
        }
    }
}

#if os(iOS)
@MainActor
final class MSPCodexOAuthWebLoginService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private static let issuer = "https://auth.openai.com"
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let callbackPath = "/auth/callback"
    private static let callbackPorts: [UInt16] = [1455, 1457]
    private static let authorizeScope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    private var activeSession: ASWebAuthenticationSession?
    private var activeCallbackServer: MSPCodexOAuthLoopbackCallbackServer?

    func startLogin(preserving existingConfiguration: MSPCodexOAuthConfiguration) async -> MSPCodexOAuthLoginResult {
        let pkce = Self.makePKCE()
        let state = Self.randomURLSafeString(byteCount: 32)
        let existingConfiguration = existingConfiguration.normalized()

        do {
            let callbackServer = try await MSPCodexOAuthLoopbackCallbackServer.start(
                ports: Self.callbackPorts,
                path: Self.callbackPath
            )
            activeCallbackServer = callbackServer
            defer {
                callbackServer.stop()
                if activeCallbackServer === callbackServer {
                    activeCallbackServer = nil
                }
            }

            let authorizeURL = try Self.authorizeURL(
                pkce: pkce,
                state: state,
                redirectURI: callbackServer.redirectURI
            )
            let callbackURL = try await authenticate(url: authorizeURL, callbackServer: callbackServer)
            let callback = try Self.parseCallbackURL(callbackURL, expectedState: state)
            let tokenResponse = try await exchangeAuthorizationCode(
                callback.code,
                pkce: pkce,
                redirectURI: callbackServer.redirectURI
            )
            let configuration = MSPCodexOAuthConfiguration(
                idToken: tokenResponse.idToken,
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken,
                accountID: "",
                email: "",
                planType: "",
                lastLoginStatus: .signedIn,
                lastStatusMessage: "Codex OAuth 已登录。",
                lastCheckedAt: .now
            ).applyingTokenMetadata()
            return MSPCodexOAuthLoginResult(
                configuration: configuration,
                message: configuration.email.isEmpty
                    ? "Codex OAuth 已登录。"
                    : "Codex OAuth 已登录：\(configuration.email)"
            )
        } catch {
            let isCanceled = Self.isLoginCanceled(error)
            var preserved = existingConfiguration
            preserved.lastLoginStatus = isCanceled
                ? (preserved.hasStoredCredential ? .signedIn : .signedOut)
                : .failed
            preserved.lastStatusMessage = isCanceled ? "已取消 Codex OAuth 登录。" : error.localizedDescription
            preserved.lastCheckedAt = .now
            return MSPCodexOAuthLoginResult(
                configuration: preserved,
                message: preserved.lastStatusMessage
            )
        }
    }

    func refreshAccessToken(using configuration: MSPCodexOAuthConfiguration) async -> MSPCodexOAuthConfiguration {
        let normalized = configuration.normalized()
        guard normalized.hasRefreshToken else {
            return normalized
        }

        do {
            let response = try await requestRefresh(refreshToken: normalized.refreshToken)
            let updated = MSPCodexOAuthConfiguration(
                idToken: response.idToken ?? normalized.idToken,
                accessToken: response.accessToken ?? normalized.accessToken,
                refreshToken: response.refreshToken ?? normalized.refreshToken,
                accountID: normalized.accountID,
                email: normalized.email,
                planType: normalized.planType,
                lastLoginStatus: .signedIn,
                lastStatusMessage: "Codex OAuth 会话已刷新。",
                lastCheckedAt: .now
            ).applyingTokenMetadata()
            return updated
        } catch {
            return MSPCodexOAuthConfiguration(
                idToken: normalized.idToken,
                accessToken: normalized.accessToken,
                refreshToken: normalized.refreshToken,
                accountID: normalized.accountID,
                email: normalized.email,
                planType: normalized.planType,
                lastLoginStatus: .failed,
                lastStatusMessage: error.localizedDescription,
                lastCheckedAt: .now
            )
        }
    }

    func cancelLogin() {
        activeSession?.cancel()
        activeSession = nil
        activeCallbackServer?.stop()
        activeCallbackServer = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = windowScenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? windowScenes.flatMap(\.windows).first {
            return window
        }
        if let windowScene = windowScenes.first {
            return ASPresentationAnchor(windowScene: windowScene)
        }
        preconditionFailure("MSPCodexOAuthWebLoginService requires an active window scene.")
    }

    private func authenticate(
        url: URL,
        callbackServer: MSPCodexOAuthLoopbackCallbackServer
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            let callbackTask = Task {
                try await callbackServer.waitForCallback()
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: "http"
                ) { [weak self] callbackURL, error in
                    Task { @MainActor in
                        self?.activeSession = nil
                    }

                    if let error {
                        callbackServer.fail(with: error)
                        return
                    }
                    guard let callbackURL else {
                        callbackServer.fail(with: MSPCodexOAuthLoginError.missingCallbackURL)
                        return
                    }
                    callbackServer.complete(with: callbackURL)
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                activeSession = session
                guard session.start() else {
                    activeSession = nil
                    callbackServer.fail(with: MSPCodexOAuthLoginError.webAuthenticationDidNotStart)
                    continuation.resume(throwing: MSPCodexOAuthLoginError.webAuthenticationDidNotStart)
                    return
                }
                continuation.resume()
            }

            do {
                let callbackURL = try await callbackTask.value
                activeSession?.cancel()
                activeSession = nil
                return callbackURL
            } catch {
                activeSession?.cancel()
                activeSession = nil
                throw error
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelLogin()
            }
        }
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        pkce: PKCECodes,
        redirectURI: String
    ) async throws -> TokenResponse {
        guard let url = URL(string: "\(Self.issuer)/oauth/token") else {
            throw MSPCodexOAuthLoginError.invalidAuthorizeURL
        }
        let body = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", Self.clientID),
            ("code_verifier", pkce.verifier)
        ]
            .map { "\($0)=\(Self.formEscaped($1))" }
            .joined(separator: "&")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await sendTokenRequest(request)
    }

    private func requestRefresh(refreshToken: String) async throws -> RefreshResponse {
        guard let url = URL(string: "\(Self.issuer)/oauth/token") else {
            throw MSPCodexOAuthLoginError.invalidAuthorizeURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
        return try await sendRefreshRequest(request)
    }

    private func sendTokenRequest(_ request: URLRequest) async throws -> TokenResponse {
        let data = try await send(request)
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func sendRefreshRequest(_ request: URLRequest) async throws -> RefreshResponse {
        let data = try await send(request)
        return try JSONDecoder().decode(RefreshResponse.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MSPCodexOAuthLoginError.invalidHTTPResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw MSPCodexOAuthLoginError.httpStatus(httpResponse.statusCode, message)
        }
        return data
    }

    private static func authorizeURL(
        pkce: PKCECodes,
        state: String,
        redirectURI: String
    ) throws -> URL {
        var components = URLComponents(string: "\(issuer)/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: authorizeScope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "codex_cli_rs")
        ]
        guard let url = components?.url else {
            throw MSPCodexOAuthLoginError.invalidAuthorizeURL
        }
        return url
    }

    private static func parseCallbackURL(
        _ url: URL,
        expectedState: String
    ) throws -> (code: String, state: String) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let state = queryItems.first(where: { $0.name == "state" })?.value ?? ""
        guard state == expectedState else {
            throw MSPCodexOAuthLoginError.stateMismatch
        }
        if let errorCode = queryItems.first(where: { $0.name == "error" })?.value,
           !errorCode.isEmpty {
            let errorDescription = queryItems.first(where: { $0.name == "error_description" })?.value
            throw MSPCodexOAuthLoginError.oauthCallbackError(errorCode, errorDescription)
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw MSPCodexOAuthLoginError.missingAuthorizationCode
        }
        return (code, state)
    }

    private static func isLoginCanceled(_ error: Error) -> Bool {
        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
            return true
        }
        if let loginError = error as? MSPCodexOAuthLoginError,
           case .loginCanceled = loginError {
            return true
        }
        return false
    }

    private static func makePKCE() -> PKCECodes {
        let verifier = randomURLSafeString(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return PKCECodes(verifier: verifier, challenge: challenge)
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            bytes = (0 ..< byteCount).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func formEscaped(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct PKCECodes: Hashable {
    var verifier: String
    var challenge: String
}

private final class MSPCodexOAuthLoopbackCallbackServer: @unchecked Sendable {
    let redirectURI: String

    private let listener: NWListener
    private let path: String
    private let port: UInt16
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var callbackResult: Result<URL, Error>?

    static func start(ports: [UInt16], path: String) async throws -> MSPCodexOAuthLoopbackCallbackServer {
        var lastError: Error?
        for port in ports {
            do {
                let server = try MSPCodexOAuthLoopbackCallbackServer(port: port, path: path)
                try await server.start()
                return server
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw MSPCodexOAuthLoginError.callbackServerUnavailable
    }

    private init(port: UInt16, path: String) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MSPCodexOAuthLoginError.callbackServerUnavailable
        }
        self.port = port
        self.path = path
        queue = DispatchQueue(label: "com.modelshellproxy.photosorter.codex-oauth-callback.\(port)")
        listener = try NWListener(using: .tcp, on: nwPort)
        redirectURI = "http://localhost:\(port)\(path)"
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let startup = MSPCodexOAuthStartupContinuation(continuation)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    startup.resume()
                case let .failed(error):
                    let callbackError = MSPCodexOAuthLoginError.callbackServerFailed(error.localizedDescription)
                    startup.resume(throwing: callbackError)
                    self.fail(with: callbackError)
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let callbackResult {
                lock.unlock()
                continuation.resume(with: callbackResult)
                return
            }
            callbackContinuation = continuation
            lock.unlock()
        }
    }

    func complete(with url: URL) {
        finish(.success(url))
    }

    func fail(with error: Error) {
        finish(.failure(error))
    }

    func stop() {
        listener.cancel()
        finish(.failure(MSPCodexOAuthLoginError.loginCanceled))
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receiveRequest(from: connection)
    }

    private func receiveRequest(from connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.sendHTTPResponse(
                    statusCode: 400,
                    body: self.errorHTML("Codex OAuth callback read failed: \(error.localizedDescription)"),
                    connection: connection
                )
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            let headerTerminator = Data("\r\n\r\n".utf8)
            if nextBuffer.range(of: headerTerminator) != nil {
                self.handleRequest(nextBuffer, connection: connection)
                return
            }
            if isComplete || nextBuffer.count > 16_384 {
                self.sendHTTPResponse(
                    statusCode: 400,
                    body: self.errorHTML("Bad Codex OAuth callback request."),
                    connection: connection
                )
                return
            }
            self.receiveRequest(from: connection, buffer: nextBuffer)
        }
    }

    private func handleRequest(_ data: Data, connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            sendHTTPResponse(
                statusCode: 400,
                body: errorHTML("Bad Codex OAuth callback request."),
                connection: connection
            )
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2,
              let callbackURL = callbackURL(from: parts[1]) else {
            sendHTTPResponse(
                statusCode: 400,
                body: errorHTML("Bad Codex OAuth callback request."),
                connection: connection
            )
            return
        }

        guard callbackURL.path == path else {
            sendHTTPResponse(
                statusCode: 404,
                body: errorHTML("Not Found"),
                connection: connection
            )
            return
        }

        let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hasCode = queryItems.contains { $0.name == "code" && !($0.value ?? "").isEmpty }
        let errorCode = queryItems.first(where: { $0.name == "error" })?.value ?? ""
        let body = hasCode && errorCode.isEmpty
            ? successHTML()
            : errorHTML(errorCode.isEmpty ? "Codex OAuth callback is missing an authorization code." : errorCode)
        sendHTTPResponse(
            statusCode: hasCode && errorCode.isEmpty ? 200 : 400,
            body: body,
            connection: connection
        ) { [weak self] in
            self?.complete(with: callbackURL)
        }
    }

    private func callbackURL(from target: String) -> URL? {
        if let absoluteURL = URL(string: target),
           absoluteURL.scheme != nil {
            return absoluteURL
        }
        return URL(string: "http://localhost:\(port)\(target)")
    }

    private func sendHTTPResponse(
        statusCode: Int,
        body: String,
        connection: NWConnection,
        completion: (() -> Void)? = nil
    ) {
        let reason = Self.reasonPhrase(for: statusCode)
        let bodyData = Data(body.utf8)
        var response = Data(
            """
            HTTP/1.1 \(statusCode) \(reason)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(bodyData.count)\r
            Connection: close\r
            \r

            """.utf8
        )
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    private func successHTML() -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Codex 登录完成</title>
          <style>
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: -apple-system-body; color: #0d0d0d; background: #fff; }
            main { width: min(520px, calc(100vw - 48px)); text-align: center; }
            h1 { font-size: 24px; line-height: 1.25; margin: 0 0 12px; }
            p { color: #666; line-height: 1.5; margin: 0; }
          </style>
        </head>
        <body><main><h1>Codex 登录完成</h1><p>可以回到 app 继续使用。</p></main></body>
        </html>
        """
    }

    private func errorHTML(_ message: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Codex 登录未完成</title>
          <style>
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: -apple-system-body; color: #0d0d0d; background: #fff; }
            main { width: min(520px, calc(100vw - 48px)); text-align: center; }
            h1 { font-size: 24px; line-height: 1.25; margin: 0 0 12px; }
            p { color: #666; line-height: 1.5; margin: 0; word-break: break-word; }
          </style>
        </head>
        <body><main><h1>Codex 登录未完成</h1><p>\(Self.htmlEscaped(message))</p></main></body>
        </html>
        """
    }

    private func finish(_ result: Result<URL, Error>) {
        var continuation: CheckedContinuation<URL, Error>?
        lock.lock()
        if callbackResult == nil {
            callbackResult = result
            continuation = callbackContinuation
            callbackContinuation = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 404:
            return "Not Found"
        default:
            return "OK"
        }
    }

    private static func htmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private final class MSPCodexOAuthStartupContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        resume(with: .success(()))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        var continuation: CheckedContinuation<Void, Error>?
        lock.lock()
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct TokenResponse: Decodable {
    var idToken: String
    var accessToken: String
    var refreshToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct RefreshResponse: Decodable {
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#else
@MainActor
final class MSPCodexOAuthWebLoginService {
    func startLogin(preserving existingConfiguration: MSPCodexOAuthConfiguration) async -> MSPCodexOAuthLoginResult {
        var configuration = existingConfiguration.normalized()
        configuration.lastLoginStatus = .failed
        configuration.lastStatusMessage = "Codex OAuth web login is only available on iOS."
        configuration.lastCheckedAt = .now
        return MSPCodexOAuthLoginResult(
            configuration: configuration,
            message: "Codex OAuth web login is only available on iOS."
        )
    }

    func refreshAccessToken(using configuration: MSPCodexOAuthConfiguration) async -> MSPCodexOAuthConfiguration {
        configuration.normalized()
    }

    func cancelLogin() {}
}
#endif
