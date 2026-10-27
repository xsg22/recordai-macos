import Foundation

struct OptionalModelSpec: Identifiable, Sendable {
    let id: String
    let name: String
    let repository: String
    let estimatedDownload: String
    let recommendedMemoryGB: Int
    static let all: [Self] = [
        .init(id: "gemma-3-4b-it-q4", name: "Gemma 3 4B · 文本与图片", repository: "ggml-org/gemma-3-4b-it-GGUF", estimatedDownload: "约 4 GB，实际大小以下载清单为准", recommendedMemoryGB: 16),
        .init(id: "gemma-3-12b-it-q4", name: "Gemma 3 12B · 文本与图片", repository: "ggml-org/gemma-3-12b-it-GGUF", estimatedDownload: "约 10 GB，实际大小以下载清单为准", recommendedMemoryGB: 32)
    ]
}

struct OptionalModelFile: Codable, Sendable {
    let name: String
    let bytes: Int64
    let sha256: String
}
enum OptionalModelSource: String, Codable, Sendable {
    case huggingFace, modelScope
    var displayName: String { self == .huggingFace ? "Hugging Face" : "ModelScope" }
}
struct OptionalModelManifest: Codable, Sendable {
    let modelID: String
    let repository: String
    let revision: String
    let files: [OptionalModelFile]
    let source: OptionalModelSource
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    init(modelID: String, repository: String, revision: String, files: [OptionalModelFile], source: OptionalModelSource = .huggingFace) {
        self.modelID = modelID; self.repository = repository; self.revision = revision; self.files = files; self.source = source
    }
    enum CodingKeys: String, CodingKey { case modelID, repository, revision, files, source }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try values.decode(String.self, forKey: .modelID)
        repository = try values.decode(String.self, forKey: .repository)
        revision = try values.decode(String.self, forKey: .revision)
        files = try values.decode([OptionalModelFile].self, forKey: .files)
        source = try values.decodeIfPresent(OptionalModelSource.self, forKey: .source) ?? .huggingFace
    }
}
enum OptionalModelError: LocalizedError {
    case message(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .http(let code): return "模型来源请求失败（HTTP \(code)）。"
        }
    }
}

enum OptionalModelCatalog {
    /// 只取官方llama.cpp文档列出的ggml-org仓库，按发布commit固定两个配套文件。
    static func resolve(_ spec: OptionalModelSpec, session: URLSession = .shared,
                        onFallback: @Sendable () -> Void = {}) async throws -> OptionalModelManifest {
        do {
            let url = URL(string: "https://huggingface.co/api/models/" + spec.repository + "?blobs=true")!
            return try parse(await fetch(url, session: session), spec: spec)
        } catch {
            guard shouldFallback(error) else { throw error }
            try Task.checkCancellation()
            onFallback()
            return try await resolveModelScope(spec, session: session)
        }
    }

