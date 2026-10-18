import SwiftUI

enum SkinType: String, CaseIterable, Identifiable {
    case oily, dry, combo, normal, sensitive
    var id: String { rawValue }
    var title: String {
        switch self {
        case .oily: return "Λιπαρό"
        case .dry: return "Ξηρό"
        case .combo: return "Μικτό"
        case .normal: return "Κανονικό"
        case .sensitive: return "Ευαίσθητο"
        }
    }
    var hint: String {
        switch self {
        case .oily: return "Γυαλίζει μέχρι το μεσημέρι, ειδικά σε μέτωπο και μύτη."
        case .dry: return "Τραβάει μετά το πλύσιμο, ξεφλουδίζει κάπου κάπου."
        case .combo: return "Λιπαρό στη ζώνη Τ (μέτωπο, μύτη), ξηρό στα μάγουλα."
        case .normal: return "Ούτε γυαλίζει ούτε τραβάει ιδιαίτερα."
        case .sensitive: return "Κοκκινίζει ή τσούζει εύκολα, ειδικά μετά το ξύρισμα."
        }
    }
}

struct RoutineStep: Identifiable {
    let id: String
    let title: String
    let detail: String
    let daily: Bool
}

enum Routine {
    static func morning(_ t: SkinType) -> [RoutineStep] {
        [
            RoutineStep(id: "m1", title: "Καθαρισμός", detail: {
                switch t {
                case .oily: return "Gel καθαρισμού με σαλικυλικό οξύ (BHA). Χλιαρό νερό, 30–60 δευτερόλεπτα."
                case .dry: return "Κρεμώδες, ήπιο καθαριστικό, ή μόνο χλιαρό νερό το πρωί."
                case .combo: return "Ήπιο gel καθαρισμού, με έμφαση σε μέτωπο και μύτη."
                case .normal: return "Ήπιο gel ή αφρός καθαρισμού."
                case .sensitive: return "Ήπιο καθαριστικό χωρίς άρωμα. Χωρίς τρίψιμο, ταμπονάρισμα με την πετσέτα."
                }
            }(), daily: true),
            RoutineStep(id: "m2", title: "Ορός (προαιρετικά)", detail: {
                switch t {
                case .oily, .combo: return "Νιασιναμίδη για λιπαρότητα και πόρους."
                case .dry: return "Υαλουρονικό οξύ πάνω σε ελαφρώς υγρό δέρμα."
                case .normal: return "Βιταμίνη C για λάμψη και προστασία."
                case .sensitive: return "Παράλειψέ το ή διάλεξε καταπραϋντικό (centella, πανθενόλη)."
                }
            }(), daily: false),
            RoutineStep(id: "m3", title: "Ενυδάτωση", detail: {
                switch t {
                case .oily: return "Ελαφριά gel κρέμα που δεν βουλώνει τους πόρους (non-comedogenic)."
                case .dry: return "Πλουσιότερη κρέμα με κεραμίδια ή γλυκερίνη."
                case .combo: return "Ελαφριά κρέμα, λίγη παραπάνω στα ξηρά σημεία."
                case .normal: return "Ελαφριά ενυδατική κρέμα."
                case .sensitive: return "Απλή κρέμα χωρίς άρωμα και οινόπνευμα."
                }
            }(), daily: true),
            RoutineStep(id: "m4", title: "Αντηλιακό SPF 30+",
                        detail: t == .oily
                            ? "Κάθε μέρα, με ματ φινίρισμα. Δύο δάχτυλα ποσότητα για πρόσωπο και λαιμό."
                            : "Κάθε μέρα, ακόμα και με συννεφιά. Δύο δάχτυλα ποσότητα για πρόσωπο και λαιμό.",
                        daily: true),
        ]
    }

    static func evening(_ t: SkinType) -> [RoutineStep] {
        [
            RoutineStep(id: "e1", title: "Καθαρισμός",
                        detail: "Ξέβγαλε ιδρώτα, λιπαρότητα και αντηλιακό. Το ίδιο καθαριστικό με το πρωί.", daily: true),
            RoutineStep(id: "e2", title: "Ενεργό συστατικό (2–3 φορές/εβδομάδα)", detail: {
                switch t {
                case .oily: return "Ρετινοειδές (π.χ. adapalene) ή BHA. Ξεκίνα με 2 φορές την εβδομάδα."
                case .dry: return "Ήπιο ρετινοειδές ή γαλακτικό οξύ, 1–2 φορές την εβδομάδα."
                case .combo: return "BHA στη ζώνη Τ ή ρετινοειδές, 2–3 φορές την εβδομάδα."
                case .normal: return "Ρετινοειδές για υφή και πρόληψη, 2–3 φορές την εβδομάδα."
                case .sensitive: return "Μόνο όταν το δέρμα είναι ήρεμο, πολύ σταδιακά, ή παράλειψέ το."
                }
            }(), daily: false),
            RoutineStep(id: "e3", title: "Ενυδάτωση",
                        detail: "Ίδια κρέμα με το πρωί ή λίγο πιο πλούσια.", daily: true),
        ]
    }

