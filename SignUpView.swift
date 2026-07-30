import SwiftUI

/// Blocks the wallpaper browser until the person using this Mac creates a
/// LiveWall profile. Passwords are never stored locally.
struct LiveWallRootView: View {
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var pets: DesktopPetManager
    @AppStorage("liveWallSignedUp") private var signedUp = false

    var body: some View {
        if signedUp {
            BrowseView(vm: vm, library: library, pets: pets)
        } else {
            SignUpView { name, email in
                UserDefaults.standard.set(name, forKey: "liveWallProfileName")
                UserDefaults.standard.set(email, forKey: "liveWallProfileEmail")
                signedUp = true
                pets.start()
            }
        }
    }
}

struct SignUpView: View {
    let complete: (String, String) -> Void
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var error = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.04, blue: 0.07), Color(red: 0.08, green: 0.05, blue: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "sparkles.tv.fill").font(.system(size: 48)).foregroundStyle(LinearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("Welcome to LiveWall").font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Create your LiveWall profile to start using wallpapers.")
                    .font(.system(size: 14)).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).frame(maxWidth: 390)

                VStack(spacing: 10) {
                    TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
                    TextField("Email address", text: $email).textFieldStyle(.roundedBorder)
                    SecureField("Password (at least 10 characters)", text: $password).textFieldStyle(.roundedBorder)
                    SecureField("Confirm password", text: $confirmPassword).textFieldStyle(.roundedBorder)
                }.frame(width: 330)

                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.red).frame(width: 330, alignment: .leading) }
                Button("Create LiveWall Account", action: create).buttonStyle(PrimaryGlassButtonStyle()).keyboardShortcut(.defaultAction)
                Text("Your profile details remain on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center).frame(maxWidth: 390)
            }
            .padding(36).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= 2 else { error = "Enter a display name."; return }
        guard trimmedEmail.contains("@") && trimmedEmail.contains(".") else { error = "Enter a valid email address."; return }
        guard password.count >= 10 else { error = "Use a password with at least 10 characters."; return }
        guard password == confirmPassword else { error = "Passwords do not match."; return }
        complete(trimmedName, trimmedEmail)
    }
}
