import SwiftUI

struct SnapshotWebPreview: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            HStack {
                Image(systemName: "circle.hexagongrid.fill").foregroundStyle(.indigo)
                Text("orbit").font(.system(size: compact ? 18 : 23, weight: .bold, design: .rounded))
                Spacer()
                Text("Workspace").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("AS").font(.system(size: 10, weight: .bold)).padding(7)
                    .background(Color.indigo.opacity(0.15), in: Circle())
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Good morning, Alex").font(.system(size: compact ? 22 : 30, weight: .bold, design: .rounded))
                Text("A little progress, every day.").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                metric("Projects", value: "12", symbol: "square.stack.3d.up")
                metric("In progress", value: "8", symbol: "chart.line.uptrend.xyaxis")
                if !compact { metric("Completed", value: "24", symbol: "checkmark.circle") }
            }
            HStack {
                Text("Your projects").font(.headline)
                Spacer()
                Text("+ New project").foregroundStyle(.indigo).font(.system(size: 11, weight: .semibold))
            }
            ForEach(Array(["Website refresh", "Mobile experience", "Public API"].enumerated()), id: \.offset) { index, name in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        RoundedRectangle(cornerRadius: 5).fill([Color.indigo, .orange, .mint][index])
                            .frame(width: 28, height: 28)
                            .overlay(Image(systemName: ["globe", "iphone", "curlybraces"][index]).font(.system(size: 13)).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).font(.system(size: 13, weight: .semibold))
                            Text(["Design review", "Ready for testing", "In development"][index]).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(["8/12", "14/16", "6/10"][index]).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ProgressView(value: [0.67, 0.87, 0.6][index]).tint([Color.indigo, .orange, .mint][index])
                }
                .padding(compact ? 10 : 18)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
            }
            if !compact {
                Text("Recent activity").font(.headline)
                Label("Sam completed the onboarding flow", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Label("Morgan shared a new design review", systemImage: "bubble.left")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(compact ? 20 : 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.indigo)
            Text(value).font(.system(size: compact ? 22 : 28, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 10 : 14)
        .background(Color.indigo.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SnapshotDevice: View {
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Label("iPhone · Orbit", systemImage: "iphone")
                Spacer()
                Label("Connected", systemImage: "circle.fill").foregroundStyle(.green)
            }.font(.system(size: 12)).padding(18)
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                HStack {
                    Text("9:41").fontWeight(.semibold)
                    Spacer()
                    Capsule().fill(.black).frame(width: 82, height: 23)
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100percent")
                }.font(.system(size: 10)).padding(.horizontal, 20).frame(height: 42)
                SnapshotWebPreview(compact: true)
                Capsule().fill(.primary).frame(width: 94, height: 4).padding(.bottom, 12)
            }
            .frame(width: 306, height: 660)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 36))
            .overlay(RoundedRectangle(cornerRadius: 36).stroke(Color.primary.opacity(0.7), lineWidth: 7))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 12)
            Spacer(minLength: 0)
            Text("USB · 60 fps · 1170 × 2532").font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 18)
        }
    }
}

struct SnapshotRemoteDesktop: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Build lab", systemImage: "square.grid.2x2")
                    .padding(8).background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                Text("Design studio").foregroundStyle(.secondary)
                Image(systemName: "plus").foregroundStyle(.secondary)
                Spacer()
                Text("4/4").foregroundStyle(.secondary)
                Label("Add Computer", systemImage: "plus")
            }.font(.system(size: 12)).padding(12)
            GeometryReader { geometry in
                let size = NSSize(width: (geometry.size.width - 1) / 2, height: (geometry.size.height - 1) / 2)
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    GridRow {
                        remote("studio-mini-01", size: size) {
                            miniTerminal("Release build", lines: ["$ swift build -c release", "Compiling OrbitCore…",
                                                                 "Linking Orbit.app", "✓ Build complete (12.4s)", "",
                                                                 "$ swift test", "✓ 128 tests passed", "✓ Ready for distribution"])
                        }
                        remote("studio-mini-02", size: size) {
                            GeometryReader { viewport in
                                SnapshotWebPreview(compact: true)
                                    .frame(width: 900, height: 620)
                                    .scaleEffect(min(viewport.size.width / 900, viewport.size.height / 620), anchor: .topLeading)
                            }
                        }
                    }
                    GridRow {
                        remote("linux-build-01", size: size) {
                            miniTerminal("Container services", lines: ["$ docker compose up -d", "✓ orbit-web      Healthy",
                                                                       "✓ orbit-api      Healthy", "✓ orbit-db       Healthy",
                                                                       "✓ orbit-cache    Healthy", "",
                                                                       "Listening on localhost:3000", "All services are ready."])
                        }
                        remote("studio-mini-03", size: size) {
                            miniTerminal("Integration tests", lines: ["$ bun test --coverage", "✓ auth             24 passed",
                                                                      "✓ projects         32 passed", "✓ activity         44 passed",
                                                                      "✓ invitations      28 passed", "", "128 pass · 0 fail",
                                                                      "Coverage 96.8%  (+2.1%)"])
                        }
                    }
                }
            }
        }
    }

    private func remote<Content: View>(_ name: String, size: NSSize, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(name, systemImage: "desktopcomputer")
                Spacer()
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("Connected").foregroundStyle(.secondary)
            }.font(.system(size: 11)).padding(10).background(.quaternary.opacity(0.4))
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        }.frame(width: size.width, height: size.height).clipped()
    }

    private func miniTerminal(_ title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            Divider()
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line).foregroundStyle(line.hasPrefix("✓") ? Color.green : .secondary)
            }
            Spacer(minLength: 0)
        }.font(.system(size: 12, design: .monospaced)).padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
}
