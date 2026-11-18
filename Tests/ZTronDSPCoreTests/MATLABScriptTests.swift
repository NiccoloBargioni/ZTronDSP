import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

@Suite("MATLABScript (WP-120)")
struct MATLABScriptTests {
    /// The golden script: every kind of variable and every plot command.
    private static let golden = """
        % Pole-zero map of a second-order section
        fs = 48000;
        w = [0 0.25 0.5 1];
        g = [1 0.5 0.25];
        p = [0.5+0.5i 0.5-0.5i];
        H = [1 2 3; 4 5 6];
        S = [0 0.5; 1 1.5; 2 2.5];
        d = [1 NaN 3];
        subplot(2, 1, 1);
        plot(w, 20*log10(abs(H(1,:))), 'r--');
        hold on;
        semilogx(w, w);
        loglog(w, w);
        stem(real(p), imag(p), 'x');
        hold off;
        grid on;
        grid off;
        xlabel('Frequency (Hz)');
        ylabel('Magnitude (dB)');
        title('It''s a filter');
        axis equal;
        axis([0 24000 -90 6]);
        subplot(2, 1, 2);
        imagesc(w, g, S);
        axis xy;
        colorbar;

        """

    private func build() throws -> MATLABScript {
        try MATLABScript()
            .comment("Pole-zero map of a second-order section")
            .scalar("fs", 48_000)
            .vector("w", [0, 0.25, 0.5, 1])
            .vector("g", [1, 0.5, 0.25] as [Float])
            .vector("p", real: [0.5, 0.5], imaginary: [0.5, -0.5])
            .matrix("H", rows: [[1, 2, 3], [4, 5, 6]])
            .matrix("S", values: [0, 0.5, 1, 1.5, 2, 2.5], rows: 3, columns: 2)
            .vector("d", optional: [1, nil, 3])
            .subplot(2, 1, 1)
            .plot("w", "20*log10(abs(H(1,:)))", style: "r--")
            .hold()
            .semilogx("w", "w")
            .loglog("w", "w")
            .stem("real(p)", "imag(p)", style: "x")
            .hold(false)
            .grid()
            .grid(false)
            .xlabel("Frequency (Hz)")
            .ylabel("Magnitude (dB)")
            .title("It's a filter")
            .axis("equal")
            .axis(x: 0 ... 24_000, y: -90 ... 6)
            .subplot(2, 1, 2)
            .imagesc("w", "g", "S")
            .colorbar()
    }

    @Test func emittedTextEqualsTheGoldenScript() throws {
        #expect(try build().text == Self.golden)
    }

    @Test func equalInputGivesEqualText() throws {
        #expect(try build() == build(), "no date, no machine name (MAT-4)")
        #expect(try build().text == build().text)
        #expect(MATLABScript().text == "" && MATLABScript().lines.isEmpty)
        let first = try MATLABScript().scalar("a", 1), second = MATLABScript().grid()
        #expect(first.appending(second).lines == ["a = 1;", "grid on;"])
    }

    /// MAT-3: 17 significant digits from Double, 9 from Float, so the numbers read back exactly.
    @Test func numbersReadBackExactly() {
        var generator = SeededGenerator(seed: 120)
        var doubles: [Double] = [0, -0.0, 1, 0.1, 1.0 / 3, .pi, 1e-300, 1e300, 123_456_789.123_456_789, .leastNonzeroMagnitude,
                                 .leastNormalMagnitude, .greatestFiniteMagnitude, 2.2250738585072014e-308, 4.9e-324]
        for _ in 0 ..< 2_000 { doubles.append(Double(bitPattern: generator.next())) }
        for value in doubles where value.isFinite {
            #expect(Double(MATLABScript.format(value)) == value, "\(value) → \(MATLABScript.format(value))")
        }
        var floats: [Float] = [0, 1, 0.1, 1.0 / 3, .pi, 1e-38, 1e38, .leastNonzeroMagnitude, .greatestFiniteMagnitude, 16_777_216]
        for _ in 0 ..< 2_000 { floats.append(Float(bitPattern: UInt32(truncatingIfNeeded: generator.next()))) }
        for value in floats where value.isFinite {
            #expect(Float(MATLABScript.format(value)) == value, "\(value) → \(MATLABScript.format(value))")
        }
        #expect(MATLABScript.format(0.1) == "0.10000000000000001")
        #expect(MATLABScript.format(Float(0.1)) == "0.100000001")
        #expect(MATLABScript.format(48_000.0) == "48000")
    }

