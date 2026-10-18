import MetalKit
import SwiftUI
import UIKit

@main
struct GlowARApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

/// Hosts the Metal camera view and owns the renderer.
struct ARMakeupView: UIViewRepresentable {
    @ObservedObject var settings: MakeupSettings

    final class Coordinator {
        var renderer: MakeupRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        if let r = MakeupRenderer(view: view, settings: settings) {
            context.coordinator.renderer = r
            settings.renderer = r
            r.start()
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.renderer?.pause()
    }
}

struct ContentView: View {
    @StateObject private var settings = MakeupSettings()
    @Environment(\.scenePhase) private var scenePhase
    @State private var toast: String?
    @State private var flash = false
    @State private var showAdvice = false

    var body: some View {
        ZStack {
            ARMakeupView(settings: settings)
                .ignoresSafeArea()
                .onTapGesture(count: 3) { settings.debugMasks.toggle() }

            if settings.splitOn {
                SplitHandle(position: $settings.split)
            }

            if flash {
                Color.white.ignoresSafeArea().transition(.opacity)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                statusHint
                ControlPanel(settings: settings, showAdvice: $showAdvice)
            }

            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            #if targetEnvironment(simulator)
            // The simulator has no face tracking: show sample measurements so the screens can be checked.
            settings.setProfile(FaceProfile(length: 0.95, jaw: 1.0, eyeGap: 0.9, eyeTilt: -4, contrast: .high, undertone: .cool))
            let env = ProcessInfo.processInfo.environment
            if let tab = env["GLOW_TAB"].flatMap(Category.init(rawValue:)) { settings.selected = tab }
            if env["GLOW_LOOK"] != nil, let a = settings.advice { settings.apply(a.night) }
            if env["GLOW_SPLIT"] != nil { settings.splitOn = true }
            if env["GLOW_SHEET"] != nil { showAdvice = true }
            #endif
        }
        .sheet(isPresented: $showAdvice) { AdviceSheet(settings: settings, isPresented: $showAdvice) }
        .onChange(of: scenePhase) { phase in
            if phase == .active { settings.renderer?.start() } else { settings.renderer?.pause() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { settings.splitOn.toggle() }
            } label: {
                Label("Πριν / Μετά", systemImage: "rectangle.split.2x1")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(settings.splitOn ? AnyShapeStyle(Color.white.opacity(0.92)) : AnyShapeStyle(.ultraThinMaterial),
                                in: Capsule())
            }
            .foregroundStyle(settings.splitOn ? .black : .white)
            Button { showAdvice = true } label: {
                Label("Τι μου πάει", systemImage: "sparkles")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundStyle(.white)
            Spacer()
            Button(action: capture) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder private var statusHint: some View {
        let message: String? = {
            if settings.unsupported { return "Χρειάζεται iPhone με Face ID (κάμερα TrueDepth)." }
            if settings.regionsFailed { return "Δεν αναγνωρίστηκε το πλέγμα του προσώπου." }
            if !settings.faceVisible { return "Κοίτα την κάμερα" }
            return nil
        }()
        if let message {
            Text(message)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 12)
        }
    }

    private func capture() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeIn(duration: 0.25)) { flash = false }
        }
        settings.renderer?.requestCapture { image in
            guard let image else { show("Δεν αποθηκεύτηκε"); return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            show("Αποθηκεύτηκε στις Φωτογραφίες")
        }
    }

    private func show(_ text: String) {
        withAnimation(.spring(response: 0.3)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeOut) { toast = nil }
        }
    }
}

/// The before/after divider: drag anywhere on the picture to move it.
struct SplitHandle: View {
    @Binding var position: Double

    var body: some View {
        GeometryReader { geo in
            let x = geo.size.width * position
            ZStack {
                Color.clear.contentShape(Rectangle())
                Rectangle().fill(Color.white).frame(width: 2)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(x: x, y: geo.size.height / 2)
                Circle().fill(Color.white).frame(width: 38, height: 38)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 14, weight: .bold)).foregroundStyle(.black))
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .position(x: x, y: geo.size.height * 0.40)
                label("ΠΡΙΝ").position(x: max(x - 38, 30), y: geo.size.height * 0.17)
                label("ΜΕΤΑ").position(x: min(x + 38, geo.size.width - 30), y: geo.size.height * 0.17)
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                position = min(max(Double(g.location.x / max(geo.size.width, 1)), 0.04), 0.96)
            })
        }
        .ignoresSafeArea()
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.heavy))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
    }
}

