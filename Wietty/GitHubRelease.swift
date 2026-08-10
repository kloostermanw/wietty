import Foundation

/// The subset of a GitHub `/releases/latest` payload the updater needs.
struct GitHubRelease: Equatable, Decodable {
    let tagName: String
    let name: String
    let body: String
    let htmlURL: URL
    let dmgAsset: Asset?

    struct Asset: Equatable {
        let name: String
        let downloadURL: URL
    }

    var version: AppVersion { AppVersion(tagName) }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
        case assets
    }

    private struct AssetDTO: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? tagName
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        let assets = try c.decodeIfPresent([AssetDTO].self, forKey: .assets) ?? []
        if let dmg = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
            dmgAsset = Asset(name: dmg.name, downloadURL: dmg.browserDownloadURL)
        } else {
            dmgAsset = nil
        }
    }
}