    @Test func undefinedValuesAreWrittenAsNaN() throws {
        #expect(MATLABScript.format(Double.nan) == "NaN" && MATLABScript.format(Float.nan) == "NaN")
        #expect(MATLABScript.format(Double.infinity) == "Inf" && MATLABScript.format(-Double.infinity) == "-Inf")
        #expect(MATLABScript.format(Float.infinity) == "Inf" && MATLABScript.format(-Float.infinity) == "-Inf")
        #expect(try MATLABScript().vector("gd", optional: [nil, 2.5]).text == "gd = [NaN 2.5];\n")
    }

    @Test func anOversizedVariableIsExportTooLarge() throws {
        let limit = MATLABScript.elementLimit
        #expect(limit == 4_000_000)
        #expect(throws: DSPError.exportTooLarge(elements: limit + 1, limit: limit)) {
            try MATLABScript().vector("x", [Float](repeating: 0, count: limit + 1))
        }
        #expect(throws: DSPError.exportTooLarge(elements: limit + 1, limit: limit)) {
            try MATLABScript().vector("x", [Double](repeating: 0, count: limit + 1))
        }
        #expect(throws: DSPError.exportTooLarge(elements: 2_001 * 2_000, limit: limit)) {
            try MATLABScript().matrix("x", values: [Float](repeating: 0, count: 2_001 * 2_000), rows: 2_001, columns: 2_000)
        }
        #expect(throws: DSPError.exportTooLarge(elements: 2_001 * 2_000, limit: limit)) {
            try MATLABScript().matrix("x", rows: [[Double]](repeating: [Double](repeating: 0, count: 2_000), count: 2_001))
        }
        #expect(throws: DSPError.exportTooLarge(elements: limit + 1, limit: limit)) {
            try MATLABScript().vector("x", real: [Double](repeating: 0, count: limit + 1), imaginary: [Double](repeating: 0, count: limit + 1))
        }
        // Exactly at the limit is accepted.
        #expect(try MATLABScript().matrix("x", values: [Float](repeating: 0, count: 2_000 * 2_000), rows: 2_000, columns: 2_000).lines.count == 1)
    }

    @Test(arguments: ["", "1x", "a b", "a-b", "x.y", "é", "_x", String(repeating: "a", count: 64)])
    func namesThatAreNotMATLABIdentifiersAreRejected(name: String) {
        #expect(throws: DSPError.self) { try MATLABScript().scalar(name, 1) }
        #expect(throws: DSPError.self) { try MATLABScript().vector(name, [1.0]) }
        #expect(throws: DSPError.self) { try MATLABScript().vector(name, [1] as [Float]) }
        #expect(throws: DSPError.self) { try MATLABScript().vector(name, real: [1], imaginary: [1]) }
        #expect(throws: DSPError.self) { try MATLABScript().matrix(name, rows: [[1]]) }
        #expect(throws: DSPError.self) { try MATLABScript().matrix(name, values: [1], rows: 1, columns: 1) }
    }

    @Test func validNamesAndShapes() throws {
        #expect(try MATLABScript().scalar("x_1", 2).text == "x_1 = 2;\n")
        #expect(try MATLABScript().scalar(String(repeating: "a", count: 63), 2).lines.count == 1)
        #expect(try MATLABScript().vector("e", [Double]()).text == "e = [];\n")
        #expect(try MATLABScript().matrix("m", rows: []).text == "m = [];\n")
        #expect(try MATLABScript().vector("z", real: [1, -2], imaginary: [-0.0, 3]).text == "z = [1-0i -2+3i];\n")
        #expect(throws: DSPError.self) { try MATLABScript().matrix("m", rows: [[1, 2], [3]]) }
        #expect(throws: DSPError.self) { try MATLABScript().matrix("m", values: [1, 2, 3], rows: 2, columns: 2) }
        #expect(throws: DSPError.self) { try MATLABScript().matrix("m", values: [], rows: -1, columns: 0) }
        #expect(throws: DSPError.self) { try MATLABScript().vector("z", real: [1], imaginary: [1, 2]) }
    }

    @Test func textInCommandsCannotBreakOutOfItsQuotes() {
        #expect(MATLABScript().title("a'); system('rm -rf /');\nx").lines == ["title('a''); system(''rm -rf /''); x');"])
        #expect(MATLABScript().comment("two\nlines").lines == ["% two lines"])
        #expect(MATLABScript().axis("tight; quit").lines == ["axis tightquit;"])
    }
}
