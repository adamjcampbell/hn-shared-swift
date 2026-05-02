import Foundation

public struct City: Sendable, Identifiable, Codable, Equatable {
    public let id: String
    public let name: String
    public let country: String

    public init(id: String, name: String, country: String) {
        self.id = id
        self.name = name
        self.country = country
    }
}

extension Array where Element == City {
    static let demoData: [City] = [
        City(id: "syd", name: "Sydney", country: "Australia"),
        City(id: "mel", name: "Melbourne", country: "Australia"),
        City(id: "tyo", name: "Tokyo", country: "Japan"),
        City(id: "nyc", name: "New York", country: "USA"),
        City(id: "lon", name: "London", country: "UK"),
        City(id: "par", name: "Paris", country: "France"),
    ]
}
