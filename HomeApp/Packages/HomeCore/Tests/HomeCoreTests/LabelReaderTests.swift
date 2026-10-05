import XCTest
@testable import HomeCore

final class LabelReaderTests: XCTestCase {
    let today = LocalDate(2026, 10, 5)

    func testFridgeRatingPlate() {
        let lines = [
            "Whirlpool",
            "REFRIGERATOR-FREEZER / RÉFRIGÉRATEUR-CONGÉLATEUR",
            "MODEL NO./NO DE MODÈLE: WRF555SDFZ00",
            "SERIAL NO./NO DE SÉRIE: K91234567",
            "115V 60HZ 6.5A",
            "REFRIGERANT R134a 4.5 OZ",
            "MFG DATE 03/2019",
            "Whirlpool Corporation Benton Harbor, MI 49022 U.S.A.",
        ]
        let g = LabelReader.read(lines: lines, today: today)
        XCTAssertEqual(g.brand, "Whirlpool")
        XCTAssertEqual(g.model, "WRF555SDFZ00")
        XCTAssertEqual(g.serial, "K91234567")
        XCTAssertEqual(g.templateKey, "refrigerator")
        XCTAssertEqual(g.category, .appliance)
        XCTAssertEqual(g.name, "Whirlpool refrigerator")
        XCTAssertEqual(g.manufactureDate, LocalDate(2019, 3, 1))
    }

    func testGEFridgeWithValuesOnNextRow() {
        let lines = [
            "GE Appliances",
            "General Electric Company, Louisville, KY",
            "MODEL NO.          SERIAL NO.",
            "GSS25GSHSS   ZT123456",
            "Refrigerator   115 V AC   60 Hz",
        ]
        let g = LabelReader.read(lines: lines, today: today)
        XCTAssertEqual(g.brand, "GE Appliances")
        XCTAssertEqual(g.model, "GSS25GSHSS")
        XCTAssertEqual(g.serial, "ZT123456")
        XCTAssertEqual(g.templateKey, "refrigerator")
        XCTAssertEqual(g.name, "GE refrigerator")
    }

    func testWaterHeaterLabel() {
        let lines = [
            "RHEEM",
            "PERFORMANCE PLATINUM",
            "GAS WATER HEATER — NATURAL GAS",
            "MODEL: XG50T06EC38U1",
            "S/N: Q081912345",
            "CAPACITY 50 U.S. GAL  (189 L)",
            "INPUT 38,000 BTU/HR",
            "MFD. 08/2019",
            "Rheem Manufacturing Company, Montgomery, AL",
        ]
        let g = LabelReader.read(lines: lines, today: today)
        XCTAssertEqual(g.brand, "Rheem")
        XCTAssertEqual(g.model, "XG50T06EC38U1")
        XCTAssertEqual(g.serial, "Q081912345")
        XCTAssertEqual(g.templateKey, "water_heater")
        XCTAssertEqual(g.category, .system)
        XCTAssertEqual(g.attributes["capacityGal"], .number(50))
        XCTAssertEqual(g.attributes["fuel"], .string("gas"))
        XCTAssertEqual(g.manufactureDate, LocalDate(2019, 8, 1))
        XCTAssertEqual(g.name, "Rheem water heater")
    }

    func testAOSmithTankWithoutTheWordsWaterHeater() {
        let g = LabelReader.read(lines: ["A. O. SMITH", "MOD. GCR-40 200", "SER. NO. 1904A012345", "40 GAL"], today: today)
        XCTAssertEqual(g.brand, "A.O. Smith")
        XCTAssertEqual(g.model, "GCR-40")
        XCTAssertEqual(g.serial, "1904A012345")
        XCTAssertEqual(g.templateKey, "water_heater")
        XCTAssertEqual(g.attributes["capacityGal"], .number(40))
    }

