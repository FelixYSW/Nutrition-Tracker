import Foundation

enum ImageStore {
    static func save(_ data: Data) throws -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FoodPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = UUID().uuidString + ".jpg"
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
        return filename
    }
    static func url(for filename: String) -> URL? {
        guard filename == (filename as NSString).lastPathComponent else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FoodPhotos", isDirectory: true).appendingPathComponent(filename)
    }
}