struct ControlPanel: View {
    @ObservedObject var settings: MakeupSettings
    @Binding var showAdvice: Bool

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Category.allCases) { cat in
                        let active = settings.selected == cat
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { settings.selected = cat }
                        } label: {
                            HStack(spacing: 5) {
                                if let shade = settings.shade(for: cat) {
                                    Circle().fill(shade.color).frame(width: 7, height: 7)
                                } else if settings.isOn(cat) {
                                    Circle().fill(Color.white).frame(width: 5, height: 5)
                                }
                                Text(cat.title).font(.footnote.weight(active ? .bold : .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(active ? Color.white.opacity(0.18) : Color.clear, in: Capsule())
                        }
                        .foregroundStyle(.white.opacity(active ? 1 : 0.7))
                    }
                }
            }

            switch settings.selected {
            case .looks: looks
            case .skin: skin
            case .brows: browGuide
            case .lips, .eyeshadow, .liner, .blush: shades
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: Looks

    @ViewBuilder private var looks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let a = settings.advice {
                    LookCard(look: a.day, title: "Για σένα · Μέρα", personal: true, suits: false,
                             selected: settings.activeLook == a.day.name) { apply(a.day) }
                    LookCard(look: a.night, title: "Για σένα · Βράδυ", personal: true, suits: false,
                             selected: settings.activeLook == a.night.name) { apply(a.night) }
                }
                ForEach(Looks.presets) { look in
                    let fit = settings.advice.map { Advisor.fit(look, undertone: $0.undertone, contrast: $0.contrast) } ?? 0
                    LookCard(look: look, title: look.name, personal: false, suits: fit >= 0.7,
                             selected: settings.activeLook == look.name) { apply(look) }
                }
                LookCard(look: Looks.bare, title: Looks.bare.name, personal: false, suits: false,
                         selected: settings.activeLook == Looks.bare.name) { apply(Looks.bare) }
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
        if let a = settings.advice {
            Button { showAdvice = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("\(a.shape.title) πρόσωπο · \(a.undertone.title.lowercased()) υπότονος · αντίθεση \(a.contrast.title.lowercased())")
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white.opacity(0.9))
        } else {
            Label(settings.faceVisible
                  ? "Σε μετράω για να σου πω τι σου πάει… \(Int(settings.measureProgress * 100))%  Χαλαρό πρόσωπο, κλειστό στόμα."
                  : "Κοίτα την κάμερα για να σου προτείνω τι σου πάει.", systemImage: "viewfinder")
                .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func apply(_ look: Look) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.25)) { settings.apply(look) }
    }

    // MARK: Skin

    @ViewBuilder private var skin: some View {
        LabeledSlider(title: "Λείανση", value: $settings.smoothing)
        LabeledSlider(title: "Τόνος", value: $settings.evenTone)
        LabeledSlider(title: "Λάμψη", value: $settings.glow)
        LabeledSlider(title: "Contour", value: $settings.contour)
        Text("Λείανση: σβήνει σημάδια και λεπτές γραμμές, κρατά την υφή του δέρματος. Τόνος: λιγότερη κοκκινίλα. Λάμψη: highlighter σε ζυγωματικά, μύτη, πάνω χείλος. Contour: σκιά κάτω από τα ζυγωματικά.")
            .font(.caption2).foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Shades

    @ViewBuilder private var shades: some View {
        let cat = settings.selected
        let starred = settings.advice?.starred ?? []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                SwatchButton(shade: nil, selected: settings.shade(for: cat) == nil, starred: false) {
                    settings.setShade(nil, for: cat)
                }
                ForEach(cat.shades) { shade in
                    SwatchButton(shade: shade, selected: settings.shade(for: cat) == shade, starred: starred.contains(shade)) {
                        UISelectionFeedbackGenerator().selectionChanged()
                        settings.setShade(shade, for: cat)
                    }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 4)
        }

        if let shade = settings.shade(for: cat) {
            HStack(spacing: 6) {
                Text(shade.name).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                if starred.contains(shade) {
                    Label("σου πάει", systemImage: "star.fill").font(.caption2.weight(.bold)).foregroundStyle(.yellow)
                }
            }

            LabeledSlider(title: "Ένταση", value: settings.intensityBinding(for: cat))

            switch cat {
            case .lips:
                Picker("Υφή", selection: $settings.lipFinish) {
                    ForEach(LipFinish.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            case .eyeshadow:
                LabeledSlider(title: "Λάμψη", value: $settings.shimmer)
            case .liner:
                LabeledSlider(title: "Πάχος", value: $settings.linerThickness, range: 0.5...1.8)
                LabeledSlider(title: "Φτερό", value: $settings.linerWing, range: 0...1.6)
            default:
                EmptyView()
            }
        } else if !starred.isEmpty {
            Label("Τα αστεράκια δείχνουν τις αποχρώσεις που σου πάνε.", systemImage: "star.fill")
                .font(.caption2.weight(.semibold)).foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Brows

    /// Brow shaping guide: live status per zone, what the lines mean, and what to remove.
    @ViewBuilder private var browGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.faceVisible, !settings.browZones.isEmpty {
                HStack(spacing: 6) {
                    ForEach(settings.browZones) { z in
                        let color: Color = !z.visible ? .white : (z.clean ? .green : .orange)
                        Text(z.label)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .background(color.opacity(z.visible ? 0.3 : 0.08), in: Capsule())
                    }
                }
            }
            if settings.browCalibration < 1 {
                Label("Μαθαίνω τα δικά σου σημεία, κοίτα ευθεία… \(Int(settings.browCalibration * 100))%",
                      systemImage: "viewfinder")
                    .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
            } else {
                Label("Οι γραμμές περνάνε από τα δικά σου σημεία", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
            }
            Text("Οι τρεις γραμμές δείχνουν πού αρχίζει, πού ψηλώνει και πού τελειώνει το φρύδι σου. Τσιμπιδάκι μόνο στις πορτοκαλί τρίχες: ανάμεσα, κάτω από το φρύδι και μετά το τέλος του.")
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 12) {
                ForEach([("Αρχή", Color(red: 0.2, green: 0.85, blue: 0.4)),
                         ("Καμάρα", Color(red: 1, green: 0.84, blue: 0.04)),
                         ("Τέλος", Color(red: 1, green: 0.33, blue: 0.33)),
                         ("Βγάλε εδώ", Color(red: 1, green: 0.4, blue: 0.1))], id: \.0) { item in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 14, height: 4)
                        Text(item.0).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            if let tip = settings.advice?.tips.first(where: { $0.icon == "eyebrow" }) {
                Label(tip.text, systemImage: "sparkles").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One complete look in the Looks row.
struct LookCard: View {
    let look: Look
    let title: String
    let personal: Bool
    let suits: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    if personal { Image(systemName: "sparkles").font(.caption2.weight(.bold)).foregroundStyle(.yellow) }
                    if suits { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                    Text(title).font(.caption.weight(.bold)).lineLimit(1)
                }
                HStack(spacing: 5) {
                    if look.shades.isEmpty {
                        Image(systemName: "nosign").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
                    }
                    ForEach(look.shades, id: \.self) { shade in
                        Circle().fill(shade.color).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.5))
                    }
                }
                .frame(height: 18)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minWidth: 96, alignment: .leading)
            .background(Color.white.opacity(selected ? 0.24 : 0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(personal ? Color.yellow.opacity(0.7) : Color.white.opacity(selected ? 0.9 : 0), lineWidth: selected ? 2 : 1))
        }
        .foregroundStyle(.white)
    }
}

/// What suits this face, and why: measurements, shades to try with one tap, two complete looks, tips.
struct AdviceSheet: View {
    @ObservedObject var settings: MakeupSettings
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                if let a = settings.advice {
                    Section("Το πρόσωπό σου") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.shape.title).font(.title2.weight(.bold))
                            Text("Μήκος προσώπου \(Self.pct(a.lengthPct)), πλάτος σαγονιού \(Self.pct(a.jawPct)) σε σχέση με το μέσο πρόσωπο. Μάτια \(a.eyeSpacing.title)\(a.eyeTilt == .straight ? "" : ", \(a.eyeTilt.title)"). Αντίθεση φρυδιών–δέρματος: \(a.contrast.title.lowercased()).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Υπότονος δέρματος").font(.subheadline.weight(.semibold))
                            Picker("Υπότονος", selection: $settings.undertoneChoice) {
                                Text("Αυτόματα").tag(Undertone?.none)
                                ForEach(Undertone.allCases) { Text($0.title).tag(Undertone?.some($0)) }
                            }
                            .pickerStyle(.segmented)
                            Text(undertoneNote(a))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Αποχρώσεις που σου πάνε") {
                        shadeRow("Κραγιόν", Array(a.lips.prefix(3)), .lips)
                        shadeRow("Ρουζ", Array(a.blushes.prefix(2)), .blush)
                        shadeRow("Σκιές", Array(a.shadows.prefix(3)), .eyeshadow)
                        shadeRow("Eyeliner", Array(a.liners.prefix(2)), .liner)
                    }
                    Section("Ολόκληρο look για σένα") {
                        lookButton("Καθημερινό", a.day)
                        lookButton("Βραδινό", a.night)
                    }
                    Section("Γιατί") {
                        ForEach(a.tips) { tip in
                            Label(tip.text, systemImage: tip.icon).font(.subheadline)
                        }
                    }
                    Section {
                        Button {
                            settings.remeasure()
                        } label: {
                            Label("Μέτρησέ με ξανά", systemImage: "arrow.clockwise")
                        }
                        Text("Το σχήμα βγαίνει από το 3D πλέγμα του προσώπου. Ο υπότονος και η αντίθεση βγαίνουν από την κάμερα, άρα εξαρτώνται από το φως: μέτρησε κοντά σε παράθυρο, με φως ημέρας, χωρίς μακιγιάζ. Είναι εκτίμηση, όχι διάγνωση.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Το πρόσωπό σου") {
                        Label("Σε μετράω… \(Int(settings.measureProgress * 100))%", systemImage: "viewfinder")
                        Text("Κοίτα την κάμερα με χαλαρό πρόσωπο και κλειστό στόμα, σε καλό φως.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Τι σου πάει")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { isPresented = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func undertoneNote(_ a: Recommendation) -> String {
        let measured = settings.profile?.undertone
        let auto = measured.map { "Η κάμερα έδειξε: \($0.title.lowercased())." } ?? ""
        return auto + " Αν ξέρεις τον δικό σου, διάλεξέ τον: φλέβες στον καρπό που δείχνουν μπλε-μοβ = ψυχρός, πρασινωπές = θερμός, και τα δύο = ουδέτερος."
    }

    private func shadeRow(_ title: String, _ shades: [Shade], _ cat: Category) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(shades) { shade in
                    let on = settings.shade(for: cat) == shade
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        settings.setShade(shade, for: cat)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(shade.color).frame(width: 16, height: 16)
                            Text(shade.name).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Color.primary.opacity(on ? 0.22 : 0.08), in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(on ? 0.8 : 0), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func lookButton(_ title: String, _ look: Look) -> some View {
        Button {
            settings.apply(look)
            isPresented = false
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    ForEach(look.shades, id: \.self) { shade in
                        Circle().fill(shade.color).frame(width: 14, height: 14)
                    }
                }
                Text(look.summary).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private static func pct(_ v: Int) -> String { v == 0 ? "ίδιο" : "\(v > 0 ? "+" : "−")\(abs(v))%" }
}

struct SwatchButton: View {
    let shade: Shade?
    let selected: Bool
    let starred: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let shade {
                    Circle().fill(shade.color)
                    Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                 startPoint: .topLeading, endPoint: .center))
                } else {
                    Circle().fill(Color.white.opacity(0.08))
                    Image(systemName: "nosign").font(.system(size: 18)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 44, height: 44)
            .overlay(Circle().stroke(Color.white, lineWidth: selected ? 2.5 : 0).padding(-4))
            .overlay(alignment: .topTrailing) {
                if starred {
                    Image(systemName: "star.fill").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(3)
                        .background(Color.black.opacity(0.75), in: Circle())
                        .offset(x: 5, y: -5)
                }
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 56, alignment: .leading)
            Slider(value: $value, in: range).tint(.white)
        }
    }
}
