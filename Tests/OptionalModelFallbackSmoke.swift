import Foundation

final class FallbackFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var paths: [String] = []
    static var primaryStatus = 503
    static let digest = String(repeating: "b", count: 64)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.paths.append(url.host!); let code = Self.primaryStatus; Self.lock.unlock()
        if url.host == "huggingface.co" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
        } else {
            let file: (String) -> [String: Any] = { name in
                ["Name":name,"Path":name,"Size":8,"Sha256":Self.digest,"Revision":String(repeating:"a",count:40)]
            }
            let result: [String: Any] = ["Success":true,"Data":["Files":[file("gemma-3-4b-it-Q4_K_M.gguf"),file("mmproj-model-f16.gguf")]]]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: result))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
@main struct OptionalModelFallbackSmoke {
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FallbackFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let spec = OptionalModelSpec.all[0]
        let manifest = try await OptionalModelCatalog.resolve(spec, session: session)
        precondition(manifest.source == .modelScope && manifest.files.count == 2)
        precondition(FallbackFixture.paths == ["huggingface.co","modelscope.cn"])
        let url = OptionalModelCatalog.downloadURL(manifest.files[0], manifest: manifest)
        precondition(url.host == "modelscope.cn" && url.path.contains(manifest.revision) && !url.path.contains("master"))
        let primary = OptionalModelManifest(modelID: manifest.modelID, repository: manifest.repository,
                                            revision: String(repeating:"c",count:40), files:manifest.files)
        try OptionalModelCatalog.assertSameFiles(primary, manifest)
        let wrong = OptionalModelManifest(modelID:manifest.modelID,repository:manifest.repository,revision:manifest.revision,
            files:[OptionalModelFile(name:manifest.files[0].name,bytes:9,sha256:FallbackFixture.digest),manifest.files[1]],source:.modelScope)
        do { try OptionalModelCatalog.assertSameFiles(primary,wrong); fatalError("不能换成不同文件") } catch is OptionalModelError { }
        precondition(OptionalModelCatalog.shouldFallback(URLError(.timedOut)))
        precondition(!OptionalModelCatalog.shouldFallback(URLError(.cancelled)))
        precondition(!OptionalModelCatalog.shouldFallback(URLError(.serverCertificateUntrusted)))
        precondition(!OptionalModelCatalog.shouldFallback(OptionalModelError.message("校验失败")))
        FallbackFixture.primaryStatus = 403; FallbackFixture.paths = []
        do { _ = try await OptionalModelCatalog.resolve(spec,session:session); fatalError("权限错误不能自动换源") } catch is OptionalModelError { }
        precondition(FallbackFixture.paths == ["huggingface.co"])
        let old: [String:Any] = ["modelID":primary.modelID,"repository":primary.repository,"revision":primary.revision,
            "files":primary.files.map { ["name":$0.name,"bytes":$0.bytes,"sha256":$0.sha256] as [String:Any] }]
        let restored = try JSONDecoder().decode(OptionalModelManifest.self, from:JSONSerialization.data(withJSONObject:old))
        precondition(restored.source == .huggingFace)
        print("PASS: HF失败自动转ModelScope/固定备用版本/配套校验/不一致拒绝/取消和权限不换源/旧清单兼容。")
    }
}
