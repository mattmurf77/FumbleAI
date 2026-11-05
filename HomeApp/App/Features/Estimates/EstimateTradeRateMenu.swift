import SwiftUI
import HomeCore

struct EstimateTradeRateMenu: View {
    let mode: Chore.WorkMode
    let kind: WorkEstimateLine.Kind
    let unit: String
    let currency: String
    let country: String?
    let select: (EstimateTradeRate) -> Void
    @State private var guide: EstimateTradeRate?

    var body: some View {
        if EstimateTradeRate.available(mode: mode, kind: kind, unit: unit, currency: currency, country: country) {
            Menu("Use a U.S. hourly rate") {
                ForEach(EstimateTradeRate.options) { rate in
                    Button {
                        guide = rate
                        select(rate)
                    } label: {
                        Text("\(rate.title) · \(rate.low.formatted(showCents: false))–\(rate.high.formatted(showCents: false))/hr")
                    }
                }
            }
            .accessibilityIdentifier("estimate.item.tradeRate")
            if let guide {
                Link("Read the \(guide.publisher) guide", destination: guide.article)
                Text("Checked \(EstimateTradeRate.checked). " + EstimateTradeRate.terms)
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