    static let beard: [RoutineStep] = [
        RoutineStep(id: "b1", title: "Λάδι ή βάλσαμο γενιών",
                    detail: "2–4 σταγόνες στις παλάμες, από τη ρίζα προς τις άκρες, μετά το μπάνιο.", daily: true),
        RoutineStep(id: "b2", title: "Χτένισμα",
                    detail: "Με χτένα ή βούρτσα προς τα κάτω. Ισιώνει τις τρίχες και μοιράζει το λάδι.", daily: true),
        RoutineStep(id: "b3", title: "Λούσιμο γενιών (2–3 φορές/εβδομάδα)",
                    detail: "Με σαμπουάν γενιών, όχι με το σαπούνι του προσώπου.", daily: false),
        RoutineStep(id: "b4", title: "Τριμάρισμα (κάθε 1–2 εβδομάδες)",
                    detail: "Με τους οδηγούς στην καρτέλα Γένια.", daily: false),
    ]

    static let weekly: [RoutineStep] = [
        RoutineStep(id: "w1", title: "Απολέπιση 1–2 φορές",
                    detail: "Όχι το ίδιο βράδυ με το ρετινοειδές ή το BHA.", daily: false),
        RoutineStep(id: "w2", title: "Καθαρή μαξιλαροθήκη",
                    detail: "Αλλαγή 1–2 φορές την εβδομάδα.", daily: false),
    ]

    static let shaving: [RoutineStep] = [
        RoutineStep(id: "s1", title: "Ξύρισμα χωρίς ερεθισμό",
                    detail: "Ζεστό νερό ή ζεστή πετσέτα για 1 λεπτό, gel ή αφρός, ξύρισμα με τη φορά της τρίχας, ξέβγαλμα με κρύο νερό, balm χωρίς οινόπνευμα.",
                    daily: false),
    ]
}

struct RoutineView: View {
    @AppStorage("skinType") private var skinRaw = SkinType.normal.rawValue
    @AppStorage("routineChecks") private var checksRaw = "{}"

    private var skin: SkinType { SkinType(rawValue: skinRaw) ?? .normal }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private var today: String { Self.dayFormatter.string(from: Date()) }

    private var checks: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(checksRaw.utf8))) ?? [:]
    }

    private func isDone(_ id: String) -> Bool { checks[id] == today }

    private func toggle(_ id: String) {
        var c = checks
        c[id] = isDone(id) ? nil : today
        if let data = try? JSONEncoder().encode(c), let s = String(data: data, encoding: .utf8) { checksRaw = s }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var dailySteps: [RoutineStep] {
        (Routine.morning(skin) + Routine.evening(skin) + Routine.beard).filter(\.daily)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                skinPicker
                section("Πρωί", icon: "sun.max", steps: Routine.morning(skin))
                section("Βράδυ", icon: "moon", steps: Routine.evening(skin))
                section("Γένια", icon: "mustache", steps: Routine.beard)
                section("Κάθε εβδομάδα", icon: "calendar", steps: Routine.weekly)
                section("Αν ξυρίζεσαι", icon: "scissors", steps: Routine.shaving)
                Text("Γενικές οδηγίες περιποίησης, όχι ιατρική συμβουλή. Για ακμή, έντονο ερεθισμό ή κάτι που δεν περνάει, δερματολόγος.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.07).ignoresSafeArea())
    }

    private var header: some View {
        let done = dailySteps.filter { isDone($0.id) }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("Ρουτίνα").font(.largeTitle.bold())
            HStack {
                Text("Σήμερα: \(done)/\(dailySteps.count)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            ProgressView(value: Double(done), total: Double(max(dailySteps.count, 1)))
                .tint(.green)
        }
        .padding(.top, 8)
    }

    private var skinPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Τύπος δέρματος").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SkinType.allCases) { t in
                        let active = t == skin
                        Button { skinRaw = t.rawValue } label: {
                            Text(t.title)
                                .font(.subheadline.weight(active ? .bold : .regular))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(active ? Color.white : Color.white.opacity(0.1), in: Capsule())
                                .foregroundStyle(active ? .black : .white)
                        }
                    }
                }
            }
            Text(skin.hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, icon: String, steps: [RoutineStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            VStack(spacing: 0) {
                ForEach(steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        if step.daily {
                            Button { toggle(step.id) } label: {
                                Image(systemName: isDone(step.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isDone(step.id) ? .green : .white.opacity(0.5))
                            }
                        } else {
                            Image(systemName: "info.circle").font(.title3).foregroundStyle(.white.opacity(0.35))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).font(.subheadline.weight(.semibold))
                            Text(step.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    if step.id != steps.last?.id { Divider().padding(.leading, 46) }
                }
            }
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
