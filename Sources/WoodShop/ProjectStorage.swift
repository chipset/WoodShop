import Foundation
import CryptoKit

/// Keep the last readable version before atomically replacing the working file.
enum ProjectStorage {
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func previousURL(_ url: URL) -> URL { url.appendingPathExtension("previous") }
    static func backupURLs(_ url: URL) -> [URL] { [previousURL(url),previousURL(url).appendingPathExtension("2"),previousURL(url).appendingPathExtension("3")] }
    static func write(_ data: Data, to url: URL, validatePrevious: (Data) throws -> Void) throws {
        try validatePrevious(data)
        if FileManager.default.fileExists(atPath:url.path) {
            let old = try Data(contentsOf:url)
            if (try? validatePrevious(old)) != nil {
                let backups = backupURLs(url)
                for i in stride(from:backups.count-1,through:1,by:-1) {
                    if let previous = try? Data(contentsOf:backups[i-1]),(try? validatePrevious(previous)) != nil { try previous.write(to:backups[i],options:.atomic) }
                }
                try old.write(to:backups[0],options:.atomic)
            }
        }
        try data.write(to:url,options:.atomic)
    }
    static func recovery(at url: URL) throws -> Document.Recovery {
        var failure: Error?
        for candidate in [url]+backupURLs(url) where FileManager.default.fileExists(atPath:candidate.path) {
            do {
                let recovery = try JSONDecoder().decode(Document.Recovery.self,from:Data(contentsOf:candidate))
                try ModelValidation.validate(recovery.project)
                return recovery
            } catch { failure = error }
        }
        throw failure ?? ModelValidation.Failure(message:"No unsaved recovery is available.")
    }
}
