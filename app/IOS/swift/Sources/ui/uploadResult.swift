import Foundation

// Equivalente ao sealed class UploadResult do Kotlin
enum UploadResult: Equatable {
    case idle
    case loading
    case success(response: PredictionResponse)
    case error(message: String)

    static func == (lhs: UploadResult, rhs: UploadResult) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading):       return true
        case (.success(let a), .success(let b)):         return a == b
        case (.error(let a), .error(let b)):             return a == b
        default:                                          return false
        }
    }
}