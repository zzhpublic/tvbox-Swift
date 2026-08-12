import Foundation
import JavaScriptCore

/// CatPaw 协议处理器 - 集成 CatPawOpen 的协议解析能力
/// 支持 index.js.md5 格式和标准 JSON/XML 数据源
/// Type 5 专门用于 CatPawOpen 协议处理
@MainActor
class CatPawProtocolHandler {
    static let shared = CatPawProtocolHandler()
    
    private let network = NetworkManager.shared
    

    
    private init() {}
    
    // MARK: - 源类型识别
    
    /// 数据源类型
    enum SourceType {
        case standard      // 普通 TVBox 源
        case catpawopen    // CatPawOpen 服务
        case unknown       // 未知
    }
    
    /// 先通过 URL 特征识别源类型
    func identifySourceTypeByUrl(url: String) -> SourceType {
        let trimmed = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 特征 1: 检查已知的 CatPawOpen 特殊路径
        if trimmed.contains("index.js.md5") {
            return .catpawopen
        }
        
        
        
        return .unknown
    }
    
    /// 再通过响应内容验证源类型（精确识别）
    func identifySourceByResponse(url: String) async throws -> SourceType {
        // 先进行快速的 URL 识别
        let urlHint = identifySourceTypeByUrl(url: url)
        
        // 如果 URL 特征明确指向 CatPawOpen，直接返回
        if urlHint == .catpawopen {
            return .catpawopen
        }
        
        // 对于 .unknown 或 .standard，需要通过响应内容验证
        do {
            let testUrl = urlHint == .catpawopen ? 
                try buildCatPawConfigUrl(from: url) : url
            
            let jsonContent = try await network.getString(from: testUrl)
            guard let jsonData = jsonContent.data(using: .utf8) else {
                return .unknown
            }
            
            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // 检查 CatPawOpen 特有的响应结构
                // CatPawOpen 配置包含 video, read, comic, music, pan 等多个分类
                let catpawKeys = ["video", "read", "comic", "music", "pan"]
                let hasMultipleCategories = catpawKeys.filter { json[$0] != nil }.count >= 2
                
                if hasMultipleCategories {
                    // 这是 CatPawOpen 配置格式
                    return .catpawopen
                }
                
                // 检查标准 TVBox 结构
                if json["class"] != nil && json["list"] != nil {
                    return .standard
                }
                
                // 如果只有一个分类（如只有 video），判断其内部结构
                if json["video"] != nil && json["class"] == nil {
                    // 可能是 CatPawOpen 的 video 分类
                    if let videoConfig = json["video"] as? [String: Any],
                       videoConfig["sites"] != nil {
                        return .catpawopen
                    }
                }
            }
        } catch {
            // 网络错误或 JSON 解析失败
            // 如果 URL 本身有 CatPawOpen 特征，仍然返回 .catpawopen
            if urlHint == .catpawopen {
                return .catpawopen
            }
        }
        
