import Foundation
import RoostKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Places grocery items the dictionary doesn't know using Apple's on-device
/// language model (iOS 26+, Apple Intelligence devices). Nothing leaves the phone.
enum SmartCategorizer {
    static func categorize(_ names: [String]) async -> [String: String]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await onDevice(names)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func onDevice(_ names: [String]) async -> [String: String]? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let keys = GroceryTaxonomy.bundled.categories.map(\.key)
        let instructions = "You sort grocery list items into supermarket aisles. Answer with exactly one aisle key from this list and nothing else: "
            + keys.joined(separator: ", ")
        var out: [String: String] = [:]
        for name in names.prefix(20) {
            let session = LanguageModelSession(instructions: instructions)
            guard let response = try? await session.respond(to: "Item: \(name)") else { continue }
            let answer = response.content.lowercased()
            if let key = keys.first(where: { answer.contains($0) }) { out[name] = key }
        }
        return out
    }
    #endif
}
