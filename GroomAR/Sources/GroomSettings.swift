import SwiftUI

enum GroomTab: String, CaseIterable, Identifiable {
    case beard, brows, routine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .beard: return "Γένια"
        case .brows: return "Φρύδια"
        case .routine: return "Ρουτίνα"
        }
    }
    var icon: String {
        switch self {
        case .beard: return "mustache"
        case .brows: return "eyebrow"
        case .routine: return "drop"
        }
    }
}

enum BeardStyle: String, CaseIterable, Identifiable {
    case stubble, short, full, goatee
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stubble: return "Stubble"
        case .short: return "Κοντά"
        case .full: return "Γεμάτα"
        case .goatee: return "Goatee"
        }
    }
    var summary: String {
        switch self {
        case .stubble: return "1–3 mm παντού. Ξύρισε μόνο τις σκιασμένες ζώνες."
        case .short: return "4–6 mm στο πηγούνι, 3–4 mm στα πλάγια."
        case .full: return "Φυσική γραμμή μάγουλου, λαιμός λίγο πιο χαμηλά."
        case .goatee: return "Μόνο γύρω από στόμα και πηγούνι, τα υπόλοιπα ξυρισμένα."
        }
    }
    var steps: [String] {
        switch self {
        case .stubble:
            return [
                "Trimmer χωρίς χτένα ή με χτένα 1–3 mm, ομοιόμορφα σε όλο το πρόσωπο, αντίθετα από τη φορά της τρίχας.",
                "Ξύρισε ό,τι είναι πάνω από τη γαλάζια γραμμή στο μάγουλο (σκιασμένη ζώνη).",
                "Ξύρισε ό,τι είναι κάτω από τη διακεκομμένη γραμμή του λαιμού.",
                "Επανάλαβε κάθε 2–3 μέρες για να μένει σταθερό το μήκος.",
            ]
        case .short:
            return [
                "Χτένα 4–6 mm στο πηγούνι και 3–4 mm στα πλάγια, για φυσικό fade προς τα αυτιά.",
                "Καθάρισε ό,τι είναι πάνω από τη γαλάζια γραμμή στο μάγουλο.",
                "Γραμμή λαιμού: περίπου δύο δάχτυλα πάνω από το μήλο του Αδάμ (η διακεκομμένη γραμμή).",
                "Μουστάκι: κόψε ό,τι πέφτει πάνω στο χείλος.",
                "Κοίτα ευθεία την κάμερα και έλεγξε ότι οι δύο πλευρές είναι συμμετρικές.",
            ]
        case .full:
            return [
                "Άφησέ τα να μεγαλώσουν 4–6 εβδομάδες πριν τα σχηματοποιήσεις.",
                "Χτένισε προς τα κάτω και κόψε μόνο τις άκρες για να δώσεις σχήμα.",
                "Κράτα τη γραμμή μάγουλου φυσική· καθάρισε μόνο τις τρίχες πάνω από τη γαλάζια γραμμή.",
                "Λαιμός λίγο πιο χαμηλά από τα κοντά γένια, ποτέ πάνω στο σαγόνι.",
            ]
        case .goatee:
            return [
                "Ξύρισε εντελώς μάγουλα και λαιμό.",
                "Ακολούθησε το γαλάζιο περίγραμμα γύρω από στόμα και πηγούνι.",
                "Κράτα τις δύο πλευρές συμμετρικές ως προς τη μέση του πηγουνιού.",
                "Μήκος 3–6 mm με trimmer.",
            ]
        }
    }
}

enum BrowGuide {
    static let steps = [
        "Χτένισε τις τρίχες προς τα πάνω με ένα χτενάκι φρυδιών.",
        "Ψαλίδισε μόνο όσες ξεπερνούν τη φυσική γραμμή του φρυδιού.",
        "Πράσινη γραμμή = αρχή του φρυδιού. Η κόκκινη περιοχή ανάμεσα καθαρίζεται.",
        "Οι πορτοκαλί κουκκίδες δείχνουν μεμονωμένες τρίχες έξω από το φρύδι σου (από κάτω, από πάνω και μετά το τέλος).",
        "Κίτρινη γραμμή = το ψηλότερο σημείο (καμάρα). Μην το χαμηλώνεις.",
        "Κόκκινη γραμμή = τέλος. Τρίχες πιο έξω από αυτήν μπορούν να φύγουν.",
        "Τσιμπιδάκι μόνο από κάτω και ανάμεσα, ποτέ από πάνω· μία-μία τρίχα, με φως ημέρας.",
        "Για αντρικό αποτέλεσμα κράτα πυκνότητα και ίσια φόρμα· μην τα λεπταίνεις.",
    ]
}

final class GroomSettings: ObservableObject {
    @Published var tab: GroomTab = .beard
    @Published var beardStyle: BeardStyle = .short
    @Published var cheekOffset: Double = 0
    @Published var neckOffset: Double = 0
    @Published var mirror = true
    @Published var preview = false   // lines only on the real face; the style preview is opt-in

    /// Live "trim here" status per zone, updated a few times a second.
    @Published var zones: [ZoneStatus] = []
    /// 0...1 while the app learns the person's nose sides, pupils and brows.
    @Published var browCalibration: Double = 0
    /// Real beard edge on each cheek against the guide; nil when no clear edge is in view.
    @Published var symmetry: SymmetryStatus?
    /// Face proportions and the beard suggested for them, once measured.
    @Published var faceShape: FaceShapeResult?

    @Published var faceVisible = false
    @Published var unsupported = false
    @Published var geometryFailed = false

    weak var renderer: GroomRenderer?
}

struct ZoneStatus: Identifiable, Equatable {
    let id: Int
    let name: String
    var visible: Bool
    var stray: Double      // share of the zone that still has hair (0...1)
    var limit = 0.02       // share below which the zone counts as clean

    var clean: Bool { stray < limit }
    var label: String {
        guard visible else { return "\(name) —" }
        return clean ? "\(name) ✓" : "\(name): κόψε"
    }
}
