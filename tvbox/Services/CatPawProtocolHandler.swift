import Foundation

/// CatPaw 协议处理器 - 集成 CatPawOpen 的协议解析能力
/// 支持 index.js.md5 格式和标准 JSON/XML 数据源
/// Type 5 专门用于 CatPawOpen 协议处理
@MainActor
class CatPawProtocolHandler {
    static let shared = CatPawProtocolHandler()
    
    private let network = NetworkManager.shared
    
    private init() {}
    
    // MARK: - 协议处理主方法
    
    /// 处理 CatPawOpen 数据源 (Type 5)
    /// 支持三种格式:
    /// 1. http://host:port/index.js.md5 (CatPawOpen Node.js 服务)
    /// 2. 标准 JSON 数据源
    /// 3. 标准 XML 数据源
    func processSource(url sourceUrl: String) async throws -> ProcessedSource {
        guard !sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatPawError.invalidSourceUrl("源地址不能为空")
        }
        
        // 检查是否是 CatPawOpen Node.js 服务
        if sourceUrl.contains("index.js.md5") || sourceUrl.contains("index.js") {
            return try await processCatPawOpenService(sourceUrl)
        }
        
        // 优先尝试 JSON，其次是 XML 格式
        do {
            return try await processJSONSource(sourceUrl)
        } catch {
            do {
                return try await processXMLSource(sourceUrl)
            } catch {
                throw CatPawError.parseError("无法解析数据源，已尝试 CatPawOpen 服务、JSON 和 XML 格式")
            }
        }
    }
    
    // MARK: - CatPawOpen 服务处理
    
    /// 处理 CatPawOpen Node.js 服务 (index.js.md5)
    /// 该服务返回配置格式，需要解析其中的 video.sites 数据
    private func processCatPawOpenService(_ serviceUrl: String) async throws -> ProcessedSource {
        // 将 index.js.md5 URL 转换为 /config 端点
        let configUrl = try buildCatPawConfigUrl(from: serviceUrl)
        
        let jsonContent = try await network.getString(from: configUrl)
        guard let jsonData = jsonContent.data(using: .utf8) else {
            throw CatPawError.decodingError("CatPawOpen 配置无法解码")
        }
        
        if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return try parseCatPawOpenConfig(json, originalUrl: serviceUrl)
        }
        
        throw CatPawError.parseError("无效的 CatPawOpen 配置格式")
    }
    
    /// 构建 CatPawOpen 服务的配置 URL
    /// 将 http://host:port/index.js.md5 转换为 http://host:port/config
    private func buildCatPawConfigUrl(from mdUrl: String) throws -> String {
        var url = mdUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 移除 index.js.md5 或 index.js 后缀，替换为 /config
        if url.contains("index.js.md5") {
            url = url.replacingOccurrences(of: "index.js.md5", with: "config")
        } else if url.hasSuffix("/index.js") {
            url = url.replacingOccurrences(of: "/index.js", with: "/config")
        } else if url.hasSuffix("/") {
            url += "config"
        } else {
            url += "/config"
        }
        
        return url
    }
    
    /// 解析 CatPawOpen 配置数据
    /// 配置包含 video/read/comic/music/pan 等多个分类
    private func parseCatPawOpenConfig(_ json: [String: Any], originalUrl: String) throws -> ProcessedSource {
        var allVideos: [CatPawVideo] = []
        
        // 优先解析 video 分类
        if let videoConfig = json["video"] as? [String: Any],
           let sites = videoConfig["sites"] as? [[String: Any]] {
            
            // 从 sites 中提取站点信息并转换为视频对象
            for site in sites {
                let siteKey = site["key"] as? String ?? ""
                let siteName = site["name"] as? String ?? ""
                let siteApi = site["api"] as? String ?? ""
                
                var video = CatPawVideo()
                video.id = siteKey
                video.name = siteName
                video.pic = site["pic"] as? String ?? ""
                video.note = siteName  // 站点名称作为备注
                
                // 附加字段
                if let siteUrl = site["url"] as? String {
                    video.des = siteUrl
                }
                
                if !video.id.isEmpty && !video.name.isEmpty {
                    allVideos.append(video)
                }
            }
        }
        
        // 如果 video 为空，尝试其他分类
        if allVideos.isEmpty {
            for (categoryKey, categoryValue) in json {
                if let categoryDict = categoryValue as? [String: Any],
                   let sites = categoryDict["sites"] as? [[String: Any]] {
                    
                    for site in sites {
                        let siteKey = site["key"] as? String ?? ""
                        let siteName = site["name"] as? String ?? ""
                        
                        var video = CatPawVideo()
                        video.id = siteKey
                        video.name = siteName
                        video.pic = site["pic"] as? String ?? ""
                        video.note = siteName
                        
                        if !video.id.isEmpty && !video.name.isEmpty {
                            allVideos.append(video)
                        }
                    }
                }
            }
        }
        
        // 将所有站点转换为分类
        let categories = allVideos.map { video in
            SourceCategory(id: video.id, name: video.name)
        }
        
        return ProcessedSource(
            sourceUrl: originalUrl,
            categories: categories,
            videos: allVideos,
            metadata: ["type": "catpawopen"]
        )
    }
    
    // MARK: - 协议具体处理逻辑
    
    /// 处理 JSON 类型数据源
    private func processJSONSource(_ sourceUrl: String) async throws -> ProcessedSource {
        let jsonContent = try await network.getString(from: sourceUrl)
        guard let jsonData = jsonContent.data(using: .utf8) else {
            throw CatPawError.decodingError("JSON 数据无法解码")
        }
        
        if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return try parseJSONToProcessedSource(json, originalUrl: sourceUrl)
        }
        
        throw CatPawError.parseError("无效的 JSON 格式")
    }
    
    /// 处理 XML 类型数据源
    private func processXMLSource(_ sourceUrl: String) async throws -> ProcessedSource {
        let xmlContent = try await network.getString(from: sourceUrl)
        return try parseXMLToProcessedSource(xmlContent, originalUrl: sourceUrl)
    }
    
    // MARK: - 数据格式转换
    
    /// 将 JSON 转换为处理后的源格式
    private func parseJSONToProcessedSource(_ json: [String: Any], originalUrl: String) throws -> ProcessedSource {
        // 解析分类
        var categories: [SourceCategory] = []
        if let classList = json["class"] as? [[String: Any]] {
            for cls in classList {
                if let id = cls["type_id"] as? String ?? String(describing: cls["type_id"] ?? ""),
                   let name = cls["type_name"] as? String {
                    categories.append(SourceCategory(id: id, name: name))
                }
            }
        }
        
        // 解析视频列表
        var videos: [CatPawVideo] = []
        if let list = json["list"] as? [[String: Any]] {
            for item in list {
                if let video = parseCatPawVideoFromJSON(item) {
                    videos.append(video)
                }
            }
        }
        
        // 提取元数据
        var metadata: [String: Any] = [:]
        if let page = json["page"] { metadata["page"] = page }
        if let pagecount = json["pagecount"] { metadata["pagecount"] = pagecount }
        if let total = json["total"] { metadata["total"] = total }
        
        return ProcessedSource(
            sourceUrl: originalUrl,
            categories: categories,
            videos: videos,
            metadata: metadata
        )
    }
    
    /// 将 XML 转换为处理后的源格式
    private func parseXMLToProcessedSource(_ xml: String, originalUrl: String) throws -> ProcessedSource {
        let categories = extractXMLCategories(from: xml)
        let videos = extractXMLVideos(from: xml)
        
        return ProcessedSource(
            sourceUrl: originalUrl,
            categories: categories,
            videos: videos,
            metadata: [:]
        )
    }
    
    // MARK: - JSON 解析工具
    
    /// 从 JSON 解析单个视频对象
    private func parseCatPawVideoFromJSON(_ json: [String: Any]) -> CatPawVideo? {
        let video = CatPawVideo(
            id: (json["vod_id"] as? String) ?? String(describing: json["vod_id"] ?? ""),
            name: json["vod_name"] as? String ?? "",
            pic: json["vod_pic"] as? String ?? "",
            note: json["vod_remarks"] as? String ?? ""
        )
        
        // 附加字段
        if let year = json["vod_year"] as? String { video.year = year }
        if let area = json["vod_area"] as? String { video.area = area }
        if let type = json["vod_type"] as? String { video.type = type }
        if let actor = json["vod_actor"] as? String { video.actor = actor }
        if let director = json["vod_director"] as? String { video.director = director }
        if let des = json["vod_content"] as? String { video.des = des }
        
        guard !video.id.isEmpty && !video.name.isEmpty else { return nil }
        return video
    }
    
    // MARK: - XML 解析工具
    
    /// 从 XML 提取分类信息
    private func extractXMLCategories(from xml: String) -> [SourceCategory] {
        var categories: [SourceCategory] = []
        let pattern = "<ty\\s+id=['\"]([^'\"]+)['\"][^>]*>([^<]+)</ty>"
        
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return categories }
        
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, range: range)
        
        for match in matches {
            guard match.numberOfRanges >= 3,
                  let idRange = Range(match.range(at: 1), in: xml),
                  let nameRange = Range(match.range(at: 2), in: xml) else {
                continue
            }
            
            let id = String(xml[idRange])
            let name = String(xml[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            categories.append(SourceCategory(id: id, name: name))
        }
        
        return categories
    }
    
    /// 从 XML 提取视频列表
    private func extractXMLVideos(from xml: String) -> [CatPawVideo] {
        var videos: [CatPawVideo] = []
        let pattern = "<video>\\s*<id>([^<]*)</id>\\s*<name><!\\[CDATA\\[(.+?)\\]\\]></name>\\s*<pic>([^<]*)</pic>\\s*<note><!\\[CDATA\\[(.+?)\\]\\]></note>"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else {
            return videos
        }
        
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, range: range)
        
        for match in matches {
            guard match.numberOfRanges >= 5 else { continue }
            
            var video = CatPawVideo()
            
            if let idRange = Range(match.range(at: 1), in: xml) {
                video.id = String(xml[idRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let nameRange = Range(match.range(at: 2), in: xml) {
                video.name = String(xml[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let picRange = Range(match.range(at: 3), in: xml) {
                video.pic = String(xml[picRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let noteRange = Range(match.range(at: 4), in: xml) {
                video.note = String(xml[noteRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            if !video.id.isEmpty && !video.name.isEmpty {
                videos.append(video)
            }
        }
        
        return videos
    }
    
    // MARK: - 工具方法
    
    /// 构建带查询参数的 URL
    func buildURL(base: String, queryParams: [String: String]) throws -> String {
        guard var components = URLComponents(string: base) else {
            throw CatPawError.invalidURL("无效的基础 URL")
        }
        
        var queryItems: [URLQueryItem] = components.queryItems ?? []
        for (key, value) in queryParams {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems
        
        guard let url = components.url else {
            throw CatPawError.invalidURL("无法构建 URL")
        }
        
        return url.absoluteString
    }
}

// MARK: - 数据模型

/// 处理后的数据源
struct ProcessedSource {
    let sourceUrl: String
    let categories: [SourceCategory]
    let videos: [CatPawVideo]
    let metadata: [String: Any]
}

/// 分类信息
struct SourceCategory: Codable {
    let id: String
    let name: String
}

/// CatPawOpen 视频对象
struct CatPawVideo: Codable {
    var id: String = ""
    var name: String = ""
    var pic: String = ""
    var note: String = ""
    var year: String? = nil
    var area: String? = nil
    var type: String? = nil
    var actor: String? = nil
    var director: String? = nil
    var des: String? = nil
    
    init() {}
    
    init(id: String, name: String, pic: String, note: String) {
        self.id = id
        self.name = name
        self.pic = pic
        self.note = note
    }
}

// MARK: - 错误定义

enum CatPawError: LocalizedError {
    case invalidSourceUrl(String)
    case decodingError(String)
    case parseError(String)
    case invalidURL(String)
    case runtimeNotAvailable(String)
    case scriptExecutionError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidSourceUrl(let msg):
            return "无效的源地址: \(msg)"
        case .decodingError(let msg):
            return "数据解码失败: \(msg)"
        case .parseError(let msg):
            return "数据解析失败: \(msg)"
        case .invalidURL(let msg):
            return "URL 构建失败: \(msg)"
        case .runtimeNotAvailable(let msg):
            return msg
        case .scriptExecutionError(let msg):
            return "脚本执行失败: \(msg)"
        }
    }
}
