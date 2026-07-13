import SwiftUI
import AppKit

// MARK: - Live run console

/// A sheet that shows a command running live: header with the command + status,
/// a streaming monospace log, and Stop / Close. Presented while a ``CaptureSession``
/// runs and stays open after it finishes so you can read the result.
struct RunConsoleView: View {
    @ObservedObject var session: CaptureSession
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ConsoleLog(lines: session.lines, live: session.status == .running)
            Divider().opacity(0.3)
            footer
        }
        .frame(width: 680, height: 520)
        .background(WindowBackdrop().ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 10) {
            RunStatusIcon(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.label)
                    .font(.headline)
                Text(session.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let name = session.projectName {
                Label(name, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            RunOutcomeLabel(status: session.status, exitCode: session.exitCode,
                            duration: liveDuration)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.lines.joined(separator: "\n"), forType: .string)
            } label: {
                Label("Copy output", systemImage: "doc.on.doc").font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)

            if session.status == .running {
                Button(role: .destructive) { session.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass(tint: .orange, prominent: true))
            } else {
                Button("Close", action: onClose)
                    .buttonStyle(.glass(tint: .accentColor, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private var liveDuration: TimeInterval? {
        session.finishedAtUnix.map { $0 - session.startedAtUnix }
    }
}

// MARK: - Past run viewer

/// A read-only sheet showing a finished run's captured output tail and outcome.
struct RunOutputSheet: View {
    let run: CommandRun
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RunStatusIcon(status: run.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.label).font(.headline)
                    Text(run.command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(Format.relative(run.startedAt))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider().opacity(0.3)
            if run.outputTail.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.alignleft").font(.title2).foregroundStyle(.secondary)
                    Text("No output was captured").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ConsoleLog(lines: run.outputTail, live: false)
            }
            Divider().opacity(0.3)
            HStack {
                RunOutcomeLabel(status: run.status, exitCode: run.exitCode, duration: run.duration)
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(.glass(tint: .accentColor, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 680, height: 500)
        .background(WindowBackdrop().ignoresSafeArea())
    }
}

// MARK: - Shared console log

/// A dark monospace log that auto-scrolls to the newest line while live.
private struct ConsoleLog: View {
    let lines: [String]
    let live: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.85))
            .onChange(of: lines.count) {
                guard live else { return }
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private var bottomAnchor: String { "console-bottom" }
}

// MARK: - Small shared pieces

/// A status glyph for a run (spinner while running).
struct RunStatusIcon: View {
    let status: CommandRun.Status
    var body: some View {
        switch status {
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title3)
        case .stopped:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange).font(.title3)
        }
    }
}

/// The outcome summary line: status word + exit code + duration.
struct RunOutcomeLabel: View {
    let status: CommandRun.Status
    let exitCode: Int32?
    let duration: TimeInterval?

    var body: some View {
        HStack(spacing: 8) {
            Text(word)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            if let code = exitCode, status != .running {
                Text("exit \(code)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let d = duration {
                Text("· \(durationText(d))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var word: String {
        switch status {
        case .running: return "Running…"
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
    private var tint: Color {
        switch status {
        case .running: return .secondary
        case .passed: return .green
        case .failed: return .red
        case .stopped: return .orange
        }
    }
    private func durationText(_ d: TimeInterval) -> String {
        d < 60 ? String(format: "%.1fs", d) : String(format: "%dm %ds", Int(d) / 60, Int(d) % 60)
    }
}

/// A compact status chip for the Recent-runs list.
struct RunStatusChip: View {
    let status: CommandRun.Status
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).imageScale(.small)
            Text(word)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
    }
    private var icon: String {
        switch status {
        case .running: return "circle.dotted"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .stopped: return "stop.circle.fill"
        }
    }
    private var word: String {
        switch status {
        case .running: return "Running"
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
    private var tint: Color {
        switch status {
        case .running: return .secondary
        case .passed: return .green
        case .failed: return .red
        case .stopped: return .orange
        }
    }
}
