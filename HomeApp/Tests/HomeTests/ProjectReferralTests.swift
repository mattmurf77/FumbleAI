import XCTest
@testable import Home

final class ProjectReferralTests: XCTestCase {
    func testOnlyShowConfiguredDisclosedSecurePartners() {
        var info = ["HomeContractorPartnerName": "Test company", "HomeContractorPartnerURL": "https://example.com/quote?campaign=project"]
        XCTAssertNil(ProjectReferral(kind: "Contractor", info: info))
        info["HomeContractorPartnerDisclosure"] = "Example referral disclosure"
        XCTAssertEqual(ProjectReferral(kind: "Contractor", info: info)?.url.absoluteString, info["HomeContractorPartnerURL"])
        info["HomeContractorPartnerURL"] = "https://user:password@example.com/"
        XCTAssertNil(ProjectReferral(kind: "Contractor", info: info))
        info["HomeContractorPartnerURL"] = "http://example.com/"
        XCTAssertNil(ProjectReferral(kind: "Contractor", info: info))
        XCTAssertNil(ProjectReferral(kind: "Financing", info: [:]))
    }
}
