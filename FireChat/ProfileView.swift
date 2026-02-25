//
//  ProfileView.swift
//  FireChat
//
//  Created by Sunnatbek on 26/02/26.
//

// MARK: - ProfileView.swift
import SwiftUI
import PhotosUI

struct ProfileView: View {
    @StateObject private var vm = ProfileViewModel()
    @EnvironmentObject var authService: AuthService
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var showSignOutAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var deletePassword = ""
    
    var body: some View {
        NavigationStack {
            List {
                // ---- Profile header ----
                Section {
                    HStack(spacing: 16) {
                        ZStack(alignment: .bottomTrailing) {
                            if let img = vm.selectedImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                            } else {
                                AvatarView(
                                    base64: authService.currentUser?.profileImageBase64,
                                    name: authService.currentUser?.name ?? "U",
                                    size: 80
                                )
                            }
                            
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 26, height: 26)
                                    .overlay(
                                        Image(systemName: "camera.fill")
                                            .foregroundColor(.white)
                                            .font(.system(size: 12))
                                    )
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(authService.currentUser?.name ?? "")
                                .font(.title3.bold())
                            
                            Text(authService.currentUser?.phone.isEmpty == false
                                 ? authService.currentUser!.phone
                                 : authService.currentUser?.email ?? "")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                Text("Online")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    
                    if vm.selectedImage != nil {
                        Label("Max image size: 80KB (auto compressed)", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // ---- Edit info ----
                Section("Personal Information") {
                    HStack {
                        Label("Name", systemImage: "person.fill")
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        TextField("Your name", text: $vm.name)
                    }
                    
                    HStack {
                        Label("Status", systemImage: "pencil.circle")
                            .foregroundColor(.secondary)
                            .frame(width: 110, alignment: .leading)
                        TextField("Your status", text: $vm.status)
                    }
                }
                
                // ---- Error message ----
                if let err = vm.errorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                
                // ---- Save button ----
                let hasChanges = vm.name != authService.currentUser?.name
                              || vm.status != authService.currentUser?.status
                              || vm.selectedImage != nil
                
                if hasChanges {
                    Section {
                        Button {
                            vm.errorMessage = nil
                            vm.saveProfile()
                        } label: {
                            HStack {
                                if vm.isLoading {
                                    ProgressView().padding(.trailing, 4)
                                }
                                Text("Save")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .foregroundColor(.white)
                        .listRowBackground(Color.green)
                    }
                }
                
                // ---- Settings ----
                Section("Settings") {
                    NavigationLink(destination: NotificationsSettingsView()) {
                        Label("Notifications", systemImage: "bell.fill")
                    }
                    NavigationLink(destination: PrivacySettingsView()) {
                        Label("Privacy", systemImage: "lock.fill")
                    }
                    NavigationLink(destination: StorageSettingsView()) {
                        Label("Storage & Data", systemImage: "internaldrive.fill")
                    }
                    NavigationLink(destination: ChatsSettingsView()) {
                        Label("Chats", systemImage: "message.fill")
                    }
                }
                
                // ---- Other ----
                Section("Other") {
                    NavigationLink(destination: HelpView()) {
                        Label("Help", systemImage: "questionmark.circle.fill")
                    }
                    
                    Button { shareApp() } label: {
                        Label("Share with friends", systemImage: "square.and.arrow.up.fill")
                    }
                    .foregroundColor(.primary)
                }
                
                // ---- Sign out + Delete account ----
                Section {
                    Button(role: .destructive) {
                        showSignOutAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                            Text("Sign Out")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    
                    Button(role: .destructive) {
                        deletePassword = ""
                        showDeleteAccountAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.minus")
                            Text("Delete Account")
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .alert("Are you sure you want to sign out?", isPresented: $showSignOutAlert) {
                Button("Sign Out", role: .destructive) { vm.signOut() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Account", isPresented: $showDeleteAccountAlert) {
                SecureField("Your password", text: $deletePassword)
                Button("Delete", role: .destructive) {
                    vm.deleteAccount(password: deletePassword)
                }
                Button("Cancel", role: .cancel) { deletePassword = "" }
            } message: {
                Text("All your data and chats will be permanently deleted.\nThis action cannot be undone!\n\nEnter your password to continue.")
            }
            .alert("Error", isPresented: .init(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
            .onChange(of: selectedPhoto) { item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        await MainActor.run {
                            vm.selectedImage = img
                        }
                    }
                }
            }
        }
    }
    
    func shareApp() {
        let vc = UIActivityViewController(
            activityItems: ["FireChat — Try this fast and free chat app!"],
            applicationActivities: nil
        )
        
        if let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?
            .windows
            .first?
            .rootViewController {
            rootVC.present(vc, animated: true)
        }
    }
}

// MARK: - Settings sub-views

struct NotificationsSettingsView: View {
    @State private var msgNotif = true
    @State private var groupNotif = true
    @State private var sound = true
    @State private var vibration = true
    @State private var preview = true
    
    var body: some View {
        List {
            Section("Messages") {
                Toggle("Message notifications", isOn: $msgNotif)
                Toggle("Group notifications", isOn: $groupNotif)
            }
            Section("Sound") {
                Toggle("Sound", isOn: $sound)
                Toggle("Vibration", isOn: $vibration)
            }
            Section {
                Toggle("Show message preview", isOn: $preview)
            }
        }
        .navigationTitle("Notifications")
        .tint(.green)
    }
}

struct PrivacySettingsView: View {
    @State private var lastSeen = 0
    @State private var profilePhoto = 0
    @State private var readReceipts = true
    @State private var twoStep = false
    
    let options = ["Everyone", "My Contacts", "Nobody"]
    
    var body: some View {
        List {
            Section("Who can see") {
                Picker("Last seen", selection: $lastSeen) {
                    ForEach(0..<options.count, id: \.self) {
                        Text(options[$0])
                    }
                }
                
                Picker("Profile photo", selection: $profilePhoto) {
                    ForEach(0..<options.count, id: \.self) {
                        Text(options[$0])
                    }
                }
            }
            
            Section("Messages") {
                Toggle("Read receipts", isOn: $readReceipts)
            }
            
            Section("Account") {
                Toggle("Two-step verification", isOn: $twoStep)
                    .tint(.green)
            }
        }
        .navigationTitle("Privacy")
        .tint(.green)
    }
}

struct StorageSettingsView: View {
    var body: some View {
        List {
            Section("Data") {
                HStack {
                    Text("Where are files stored?")
                    Spacer()
                    Text("Firestore")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Image limit")
                    Spacer()
                    Text("200 KB")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Audio limit")
                    Spacer()
                    Text("60 seconds")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("File size limit")
                    Spacer()
                    Text("700 KB")
                        .foregroundColor(.secondary)
                }
            }
            
            Section {
                Button("Clear temporary files") {
                    let tmp = FileManager.default.temporaryDirectory
                    if let files = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) {
                        files.forEach {
                            try? FileManager.default.removeItem(at: tmp.appendingPathComponent($0))
                        }
                    }
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle("Storage")
    }
}

struct ChatsSettingsView: View {
    @State private var fontSize = 1
    
    var body: some View {
        List {
            Section("Appearance") {
                Picker("Text size", selection: $fontSize) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                }
            }
        }
        .navigationTitle("Chats")
        .tint(.green)
    }
}

struct HelpView: View {
    let faqs: [(String, String)] = [
        ("I can't send an image", "Images must be smaller than 200KB. The app will try to compress automatically."),
        ("I can't send audio", "Audio must be a maximum of 60 seconds."),
        ("I can't send a file", "Files must be smaller than 700KB."),
        ("Where is my data stored?", "All data is securely stored in Firebase Firestore. Firebase Storage is not used.")
    ]
    
    var body: some View {
        List {
            Section("Frequently Asked Questions") {
                ForEach(faqs, id: \.0) { faq in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(faq.0)
                            .fontWeight(.medium)
                        Text(faq.1)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section("Version") {
                HStack {
                    Text("App version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Help")
    }
}