    func testFurnaceLabel() {
        let lines = [
            "Carrier",
            "Gas-Fired Induced-Combustion Furnace",
            "M/N 59SC5A080S17--14",
            "S/N 2419A12345",
            "For use with Natural Gas or Propane (LP) Gas",
            "INPUT BTUH 80,000   OUTPUT 77,000",
            "120V 60Hz 1PH  MAX 12 AMPS",
            "THERMOSTAT HEAT ANTICIPATOR 0.4",
            "Manufactured: JUNE 2019",
        ]
        let g = LabelReader.read(lines: lines, today: today)
        XCTAssertEqual(g.brand, "Carrier")
        XCTAssertEqual(g.model, "59SC5A080S17--14")
        XCTAssertEqual(g.serial, "2419A12345")
        XCTAssertEqual(g.templateKey, "hvac_furnace")
        XCTAssertEqual(g.kind, "furnace")
        XCTAssertEqual(g.attributes["fuel"], .string("gas"))
        XCTAssertEqual(g.manufactureDate, LocalDate(2019, 6, 1))
        XCTAssertEqual(g.name, "Carrier furnace")
    }

    func testTVBackLabel() {
        let lines = [
            "SAMSUNG",
            "LED TV",
            "Model Code: UN55TU7000FXZA",
            "Serial No.: 0B4R3CAN123456X",
            "55\" Class",
            "Manufactured: January 2021",
            "Rated 100-240V~ 50/60Hz 130W",
        ]
        let g = LabelReader.read(lines: lines, today: today)
        XCTAssertEqual(g.brand, "Samsung")
        XCTAssertEqual(g.model, "UN55TU7000FXZA")
        XCTAssertEqual(g.serial, "0B4R3CAN123456X")
        XCTAssertEqual(g.templateKey, "tv")
        XCTAssertEqual(g.category, .electronic)
        XCTAssertEqual(g.attributes["screenSize"], .number(55))
        XCTAssertEqual(g.manufactureDate, LocalDate(2021, 1, 1))
        XCTAssertEqual(g.name, "Samsung TV")
    }

    func testCondenserHasNoTemplateButAKind() {
        let lines = ["Trane", "SPLIT SYSTEM AIR CONDITIONER", "Model No. 4TTR4036L1000A", "Serial No. 21234ABCDE"]
        let g = LabelReader.read(lines: lines, today: today)
        XCTAssertEqual(g.brand, "Trane")
        XCTAssertNil(g.templateKey)
        XCTAssertEqual(g.kind, "air conditioner")
        XCTAssertEqual(g.category, .system)
        XCTAssertEqual(g.model, "4TTR4036L1000A")
        XCTAssertEqual(g.name, "Trane air conditioner")
    }

    func testOtherKinds() {
        XCTAssertEqual(LabelReader.read(lines: ["Bosch", "Dishwasher", "E-Nr: SHX878WD5N"]).templateKey, "dishwasher")
        XCTAssertEqual(LabelReader.read(lines: ["LG", "Front load washer", "MODEL WM3900HWA"]).templateKey, "washer")
        XCTAssertEqual(LabelReader.read(lines: ["Maytag", "ELECTRIC DRYER", "MODEL MED6230HW1"]).attributes["fuel"], .string("electric"))
        XCTAssertEqual(LabelReader.read(lines: ["Frigidaire", "ELECTRIC RANGE", "MOD FCRE3052AS"]).templateKey, "range")
        XCTAssertEqual(LabelReader.read(lines: ["Panasonic", "MICROWAVE OVEN", "MODEL NN-SN966S"]).kind, "microwave")
        XCTAssertNil(LabelReader.read(lines: ["Panasonic", "MICROWAVE OVEN"]).templateKey)
        XCTAssertEqual(LabelReader.read(lines: ["hOmeLabs", "Energy Star Dehumidifier", "Model: HME020031N"]).templateKey, "dehumidifier")
        XCTAssertEqual(LabelReader.read(lines: ["Zoeller", "M53", "SER 12345"]).templateKey, "sump_pump")
        XCTAssertEqual(LabelReader.read(lines: ["LiftMaster", "MODEL 8550W"]).templateKey, "garage_door_opener")
        XCTAssertEqual(LabelReader.read(lines: ["Traeger", "PRO 575", "SN 0123456789"]).templateKey, "grill")
        XCTAssertEqual(LabelReader.read(lines: ["Toro", "RECYCLER 22 in. LAWN MOWER", "Model No. 21442"]).templateKey, "lawn_mower")
        XCTAssertEqual(LabelReader.read(lines: ["NETGEAR", "Nighthawk AC1900 Smart WiFi Router", "Model: R7000"]).templateKey, "router")
        XCTAssertEqual(LabelReader.read(lines: ["ecobee", "SmartThermostat", "Model EB-STATE5-01"]).templateKey, "thermostat")
        XCTAssertEqual(LabelReader.read(lines: ["InSinkErator", "Badger 5", "MODEL B5-1"]).kind, "garbage disposal")
    }

