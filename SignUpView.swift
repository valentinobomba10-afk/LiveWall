import SwiftUI

/// Root of the control window. Shows the auth screen until the user has a
/// Supabase session (or chooses to continue without one), then the browser.
struct LiveWallRootView: View {
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var movies: MovieStore
    @ObservedObject private var auth = AuthService.shared
    @AppStorage("skippedSignIn") private var skippedSignIn = false

    var body: some View {
        if auth.isSignedIn || skippedSignIn {
            BrowseView(vm: vm, library: library, movies: movies)
        } else {
            AuthView(onSkip: { skippedSignIn = true })
        }
    }
}

/// Sign in / create account, backed by Supabase Auth. Styled to match the app —
/// dark plum canvas, soft gradient wash, glass card.
struct AuthView: View {
    var onSkip: () -> Void
    @ObservedObject private var auth = AuthService.shared

    private enum Mode { case signIn, signUp }
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false

    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.063, blue: 0.086).ignoresSafeArea()
            LinearGradient(colors: [.purple.opacity(0.28), .blue.opacity(0.12), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                card
                Spacer()
                Button("Continue without an account", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 26)
            }
        }
        .frame(minWidth: 460, minHeight: 560)
    }

    private var card: some View {
        VStack(spacing: 20) {
            // Mark
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 62, height: 62)
                .overlay(Image(systemName: "sparkles.tv.fill").font(.system(size: 28)).foregroundStyle(.white))
                .shadow(color: .purple.opacity(0.5), radius: 16, y: 6)

            VStack(spacing: 5) {
                Text(mode == .signIn ? "Welcome back" : "Create your account")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                Text(mode == .signIn ? "Sign in to sync across your Macs."
                                     : "One account, all your wallpapers and widgets.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            // Segmented mode switch
            HStack(spacing: 0) {
                segment("Sign In", .signIn)
                segment("Create Account", .signUp)
            }
            .padding(3)
            .background(.white.opacity(0.07), in: Capsule())

            VStack(spacing: 11) {
                field(icon: "envelope.fill", placeholder: "Email", text: $email, secure: false)
                passwordField
            }

            if let error = auth.errorMessage {
                Text(error)
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if auth.pendingConfirmation {
                Text("Check your email to confirm your account, then sign in.")
                    .font(.system(size: 12)).foregroundStyle(.green)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                ZStack {
                    if auth.isWorking { ProgressView().controlSize(.small).tint(.white) }
                    else { Text(mode == .signIn ? "Sign In" : "Create Account")
                            .font(.system(size: 15, weight: .semibold)) }
                }
                .frame(maxWidth: .infinity).frame(height: 44)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(auth.isWorking)
            .opacity(auth.isWorking ? 0.7 : 1)

            Text("Your password is sent securely to Supabase and never stored on this Mac.")
                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 14)
    }

    private func segment(_ title: String, _ value: Mode) -> some View {
        let active = mode == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { mode = value; auth.errorMessage = nil; auth.pendingConfirmation = false }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? .white : .white.opacity(0.55))
                .frame(maxWidth: .infinity).frame(height: 32)
                .background { if active { Capsule().fill(Color.accentColor) } }
        }
        .buttonStyle(.plain)
    }

    private func field(icon: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).frame(width: 18)
            if secure {
                SecureField(placeholder, text: text).textFieldStyle(.plain)
            } else {
                TextField(placeholder, text: text).textFieldStyle(.plain)
            }
        }
        .font(.system(size: 14)).foregroundStyle(.white)
        .padding(.horizontal, 13).frame(height: 44)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private var passwordField: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5)).frame(width: 18)
            Group {
                if showPassword { TextField("Password", text: $password).textFieldStyle(.plain) }
                else { SecureField("Password", text: $password).textFieldStyle(.plain) }
            }
            .font(.system(size: 14)).foregroundStyle(.white)
            Button { showPassword.toggle() } label: {
                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 13).frame(height: 44)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private func submit() {
        Task {
            if mode == .signIn { await auth.signIn(email: email, password: password) }
            else { await auth.signUp(email: email, password: password) }
        }
    }
}
