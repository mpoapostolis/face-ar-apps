import simd

enum FaceShape: String {
    case oval, round, long, square, heart

    var title: String {
        switch self {
        case .oval: return "Οβάλ"
        case .round: return "Στρογγυλό"
        case .long: return "Μακρόστενο"
        case .square: return "Τετράγωνο"
        case .heart: return "Στενό σαγόνι"
        }
    }
}

/// The person's face proportions against the average face, and the beard that suits them.
struct FaceShapeResult: Equatable {
    var shape: FaceShape
    var lengthPct: Int      // face length for its width, % against the average face
    var jawPct: Int         // jaw width for the cheekbone width, % against the average face
    var style: BeardStyle
    var cheek: Double       // suggested slider positions
    var neck: Double
    var why: String
}

/// Measures the face on the live ARKit mesh, which is fitted to the person's own head shape.
/// The measurements are 3D distances between mesh points, so the head pose does not matter;
/// only frames with a relaxed, closed mouth are used. They are compared with the same
/// measurements on ARKit's average face.
final class FaceShapeEstimator {
    static let target = 40
    private let geometry: FaceGeometry
    private let base: SIMD2<Float>
    private var sum = SIMD2<Float>(repeating: 0)
    private var n = 0

    var done: Bool { n >= Self.target }

    init(geometry: FaceGeometry) {
        self.geometry = geometry
        base = geometry.shapeRatios(geometry.neutral)
    }

    /// Adds one frame; returns the result once enough frames are in.
    func add(_ live: [SIMD3<Float>]) -> FaceShapeResult? {
        guard !done else { return nil }
        sum += geometry.shapeRatios(live)
        n += 1
        guard done else { return nil }
        let r = sum / Float(n) / base
        return Self.result(length: r.x, jaw: r.y)
    }

    static func result(length: Float, jaw: Float) -> FaceShapeResult {
        let shape: FaceShape
        if jaw > 1.035 { shape = .square }
        else if jaw < 0.965 { shape = .heart }
        else if length > 1.035 { shape = .long }
        else if length < 0.965 { shape = .round }
        else { shape = .oval }

        let style: BeardStyle
        let cheek: Double, neck: Double
        let why: String
        switch shape {
        case .oval:
            (style, cheek, neck) = (.short, 0, 0)
            why = "Ισορροπημένες αναλογίες: σου πάνε σχεδόν όλα. Κοντά γένια με καθαρή γραμμή είναι η σίγουρη επιλογή."
        case .round:
            (style, cheek, neck) = (.short, -0.35, 0)
            why = "Χαμήλωσε λίγο τη γραμμή στο μάγουλο και άφησε περισσότερο μήκος στο πηγούνι από ό,τι στα πλάγια, για να δείχνει το πρόσωπο πιο μακρύ."
        case .long:
            (style, cheek, neck) = (.short, 0.3, 0)
            why = "Κράτα όγκο στα πλάγια και κοντό το πηγούνι. Η γραμμή στο μάγουλο λίγο πιο ψηλά δίνει πλάτος. Απόφυγε το μακρύ goatee."
        case .square:
            (style, cheek, neck) = (.stubble, 0, 0)
            why = "Δυνατό σαγόνι: κοντό, ομοιόμορφο μήκος για να φαίνεται η γραμμή του, με ελαφρύ στρογγύλεμα στο πηγούνι."
        case .heart:
            (style, cheek, neck) = (.full, 0, 0.3)
            why = "Πιο γεμάτα γένια δίνουν όγκο στο κάτω μέρος του προσώπου, με τη γραμμή του λαιμού λίγο πιο χαμηλά."
        }
        return FaceShapeResult(shape: shape, lengthPct: Int(((length - 1) * 100).rounded()),
                               jawPct: Int(((jaw - 1) * 100).rounded()),
                               style: style, cheek: cheek, neck: neck, why: why)
    }
}