        return .unknown
    }
    
    // MARK: - 协议处理主方法
    
    /// 智能处理 CatPawOpen 数据源 (Type 5)
    /// 自动识别源类型并调用相应的处理方法
    func processSource(url sourceUrl: String) async throws -> ProcessedSource {
        guard !sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatPawError.invalidSourceUrl("源地址不能为空")
        }
        
        // 智能识别源类型
        let sourceType = try await identifySourceByResponse(url: sourceUrl)
        
        switch sourceType {
        case .catpawopen:
            return try await processCatPawOpenService(sourceUrl)
        case .standard:
            // 优先尝试 JSON，其次是 XML 格式
            do {
                return try await processJSONSource(sourceUrl)
            } catch {
                do {
                    return try await processXMLSource(sourceUrl)
                } catch {
                    throw CatPawError.parseError("无法解析数据源，已尝试 JSON 和 XML 格式")
                }
            }
        case .unknown:
            // 未知格式，尝试所有方式
            do {
                return try await processCatPawOpenService(sourceUrl)
            } catch {
                do {
                    return try await processJSONSource(sourceUrl)
                } catch {
                    do {
                        return try await processXMLSource(sourceUrl)
                    } catch {
                        throw CatPawError.parseError("无法解析数据源，已尝试 CatPawOpen、JSON 和 XML 格式")
                    }
                }
            }
        }
    }
    
    // MARK: - CatPawOpen 服务处理
    
    /// 处理 CatPawOpen Node.js 服务 (index.js.md5)
    /// 该服务返回配置格式，需要解析其中的 video.sites / sites.list 数据
    private func processCatPawOpenService(_ serviceUrl: String) async throws -> ProcessedSource {
        // 将 index.js.md5 URL 转换为 /config 端点
        let configUrl = try buildCatPawConfigUrl(from: serviceUrl)
        
        let rawContent = try await network.getString(from: configUrl)
        guard !rawContent.isEmpty else {
            throw CatPawError.decodingError("CatPawOpen 配置响应为空")
        }

        // 尝试直接 JSON 解析（纯 JSON 格式）
        if let jsonData = rawContent.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return try parseCatPawOpenConfig(json, originalUrl: serviceUrl)
        }

        // 响应为 JavaScript 代码（CommonJS module），用 JavaScriptCore 提取默认导出对象
        if let json = extractJSDefaultExport(from: rawContent) {
            return try parseCatPawOpenConfig(json, originalUrl: serviceUrl)
        }

        throw CatPawError.parseError("无效的 CatPawOpen 配置格式")
    }

    /// 从 CommonJS JavaScript 源码中提取默认导出对象
    /// 支持 `var xxx_default = { ... }` 和 `module.exports = { ... }` 两种常见格式
    private func extractJSDefaultExport(from jsSource: String) -> [String: Any]? {
        // 方式一：用 JavaScriptCore 执行脚本，读取导出值
        if let result = extractViaJavaScriptCore(jsSource) {
            return result
        }
        // 方式二：Regex 兜底——提取 var xxx_default = { ... } 的对象文字量，再转 JSON
        return extractViaRegex(jsSource)
    }

    /// 用 JavaScriptCore 执行 CommonJS 脚本并提取导出对象
    private func extractViaJavaScriptCore(_ jsSource: String) -> [String: Any]? {
        guard let context = JSContext() else { return nil }

        // 提供最小化的 CommonJS 运行时 shim
        let shimScript = """
        var module = { exports: {} };
        var exports = module.exports;
        var __defProp = Object.defineProperty;
        var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
        var __getOwnPropNames = Object.getOwnPropertyNames;
        var __hasOwnProp = Object.prototype.hasOwnProperty;
        var __export = function(target, all) {
          for (var name in all) {
            __defProp(target, name, { get: all[name], enumerable: true });
          }
        };
        var __copyProps = function(to, from, except, desc) {
          if (from && typeof from === 'object' || typeof from === 'function') {
            for (var key of __getOwnPropNames(from)) {
              if (!__hasOwnProp.call(to, key) && key !== except) {
                __defProp(to, key, { get: function() { return from[key]; }, enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
              }
            }
          }
          return to;
        };
        var __toCommonJS = function(mod) {
          return __copyProps(__defProp({}, '__esModule', { value: true }), mod);
        };
        """
        context.evaluateScript(shimScript)
        context.evaluateScript(jsSource)

        guard context.exception == nil else { return nil }

        // 取 module.exports 的 default 属性（或直接 module.exports）
        let exportsVal = context.evaluateScript("JSON.stringify(module.exports.default || module.exports)")
        guard let jsonStr = exportsVal?.toString(), !jsonStr.isEmpty, jsonStr != "undefined" else {
            return nil
        }
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// 用正则提取 JS 中 `var xxx_default = { ... }` 块并转 JSON
    private func extractViaRegex(_ jsSource: String) -> [String: Any]? {
        // 找到默认变量赋值的起始位置
        let marker = "_default = "
        guard let markerRange = jsSource.range(of: marker) else { return nil }
        let objStart = jsSource.index(markerRange.upperBound, offsetBy: 0)
        guard jsSource[objStart] == "{" else { return nil }

        // 括号匹配提取完整 JS 对象文字量
        var depth = 0
        var objEnd = objStart
        for idx in jsSource.indices[objStart...] {
            let ch = jsSource[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 { objEnd = idx; break }
            }
        }
        guard depth == 0 else { return nil }

        let jsObj = String(jsSource[objStart...objEnd])

        // 将 JS 对象键（未加引号）转换为合法 JSON 键
        guard let keyQuoted = quoteJSObjectKeys(jsObj),
              let data = keyQuoted.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// 将 JS 对象文字量中未加引号的键名加上双引号，使其成为合法 JSON
    private func quoteJSObjectKeys(_ js: String) -> String? {
        // 匹配 {, 或换行后的 标识符键: 形式（不含字符串值中的冒号）
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<=[{,\n\r])\s*([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
            options: []
        ) else { return nil }

        var result = js
        var offset = 0
        let nsStr = js as NSString
        let matches = regex.matches(in: js, range: NSRange(js.startIndex..., in: js))

        for match in matches {
            guard match.numberOfRanges >= 2,
                  let keyRange = Range(match.range(at: 1), in: result) else { continue }

            let key = String(result[keyRange])
            // 跳过已是合法值的内容（避免误替换）
            let replacement = "\"\(key)\""
            let shiftedStart = result.index(keyRange.lowerBound, offsetBy: 0)
            result.replaceSubrange(keyRange, with: replacement)
            // 每次替换后偏移量自动跟踪（直接在原 result 上操作，range 已失效，需重新计算）
            _ = offset // suppress warning; offset unused because we work on `result` directly
        }

        // 由于直接替换导致后续 range 失效，改用 NSRegularExpression replacementString 方式重做
        let template = #"$0"#
        let fullRange = NSRange(js.startIndex..., in: js)
        // 用单次 replacingMatches 替换所有匹配
        guard let regex2 = try? NSRegularExpression(
            pattern: #"(?<=[{,\n\r])\s*([A-Za-z_][A-Za-z0-9_]*)(\s*):"#,
            options: []
        ) else { return nil }

        let quoted = regex2.stringByReplacingMatches(
            in: js,
            range: fullRange,
            withTemplate: #" "$1"$2:"#
        )
        return quoted
    }
    
    /// 构建 CatPawOpen 服务的配置 URL
    /// 将 http://host:port/index.js.md5 转换为 http://host:port/config
    private func buildCatPawConfigUrl(from mdUrl: String) throws -> String {
        var url = mdUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 移除 index.js.md5 或 index.js 后缀，替换为 /config
        if url.contains("index.js.md5") {
            url = url.replacingOccurrences(of: "index.js.md5", with: "index.config.js")
        } 
        
        return url
    }
    
    /// 解析 CatPawOpen 配置数据
    /// 兼容两种格式：
    ///   - 旧格式：json["video"]["sites"] → [[key, name, api, type, ...]]
    ///   - 新格式：json["sites"]["list"] → [[key, name, api, type, ...]]
    private func parseCatPawOpenConfig(_ json: [String: Any], originalUrl: String) throws -> ProcessedSource {
        var allVideos: [CatPawVideo] = []

        // --- 新格式：sites.list ---
        if let sitesDict = json["sites"] as? [String: Any],
           let list = sitesDict["list"] as? [[String: Any]], !list.isEmpty {
            for site in list {
                if let video = parseSiteToVideo(site) { allVideos.append(video) }
            }
        }

        // --- 旧格式：video.sites ---
        if allVideos.isEmpty,
           let videoConfig = json["video"] as? [String: Any],
           let sites = videoConfig["sites"] as? [[String: Any]] {
            for site in sites {
                if let video = parseSiteToVideo(site) { allVideos.append(video) }
            }
        }

        // --- 兜底：遍历所有顶层字典键中的 sites / list 数组 ---
        if allVideos.isEmpty {
            for (_, categoryValue) in json {
                if let categoryDict = categoryValue as? [String: Any] {
                    let sites = (categoryDict["sites"] as? [[String: Any]])
                             ?? (categoryDict["list"] as? [[String: Any]])
                             ?? []
                    for site in sites {
                        if let video = parseSiteToVideo(site) { allVideos.append(video) }
                    }
                }
            }
        }

        let categories = allVideos.map { SourceCategory(id: $0.id, name: $0.name) }
        return ProcessedSource(
            sourceUrl: originalUrl,
            categories: categories,
            videos: allVideos,
            metadata: ["type": "catpawopen"]
        )
    }

    /// 将站点字典转换为 CatPawVideo
    private func parseSiteToVideo(_ site: [String: Any]) -> CatPawVideo? {
        let siteKey = site["key"] as? String ?? ""
        let siteName = site["name"] as? String ?? ""
        guard !siteKey.isEmpty && !siteName.isEmpty else { return nil }

        var video = CatPawVideo()
        video.id = siteKey
        video.name = siteName
        video.pic = site["pic"] as? String ?? ""
        video.note = siteName
        if let siteUrl = site["url"] as? String { video.des = siteUrl }
        if let siteApi = site["api"] as? String { video.actor = siteApi }
        return video
    }
    
    // MARK: - 标准源处理逻辑
    
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
                    let id = cls["type_id"] as? String ?? String(describing: cls["type_id"] ?? "")
                    let name = cls["type_name"]  as? String ?? String(describing: cls["type_name"] ?? "")

                    categories.append(SourceCategory(id: id, name: name))
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
        var video = CatPawVideo(
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
    
    /// 从 XML 提取分类��息
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
