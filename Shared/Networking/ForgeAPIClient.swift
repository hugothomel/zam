import Foundation

/// Actor-based client for the Forge REST API. Injects JWT for authenticated requests.
actor ForgeAPIClient {
    private let baseURLString: String
    private let session: URLSession
    private let authManager: AuthManager

    static let defaultBaseURL = "https://nurturing-perfection-staging.up.railway.app/api"

    init(authManager: AuthManager, baseURL: String = ForgeAPIClient.defaultBaseURL) {
        self.authManager = authManager
        self.baseURLString = baseURL
        self.session = URLSession.shared
    }

    /// Build URL from path string without percent-encoding slashes or query params.
    private func makeURL(_ path: String) -> URL {
        URL(string: baseURLString + path)!
    }

    // MARK: - Games

    func forkGame(gameId: String) async throws -> GameSummary {
        try await post("/games/\(gameId)/fork")
    }

    func getGameVersion(gameId: String) async throws -> GameWithVersion {
        try await get("/games/\(gameId)/versions/current")
    }

    func saveGameVersion(
        gameId: String,
        configData: [String: Any],
        graphData: [String: Any]
    ) async throws {
        let body: [String: Any] = [
            "graph_data": graphData,
            "config_data": configData,
            "description": "Updated from Zam",
        ]
        try await postDiscarding("/games/\(gameId)/versions", jsonDict: body)
    }

    func submitBuild(gameId: String) async throws {
        try await postDiscarding("/games/\(gameId)/build")
    }

    func getBuildStatus(gameId: String) async throws -> BuildStatus {
        try await get("/games/\(gameId)/build/status")
    }

    func cancelBuild(gameId: String) async throws {
        try await postDiscarding("/games/\(gameId)/build/cancel")
    }

    func listUserGames() async throws -> GameListResponse {
        try await get("/games?visibility=all")
    }

    // MARK: - Remix

    func startRemix(gameId: String, config: WorldSetupConfig) async throws -> RemixStartResponse {
        var body: [String: Any] = [
            "style": config.style,
            "character": config.character,
            "world": config.world,
            "camera_type": config.cameraType,
            "actions": config.actions.map { ["name": $0.name, "key_binding": $0.keyBinding ?? ""] },
            "mother_keyframe_id": config.motherKeyframeId ?? "",
            "game_name": config.gameName,
            "auto_build": true,
        ]
        if !config.actionDescriptions.isEmpty {
            body["action_descriptions"] = config.actionDescriptions
        }
        if !config.baseMovement.isEmpty {
            body["base_movement"] = config.baseMovement
        }
        return try await post("/games/\(gameId)/remix", jsonDict: body)
    }

    func getRemixStatus(gameId: String) async throws -> RemixStatus {
        try await get("/games/\(gameId)/remix/status")
    }

    // MARK: - Assets

    func uploadKeyframe(imageData: Data, name: String = "mother_keyframe") async throws -> AssetUploadResponse {
        let url = makeURL("/assets/upload")
        var request = try authorizedRequest(url: url, method: "POST")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: "keyframe.jpg", contentType: "image/jpeg", data: imageData)
        body.appendMultipart(boundary: boundary, name: "name", value: name)
        body.appendMultipart(boundary: boundary, name: "asset_type", value: "keyframe")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        let wrapper = try JSONDecoder().decode(AssetUploadWrapper.self, from: data)
        return wrapper.asset
    }

    func analyzeKeyframe(imageData: Data) async throws -> KeyframeAnalysis {
        let url = makeURL("/clips/keyframe/analyze")
        var request = try authorizedRequest(url: url, method: "POST")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.appendMultipart(boundary: boundary, name: "image", filename: "keyframe.jpg", contentType: "image/jpeg", data: imageData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(KeyframeAnalysis.self, from: data)
    }

    func getAssetImageURL(assetId: String) -> URL {
        makeURL("/assets/\(assetId)/image")
    }

    // MARK: - Private Helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = makeURL(path)
        let request = try authorizedRequest(url: url, method: "GET")
        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, jsonDict: [String: Any]? = nil) async throws -> T {
        let url = makeURL(path)
        var request = try authorizedRequest(url: url, method: "POST")

        if let jsonDict {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonDict)
        }

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postDiscarding(_ path: String, jsonDict: [String: Any]? = nil) async throws {
        let url = makeURL(path)
        var request = try authorizedRequest(url: url, method: "POST")

        if let jsonDict {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonDict)
        }

        let (data, response) = try await session.data(for: request)
        try validateResponse(response, data: data)
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method

        if let token = authManager.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let userId = authManager.userId {
            request.setValue(userId, forHTTPHeaderField: "X-User-ID")
        }

        return request
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ForgeAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ForgeAPIError.httpError(statusCode: http.statusCode, body: body)
        }
    }
}

// MARK: - Errors

enum ForgeAPIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

// MARK: - Multipart Helpers

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