    static func shouldFallback(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let network = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost,
                    .notConnectedToInternet, .secureConnectionFailed].contains(network.code)
        }
        if case let OptionalModelError.http(code) = error { return code == 404 || code == 408 || code == 429 || code >= 500 }
        // 校验失败、拒绝授权、证书不可信与未知清单不通过换源掩盖。
        return false
    }
    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OptionalModelError.message("模型站点返回无效响应。") }
        guard http.statusCode == 200 else { throw OptionalModelError.http(http.statusCode) }
        return data
    }
    static func resolveModelScope(_ spec: OptionalModelSpec, session: URLSession = .shared) async throws -> OptionalModelManifest {
        let url = URL(string: "https://modelscope.cn/api/v1/models/" + spec.repository + "/repo/files?Revision=master&Recursive=true")!
        return try parseModelScope(await fetch(url, session: session), spec: spec)
    }
    static func parseModelScope(_ data: Data, spec: OptionalModelSpec) throws -> OptionalModelManifest {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["Success"] as? Bool != false,
              let body = root["Data"] as? [String: Any], let all = body["Files"] as? [[String: Any]] else {
            throw OptionalModelError.message("ModelScope模型清单无效。")
        }
        let text = all.filter { ($0["Name"] as? String)?.lowercased().hasSuffix("-q4_k_m.gguf") == true }
        let vision = all.filter {
            guard let name = $0["Name"] as? String else { return false }
            return name.lowercased().hasPrefix("mmproj-") && name.lowercased().hasSuffix("-f16.gguf")
        }
        guard text.count == 1, vision.count == 1 else { throw OptionalModelError.message("ModelScope未找到唯一配套文本和图片权重。") }
        let selected = text + vision
        guard let revision = selected[0]["Revision"] as? String,
              revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              selected.allSatisfy({ $0["Revision"] as? String == revision }) else {
            throw OptionalModelError.message("ModelScope配套文件版本不一致，下载已停止。")
        }
        let files = try selected.map { value -> OptionalModelFile in
            guard let name = value["Name"] as? String,
                  name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
                  value["Path"] as? String == name,
                  let digest = value["Sha256"] as? String,
                  digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let size = (value["Size"] as? NSNumber)?.int64Value, size > 0, size < 30_000_000_000 else {
                throw OptionalModelError.message("ModelScope清单缺少可靠大小/校验值或文件路径不安全。")
            }
            return OptionalModelFile(name: name, bytes: size, sha256: digest)
        }
        return OptionalModelManifest(modelID: spec.id, repository: spec.repository, revision: revision, files: files, source: .modelScope)
    }
    static func assertSameFiles(_ primary: OptionalModelManifest, _ backup: OptionalModelManifest) throws {
        guard primary.modelID == backup.modelID, primary.repository == backup.repository,
              primary.files.count == backup.files.count,
              primary.files.allSatisfy({ file in backup.files.contains { $0.name == file.name && $0.bytes == file.bytes && $0.sha256 == file.sha256 } }) else {
            throw OptionalModelError.message("ModelScope备用文件与已选版本不一致，已停止切换来源。")
        }
    }
    static func parse(_ data: Data, spec: OptionalModelSpec) throws -> OptionalModelManifest {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = root["sha"] as? String, revision.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              let siblings = root["siblings"] as? [[String: Any]] else { throw OptionalModelError.message("模型版本清单无效。") }
        let text = siblings.filter { ($0["rfilename"] as? String)?.lowercased().hasSuffix("-q4_k_m.gguf") == true }
        let vision = siblings.filter {
            guard let name = $0["rfilename"] as? String else { return false }
            return name.lowercased().hasPrefix("mmproj-") && name.lowercased().hasSuffix("-f16.gguf")
        }
        guard text.count == 1, vision.count == 1 else {
            throw OptionalModelError.message("没有找到唯一配套的 Q4_K_M 文本模型与 F16 图片模型，已停止下载以免装错文件。")
        }
        let files = try (text + vision).map { value -> OptionalModelFile in
            guard let name = value["rfilename"] as? String,
                  name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
                  let lfs = value["lfs"] as? [String: Any], let digest = lfs["sha256"] as? String ?? lfs["oid"] as? String,
                  digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let size = (lfs["size"] as? NSNumber)?.int64Value, size > 0, size < 30_000_000_000 else {
                throw OptionalModelError.message("模型清单缺少大小或 SHA-256，无法安全安装。")
            }
            return OptionalModelFile(name: name, bytes: size, sha256: digest)
        }
        return OptionalModelManifest(modelID: spec.id, repository: spec.repository, revision: revision, files: files)
    }
    static func downloadURL(_ file: OptionalModelFile, manifest: OptionalModelManifest) -> URL {
        let base = manifest.source == .huggingFace ? "https://huggingface.co/" : "https://modelscope.cn/models/"
        return URL(string: base + manifest.repository + "/resolve/" + manifest.revision + "/" + file.name)!
    }
}
