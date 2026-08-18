import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var showFileImporter = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Theme.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    header
                    linkInput
                    dividerRow
                    nowPlayingSection
                    localFileRow
                    isolateButton
                    statusRow
                    resultSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.interactively)

            Button {
                state.showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(12)
            }
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $state.showSettings) {
            SettingsSheet()
                .environmentObject(state)
        }
        .onAppear { state.startNowPlayingRefresh() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            LogoGlyph()
            Text("Backtrack")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
            Text("Extract and play the instrumental\nfrom any Spotify track.")
                .font(.system(size: 17))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private var linkInput: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.lime)
            TextField(
                "", text: $state.linkText,
                prompt: Text("Paste Spotify link").foregroundStyle(Theme.secondaryText)
            )
            .font(.system(size: 17))
            .foregroundStyle(.white)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            Button {
                state.pasteFromClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .card(highlighted: AppState.isTrackLink(state.linkText))
    }

    private var dividerRow: some View {
        HStack(spacing: 12) {
            line
            Text("Or use currently playing song on Spotify")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
            line
        }
    }

    private var line: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var nowPlayingSection: some View {
        if let np = state.nowPlaying, np.url != nil {
            HStack(spacing: 14) {
                AsyncImage(url: np.artwork.flatMap(URL.init(string:))) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.15))
                        .overlay(Image(systemName: "music.note")
                            .foregroundStyle(Theme.secondaryText))
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(np.title ?? "Unknown track")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(np.artist ?? "")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.green)
                            .frame(width: 14, height: 14)
                            .overlay(Image(systemName: "music.note")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.black))
                        Text("Spotify")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.green)
                    }
                }
                Spacer()
                if np.playing { EqualizerBars() }
            }
            .padding(14)
            .card(highlighted: state.usesNowPlaying)
            .contentShape(Rectangle())
            .onTapGesture { state.linkText = "" }
        } else if state.client == nil {
            Button { state.showSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(Theme.lime)
                    Text("Connect to your desktop server to get started")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(16)
                .card()
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(Theme.secondaryText)
                Text("Nothing playing on Spotify right now")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
            }
            .padding(16)
            .card()
        }
    }

    private var localFileRow: some View {
        Button { showFileImporter = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.plus")
                    .foregroundStyle(Theme.lime)
                Text("Or isolate a local audio file — fully on-device")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .card()
        }
        .disabled(state.isWorking)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [UTType.audio]) { result in
            if case .success(let url) = result {
                state.isolateLocalFile(url)
            }
        }
    }

    private var isolateButton: some View {
        Button {
            state.isolate()
        } label: {
            HStack(spacing: 10) {
                if state.isWorking {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                }
                Text(state.isWorking ? "Isolating…" : "Isolate Background Music")
                    .font(.system(size: 20, weight: .bold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 66)
            .background(
                Capsule().fill(LinearGradient(
                    colors: [Theme.lime, Theme.limeDeep],
                    startPoint: .top, endPoint: .bottom)))
            .shadow(color: Theme.limeDeep.opacity(0.45), radius: 22, y: 4)
        }
        .disabled(state.isWorking || state.sourceURL == nil)
        .opacity(state.sourceURL == nil && !state.isWorking ? 0.45 : 1)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch state.phase {
        case .working(let label):
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                if let elapsed = state.job?.elapsed, elapsed > 1 {
                    Text("· \(Int(elapsed))s")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(Theme.secondaryText.opacity(0.7))
                }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .card()
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if case .ready = state.phase, let job = state.job {
            PlayerCard(job: job, player: state.player)
        }
    }
}

struct PlayerCard: View {
    var job: JobStatus
    @ObservedObject var player: PlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Isolated Instrumental")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(Theme.green)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Theme.lime).frame(width: 6, height: 6)
                    Text(timeString(player.currentTime))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("\(job.title ?? "Track") (Instrumental)")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(job.artist ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryText)
            }

            WaveformView(
                samples: player.waveform,
                progress: player.duration > 0 ? player.currentTime / player.duration : 0
            ) { fraction in
                player.seek(to: fraction * player.duration)
            }
            .frame(height: 110)
            .padding(.top, 4)

            HStack {
                Text(timeString(player.currentTime))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.lime)
                Spacer()
                Text(timeString(player.duration))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }

            HStack {
                Spacer()
                Button { player.skip(-15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                Spacer()
                Button { player.playPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 74, height: 74)
                        .background(
                            Circle().fill(LinearGradient(
                                colors: [Theme.lime, Theme.limeDeep],
                                startPoint: .top, endPoint: .bottom)))
                        .shadow(color: Theme.limeDeep.opacity(0.5), radius: 18)
                }
                Spacer()
                Button { player.skip(15) } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(18)
        .card()
    }
}