    func testGarbageTextHasNoFalseBrand() {
        let lines = [
            "CAUTION: Risk of electric shock. Disconnect power before servicing.",
            "Do not remove this label",
            "Made in China",
            "New York, NY 10001",
            "The quick brown fox jumps over the lazy dog",
            "Sharp edges — wear gloves",
            "Page 3 of 12  Rev 2.1",
        ]
        let g = LabelReader.read(lines: lines, today: today)
        XCTAssertNil(g.brand)
        XCTAssertNil(g.model)
        XCTAssertNil(g.serial)
        XCTAssertNil(g.templateKey)
        XCTAssertNil(g.manufactureDate)
        XCTAssertNil(g.name)
        XCTAssertTrue(g.isEmpty)
        XCTAssertTrue(LabelReader.read(lines: []).isEmpty)
    }

    func testBrandIsWholeWordOnly() {
        // "LG" inside a word, "GE" inside "GEAR" / "PAGE", "Nest" inside "honest": no brand.
        let g = LabelReader.read(lines: ["ALGAE GEAR PAGE", "honestly nested"])
        XCTAssertNil(g.brand)
        XCTAssertEqual(LabelReader.read(lines: ["york international corp"]).brand, "York")
    }

    func testRatingsAreNotModelNumbers() {
        let g = LabelReader.read(lines: ["MODEL NO.", "115 V 60 HZ 6.5 A"])
        XCTAssertNil(g.model)
        let h = LabelReader.read(lines: ["MODEL:", "120V 60Hz  KDTM354DSS5"])
        XCTAssertEqual(h.model, "KDTM354DSS5")
    }

    func testFutureAndUnrecognizableDatesAreIgnored() {
        XCTAssertNil(LabelReader.read(lines: ["MFG DATE 2031-01-01"], today: today).manufactureDate)
        XCTAssertNil(LabelReader.read(lines: ["DATE CODE 1903"], today: today).manufactureDate)
        XCTAssertEqual(LabelReader.read(lines: ["DATE CODE 2018.11.20"], today: today).manufactureDate, LocalDate(2018, 11, 20))
        XCTAssertEqual(LabelReader.read(lines: ["Mfd. for Sears", "Date 15.03.2017"], today: today).manufactureDate, LocalDate(2017, 3, 15))
    }

    func testParseDateFormats() {
        XCTAssertEqual(LabelReader.parseDate("2019-03-15", today: nil), LocalDate(2019, 3, 15))
        XCTAssertEqual(LabelReader.parseDate("03/15/2019", today: nil), LocalDate(2019, 3, 15))
        XCTAssertEqual(LabelReader.parseDate("MAR 2019", today: nil), LocalDate(2019, 3, 1))
        XCTAssertEqual(LabelReader.parseDate("2020 SEP", today: nil), LocalDate(2020, 9, 1))
        XCTAssertEqual(LabelReader.parseDate("11/2018", today: nil), LocalDate(2018, 11, 1))
        XCTAssertEqual(LabelReader.parseDate("2018/11", today: nil), LocalDate(2018, 11, 1))
        XCTAssertNil(LabelReader.parseDate("5/370 VAC", today: nil))
    }

    func testRowsJoinFragmentsOnTheSameLine() {
        let frags = [
            LabelReader.Fragment(text: "WRF555SDFZ", x: 0.5, y: 0.301, height: 0.03),
            LabelReader.Fragment(text: "Whirlpool", x: 0.1, y: 0.1, height: 0.05),
            LabelReader.Fragment(text: "MODEL NO.", x: 0.1, y: 0.30, height: 0.03),
            LabelReader.Fragment(text: "SERIAL NO.", x: 0.1, y: 0.35, height: 0.03),
            LabelReader.Fragment(text: "K91234567", x: 0.5, y: 0.352, height: 0.03),
        ]
        let rows = LabelReader.rows(from: frags)
        XCTAssertEqual(rows, ["Whirlpool", "MODEL NO.  WRF555SDFZ", "SERIAL NO.  K91234567"])
        let g = LabelReader.read(lines: rows)
        XCTAssertEqual(g.model, "WRF555SDFZ")
        XCTAssertEqual(g.serial, "K91234567")
    }
}
