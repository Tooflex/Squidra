/// Evidence for a model attempt's monetary amount. An estimate or historical
/// amount with unknown provenance must never be labeled a provider invoice.
public enum ModelCostBasis: String, Codable, Equatable, Sendable {
    case unspecified
    case providerReported = "provider_reported"
    case localZero = "local_zero"
    case publishedRateEstimate = "published_rate_estimate"

    public func validates(amount: Int64, rateID: String?) -> Bool {
        guard amount >= 0 else { return false }
        switch self {
        case .unspecified, .providerReported: return rateID == nil
        case .localZero: return amount == 0 && rateID == nil
        case .publishedRateEstimate:
            guard let rateID,(1...96).contains(rateID.utf8.count) else { return false }
            return rateID.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0)
            }
        }
    }
}
