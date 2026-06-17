import Foundation

// Equivalente ao sealed class UploadResult do Kotlin
enum UploadResult: Equatable {
    case idle
    case loading
    case success(classification: String, confidence: Double)
    case error(message: String)

    static func == (lhs: UploadResult, rhs: UploadResult) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):       return true
        case (.success(let a, _), .success(let b, _)):   return a == b
        case (.error(let a), .error(let b)):             return a == b
        default:                                          return false
        }
    }
}