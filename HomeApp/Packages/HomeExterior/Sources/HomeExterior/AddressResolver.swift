import Foundation
import PlanKit
import HomeCore
#if canImport(MapKit)
import MapKit
#endif

public enum AddressError: Error, Hashable, Sendable {
    /// MapKit unavailable (Linux tests).
    case unavailable
    /// "We couldn't find that address. Check it or set up the yard by hand."
    case notFound
}

/// Typed address with autocomplete (FR-PLN-02, FR-EXT-02): `MKLocalSearchCompleter` for suggestions,
/// `MKLocalSearch` to resolve. No location permission is requested; only the typed text goes to Apple Maps.
public struct AddressResolver: AddressResolving {
    public init() {}

    public func suggestions(for query: String) async throws -> [AddressSuggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 3 else { return [] }
        #if canImport(MapKit)
        return try await CompleterBox.shared.complete(q)
        #else
        throw AddressError.unavailable
        #endif
    }

    public func resolve(_ query: String) async throws -> ResolvedAddress {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw AddressError.notFound }
        #if canImport(MapKit)
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        request.resultTypes = [.address]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw AddressError.notFound }
        let pm = item.placemark
        let line = [pm.subThoroughfare, pm.thoroughfare].compactMap { $0 }.joined(separator: " ")
        let address = PostalAddressLite(line: line.isEmpty ? (item.name ?? q) : line, locality: pm.locality,
                                        region: pm.administrativeArea, postalCode: pm.postalCode, countryCode: pm.isoCountryCode)
        let coord = GeoCoordinate(latitude: pm.coordinate.latitude, longitude: pm.coordinate.longitude)
        let display = address.singleLine.isEmpty ? q : address.singleLine
        return ResolvedAddress(address: address, coordinate: coord, displayName: display)
        #else
        throw AddressError.unavailable
        #endif
    }
}

#if canImport(MapKit)
/// One shared completer; a newer query supersedes (and empties) an in-flight one.
@MainActor
final class CompleterBox: NSObject, MKLocalSearchCompleterDelegate {
    static let shared = CompleterBox()
    private let completer = MKLocalSearchCompleter()
    private var continuation: CheckedContinuation<[AddressSuggestion], Error>?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .address
    }

    func complete(_ query: String) async throws -> [AddressSuggestion] {
        continuation?.resume(returning: [])
        continuation = nil
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            completer.queryFragment = query
        }
    }

    // The completer lives on the main actor, so its delegate callbacks arrive on the main thread.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            let results = completer.results.prefix(8).map { AddressSuggestion(title: $0.title, subtitle: $0.subtitle) }
            continuation?.resume(returning: Array(results))
            continuation = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
#endif
