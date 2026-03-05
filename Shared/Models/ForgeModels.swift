import Foundation

// MARK: - Game

struct GameSummary: Codable, Identifiable {
    let id: String
    let userId: String
    let name: String
    var slug: String?
    var description: String?
    var visibility: String?
    var forkedFromId: String?
    var remixCount: Int?
    var tags: [String]?
    var thumbnailUrl: String?
    var publishedAt: String?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, slug, description, visibility
        case forkedFromId = "forked_from_id"
        case remixCount = "remix_count"
        case tags
        case thumbnailUrl = "thumbnail_url"
        case publishedAt = "published_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GameListResponse: Codable {
    let games: [GameSummary]
    let total: Int
}

// MARK: - Game Version

struct GameVersionFull: Codable {
    let id: String
    let gameId: String
    let version: Int
    let isCurrent: Bool
    var description: String?
    var graphData: [String: AnyCodable]?
    var configData: [String: AnyCodable]?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case gameId = "game_id"
        case version
        case isCurrent = "is_current"
        case description
        case graphData = "graph_data"
        case configData = "config_data"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct GameWithVersion: Codable {
    let game: GameSummary
    let version: GameVersionFull
}

// MARK: - World Setup Config (extracted from config_data)

struct WorldSetupConfig {
    var gameName: String = ""
    var cameraType: String = "side_scroll"
    var style: String = ""
    var character: String = ""
    var world: String = ""
    var actions: [GameAction] = []
    var motherKeyframeId: String?
    var motherKeyframeUrl: String?
    var actionDescriptions: [String: String] = [:]  // {action_name: "animation description"}
    var baseMovement: String = ""  // Continuous movement for cruise/idle nodes

    /// Build from the raw config_data dictionary.
    static func from(configData: [String: AnyCodable]?) -> WorldSetupConfig {
        guard let data = configData else { return WorldSetupConfig() }

        var config = WorldSetupConfig()

        if let ws = data["world_setup"]?.value as? [String: Any] {
            config.style = ws["style"] as? String ?? ""
            config.character = ws["character"] as? String ?? ""
            config.world = ws["world"] as? String ?? ""
            config.cameraType = ws["camera_type"] as? String ?? "side_scroll"
            config.motherKeyframeId = ws["mother_keyframe_id"] as? String
            config.motherKeyframeUrl = ws["mother_keyframe_url"] as? String
            config.baseMovement = ws["base_movement"] as? String ?? ""
            if let descs = ws["action_descriptions"] as? [String: String] {
                config.actionDescriptions = descs
            }
        }

        if let acts = data["actions"]?.value as? [[String: Any]] {
            config.actions = acts.compactMap { dict in
                guard let name = dict["name"] as? String else { return nil }
                return GameAction(name: name, keyBinding: dict["key_binding"] as? String)
            }
        }

        config.gameName = data["name"]?.value as? String ?? ""

        return config
    }

    /// Convert back to config_data patch for saving.
    func toConfigPatch() -> [String: Any] {
        var ws: [String: Any] = [
            "style": style,
            "character": character,
            "world": world,
            "camera_type": cameraType,
        ]
        if let kid = motherKeyframeId { ws["mother_keyframe_id"] = kid }
        if let kurl = motherKeyframeUrl { ws["mother_keyframe_url"] = kurl }
        if !baseMovement.isEmpty { ws["base_movement"] = baseMovement }
        if !actionDescriptions.isEmpty { ws["action_descriptions"] = actionDescriptions }

        let actionDicts: [[String: Any]] = actions.map { a in
            var d: [String: Any] = ["name": a.name]
            if let kb = a.keyBinding { d["key_binding"] = kb }
            return d
        }

        return [
            "name": gameName,
            "world_setup": ws,
            "actions": actionDicts,
        ]
    }
}

struct GameAction: Identifiable {
    let id = UUID()
    var name: String
    var keyBinding: String?
}

// MARK: - Build Status

struct BuildStatus: Codable {
    let status: String
    let stage: String?
    let log: String?
    let job: BuildJobProgress?
    let onnxJobId: String?

    enum CodingKeys: String, CodingKey {
        case status, stage, log, job
        case onnxJobId = "onnx_job_id"
    }
}

struct BuildJobProgress: Codable {
    let jobId: String
    let jobStatus: String
    var currentEpoch: Int?
    var totalEpochs: Int?
    var statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case jobStatus = "job_status"
        case currentEpoch = "current_epoch"
        case totalEpochs = "total_epochs"
        case statusMessage = "status_message"
    }
}

// MARK: - Remix

struct RemixStartResponse: Codable {
    let remixId: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case remixId = "remix_id"
        case status
    }
}

struct RemixStatus: Codable {
    let status: String
    let stage: String?
    let totalClips: Int?
    let completedClips: Int?
    let currentNode: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case status, stage, error
        case totalClips = "total_clips"
        case completedClips = "completed_clips"
        case currentNode = "current_node"
    }
}

// MARK: - Keyframe Analysis

struct KeyframeAnalysis: Codable {
    var style: String?
    var character: String?
    var world: String?
}

// MARK: - Asset Upload

struct AssetUploadWrapper: Codable {
    let asset: AssetUploadResponse
}

struct AssetUploadResponse: Codable {
    let id: String
    let name: String?
    let assetType: String?
    let storagePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case assetType = "asset_type"
        case storagePath = "storage_path"
    }
}

// MARK: - AnyCodable (type-erased Codable wrapper)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
