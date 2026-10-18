import MetalKit
import SwiftUI
import UIKit

@main
struct GroomARApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

struct ARGuideView: UIViewRepresentable {
    @ObservedObject var settings: GroomSettings

    final class Coordinator { var renderer: GroomRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        if let r = GroomRenderer(view: view, settings: settings) {
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
    @StateObject private var settings = GroomSettings()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSteps = false
    @State private var showAdvice = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            ARGuideView(settings: settings).ignoresSafeArea()

            if settings.tab == .routine {
                RoutineView()
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    topBar
                    symmetryBadge
                    Spacer()
                    hint
                    panel
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onChange(of: settings.tab) { tab in
            if tab == .routine { settings.renderer?.pause() } else { settings.renderer?.start() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, settings.tab != .routine { settings.renderer?.start() }
            if phase != .active { settings.renderer?.pause() }
        }
        .sheet(isPresented: $showSteps) { stepsSheet }
        .sheet(isPresented: $showAdvice) { adviceSheet }
        .overlay {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: capture) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)
            if settings.tab == .beard {
                Button { showAdvice = true } label: {
                    Label("Πρόταση", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .foregroundStyle(.white)
            }
            Spacer()
            Button {
                settings.mirror.toggle()
            } label: {
                Label(settings.mirror ? "Καθρέφτης" : "Κανονικά", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Live comparison of the real beard edge on the two cheeks.
    @ViewBuilder private var symmetryBadge: some View {
        if settings.tab == .beard, settings.faceVisible, let s = settings.symmetry {
            let text = s.even
                ? "Συμμετρικά ✓"
                : "\(s.delta > 0 ? "Αριστερό" : "Δεξί") μάγουλο \(Self.mm(abs(s.delta))) χιλ. πιο ψηλά"
            Label(text, systemImage: "arrow.left.and.right")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background((s.even ? Color.green : Color.orange).opacity(0.35), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    private static func mm(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }

    @ViewBuilder private var hint: some View {
        let message: String? = {
            if settings.unsupported { return "Χρειάζεται iPhone με Face ID (κάμερα TrueDepth)." }
            if settings.geometryFailed { return "Δεν αναγνωρίστηκε το πλέγμα του προσώπου." }
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
        settings.renderer?.requestCapture { image in
            guard let image else { show("Δεν αποθηκεύτηκε"); return }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            show("Αποθηκεύτηκε στις Φωτογραφίες")
        }
    }

    private func show(_ text: String) {
        withAnimation(.spring(response: 0.3)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.easeOut) { toast = nil } }
    }

    /// Live status per zone: green = clean, orange = hair still there to trim.
    @ViewBuilder private var zoneRow: some View {
        if settings.faceVisible, !settings.zones.isEmpty {
            HStack(spacing: 6) {
                ForEach(settings.zones) { z in
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
    }

    @ViewBuilder private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            zoneRow
            if settings.tab == .beard {
                HStack(spacing: 6) {
                    ForEach(BeardStyle.allCases) { style in
                        let active = settings.beardStyle == style
                        Button { settings.beardStyle = style } label: {
                            Text(style.title)
                                .font(.footnote.weight(active ? .bold : .medium))
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(active ? Color.white.opacity(0.2) : Color.clear, in: Capsule())
                        }
                        .foregroundStyle(.white.opacity(active ? 1 : 0.7))
                    }
                }
                Text(settings.beardStyle.summary)
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                SliderRow(title: settings.beardStyle == .goatee ? "Ύψος" : "Μάγουλο", value: $settings.cheekOffset)
                SliderRow(title: settings.beardStyle == .goatee ? "Πλάτος" : "Λαιμός", value: $settings.neckOffset)
                Toggle(isOn: $settings.preview) {
                    Text("Δείξε το στυλ πάνω μου").font(.caption.weight(.medium))
                }
                .tint(Color(red: 0.25, green: 0.85, blue: 1))
                legend([("Γραμμή κοπής", Color(red: 0.25, green: 0.85, blue: 1)),
                        ("Λαιμός (διακεκομμένη)", .white.opacity(0.7)),
                        ("Κόψε εδώ", Color(red: 1, green: 0.4, blue: 0.1))])
            } else {
                if settings.browCalibration < 1 {
                    Label("Μαθαίνω τα δικά σου σημεία, κοίτα ευθεία… \(Int(settings.browCalibration * 100))%",
                          systemImage: "viewfinder")
                        .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                } else {
                    Label("Οι γραμμές περνάνε από τα δικά σου σημεία", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
                Text("Οι τρεις γραμμές δείχνουν πού αρχίζει, πού ψηλώνει και πού τελειώνει το φρύδι σου.")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                legend([("Αρχή", Color(red: 0.2, green: 0.85, blue: 0.4)),
                        ("Καμάρα", Color(red: 1, green: 0.84, blue: 0.04)),
                        ("Τέλος", Color(red: 1, green: 0.33, blue: 0.33)),
                        ("Βγάλε εδώ", Color(red: 1, green: 0.4, blue: 0.1))])
            }
            Button { showSteps = true } label: {
                Label("Οδηγίες βήμα-βήμα", systemImage: "list.number")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            }
            .foregroundStyle(.white)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func legend(_ items: [(String, Color)]) -> some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.0) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(item.1).frame(width: 14, height: 4)
                    Text(item.0).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private var tabBar: some View {
        HStack {
            ForEach(GroomTab.allCases) { tab in
                let active = settings.tab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { settings.tab = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 19, weight: .semibold))
                        Text(tab.title).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .foregroundStyle(.white.opacity(active ? 1 : 0.5))
            }
        }
        .padding(.horizontal, 12)
        .background(.black.opacity(0.85))
    }

    /// Suggestion from the measured face shape, plus the real beard line against the guide.
    private var adviceSheet: some View {
        NavigationStack {
            List {
                if let f = settings.faceShape {
                    Section("Το πρόσωπό σου") {
                        Text(f.shape.title).font(.title2.weight(.bold))
                        Text("Μήκος προσώπου \(Self.pct(f.lengthPct)), πλάτος σαγονιού \(Self.pct(f.jawPct)) σε σχέση με το μέσο πρόσωπο.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Τι σου πάει") {
                        Text(f.why)
                        Button {
                            settings.beardStyle = f.style
                            settings.cheekOffset = f.cheek
                            settings.neckOffset = f.neck
                            showAdvice = false
                        } label: {
                            Label("Βάλε τον οδηγό: \(f.style.title)", systemImage: "checkmark.circle.fill")
                                .font(.body.weight(.semibold))
                        }
                    }
                } else {
                    Section("Το πρόσωπό σου") {
                        Label("Μετράω το πρόσωπό σου… κοίτα την κάμερα με χαλαρό πρόσωπο και κλειστό στόμα.",
                              systemImage: "viewfinder")
                    }
                }
                Section("Η γραμμή των γενιών σου τώρα") {
                    if let s = settings.symmetry {
                        Text("Αριστερό μάγουλο: \(Self.signed(s.left)) χιλ. · Δεξί μάγουλο: \(Self.signed(s.right)) χιλ. από τον οδηγό (+ = πιο ψηλά).")
                        if settings.beardStyle != .goatee {
                            Button {
                                if let v = settings.renderer?.cheekOffsetOnBeard() { settings.cheekOffset = v }
                                showAdvice = false
                            } label: {
                                Label("Φέρε τον οδηγό πάνω στη γραμμή μου", systemImage: "arrow.up.and.down")
                            }
                        }
                    } else {
                        Text("Δεν φαίνεται καθαρή άκρη γενιών στα μάγουλα. Κοίτα ευθεία την κάμερα, με φως από μπροστά.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Οι μετρήσεις βγαίνουν από το 3D πλέγμα του προσώπου και την κάμερα. Είναι εκτίμηση: δες τες ως αφετηρία.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Πρόταση")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { showAdvice = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private static func pct(_ v: Int) -> String { v == 0 ? "ίδιο" : "\(v > 0 ? "+" : "−")\(abs(v))%" }
    private static func signed(_ v: Double) -> String { v == 0 ? "0" : "\(v > 0 ? "+" : "−")\(mm(abs(v)))" }

    private var stepsSheet: some View {
        NavigationStack {
            List {
                let steps = settings.tab == .brows ? BrowGuide.steps : settings.beardStyle.steps
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(i + 1)").font(.headline).frame(width: 22)
                        Text(step).font(.body)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(settings.tab == .brows ? "Φρύδια" : settings.beardStyle.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { showSteps = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                .frame(width: 62, alignment: .leading)
            Image(systemName: "arrow.down").font(.caption2).foregroundStyle(.white.opacity(0.5))
            Slider(value: $value, in: -1...1).tint(.white)
            Image(systemName: "arrow.up").font(.caption2).foregroundStyle(.white.opacity(0.5))
        }
    }
}
