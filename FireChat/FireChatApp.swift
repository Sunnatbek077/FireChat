//
//  FireChatApp.swift
//  FireChat
//
//  Created by Sunnatbek on 26/02/26.
//

// MARK: - FireChatApp.swift
import SwiftUI
import FirebaseCore
import Combine

@main
struct FireChatApp: App {
    init() { FirebaseApp.configure() }
    
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(AuthService.shared)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var authService: AuthService
    
    var body: some View {
        Group {
            if authService.isAuthenticated { MainTabView() }
            else { AuthView() }
        }
        .onAppear  { authService.setOnlineStatus(true) }
        .onDisappear { authService.setOnlineStatus(false) }
    }
}

// MARK: - AuthView.swift
import SwiftUI

struct AuthView: View {
    @State private var showLogin = true
    var body: some View {
        NavigationStack {
            if showLogin { LoginView(showLogin: $showLogin) }
            else { RegisterView(showLogin: $showLogin) }
        }
    }
}

struct LoginView: View {
    @Binding var showLogin: Bool
    @StateObject private var vm = AuthViewModel()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 64)).foregroundColor(.green)
                    Text("FireChat").font(.largeTitle.bold())
                    Text("Secure and fast messaging")
                        .font(.subheadline).foregroundColor(.secondary)
                }.padding(.top, 60)
                
                VStack(spacing: 16) {
                    AuthTextField(icon: "envelope.fill", placeholder: "Email", text: $vm.email)
                        .keyboardType(.emailAddress).autocapitalization(.none)
                    AuthTextField(icon: "lock.fill", placeholder: "Password", text: $vm.password, isSecure: true)
                }.padding(.horizontal)
                
                Button(action: vm.login) {
                    Group {
                        if vm.isLoading { ProgressView().tint(.white) }
                        else { Text("Login").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.green).foregroundColor(.white).cornerRadius(14)
                }.padding(.horizontal).disabled(vm.isLoading)
                
                Button { showLogin = false } label: {
                    HStack(spacing: 4) {
                        Text("Don't have an account?").foregroundColor(.secondary)
                        Text("Sign Up").foregroundColor(.green).fontWeight(.semibold)
                    }
                }
            }
        }
        .alert("Error", isPresented: $vm.showError) { Button("OK") {} } message: { Text(vm.errorMessage) }
        .navigationBarHidden(true)
    }
}

struct RegisterView: View {
    @Binding var showLogin: Bool
    @StateObject private var vm = AuthViewModel()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 64)).foregroundColor(.green)
                    Text("Create Account").font(.largeTitle.bold())
                }.padding(.top, 50)
                
                VStack(spacing: 16) {
                    AuthTextField(icon: "person.fill", placeholder: "To'liq ism", text: $vm.name)
                    AuthTextField(icon: "phone.fill", placeholder: "Telefon", text: $vm.phone)
                        .keyboardType(.phonePad)
                    AuthTextField(icon: "envelope.fill", placeholder: "Email", text: $vm.email)
                        .keyboardType(.emailAddress).autocapitalization(.none)
                    AuthTextField(icon: "lock.fill", placeholder: "Parol", text: $vm.password, isSecure: true)
                }.padding(.horizontal)
                
                Button(action: vm.register) {
                    Group {
                        if vm.isLoading { ProgressView().tint(.white) }
                        else { Text("Sign Up").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background(Color.green).foregroundColor(.white).cornerRadius(14)
                }.padding(.horizontal).disabled(vm.isLoading)
                
                Button { showLogin = true } label: {
                    HStack(spacing: 4) {
                        Text("Already have an account?").foregroundColor(.secondary)
                        Text("Login").foregroundColor(.green).fontWeight(.semibold)
                    }
                }.padding(.bottom)
            }
        }
        .alert("Error", isPresented: $vm.showError) { Button("OK") {} } message: { Text(vm.errorMessage) }
        .navigationBarHidden(true)
    }
}

struct AuthTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(.green).frame(width: 20)
            if isSecure { SecureField(placeholder, text: $text) }
            else { TextField(placeholder, text: $text) }
        }
        .padding(14).background(Color(.systemGray6)).cornerRadius(12)
    }
}

// MARK: - MainTabView.swift
import SwiftUI

struct MainTabView: View {
    @StateObject private var convVM = ConversationListViewModel()
    
    var body: some View {
        TabView {
            ConversationListView(vm: convVM)
                .tabItem { Label("Chats", systemImage: "message.fill") }
                .badge(convVM.totalUnread > 0 ? "\(convVM.totalUnread)" : nil)
            
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.fill") }
        }
        .tint(.green)
    }
}

// MARK: - ConversationListView.swift

struct ConversationListView: View {
    @ObservedObject var vm: ConversationListViewModel
    @State private var showNewChat = false
    @State private var navPath = NavigationPath()
    
    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                SearchBar(text: $vm.searchText).padding(.horizontal).padding(.vertical, 8)
                
                if !vm.searchText.isEmpty {
                    List(vm.searchResults) { user in
                        UserRowView(user: user)
                            .contentShape(Rectangle())
                            .onTapGesture { startChat(with: user) }
                    }.listStyle(.plain)
                } else if vm.conversations.isEmpty {
                    EmptyChatsView()
                } else {
                    List {
                        ForEach(vm.conversations) { conv in
                            let uid = AuthService.shared.currentUser?.uid ?? ""
                            NavigationLink(value: conv) {
                                ConversationRowView(conversation: conv)
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteConversation(conv)
                                } label: {
                                    Label("Delete", systemImage: "trash.fill")
                                }
                            }
                        }
                    }.listStyle(.plain)
                }
            }
            .navigationTitle("FireChat")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNewChat = true } label: {
                        Image(systemName: "square.and.pencil").foregroundColor(.green)
                    }
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView { user in startChat(with: user) }
            }
            // Conversation -> ChatView navigation
            .navigationDestination(for: Conversation.self) { conv in
                let uid = AuthService.shared.currentUser?.uid ?? ""
                ChatView(
                    conversationId: conv.id ?? "",
                    displayName: conv.displayName(for: uid)
                )
            }
            // Yangi chat: ID dan ChatView ga o'tish
            .navigationDestination(for: ChatDestination.self) { dest in
                ChatView(conversationId: dest.conversationId, displayName: dest.displayName)
            }
        }
    }
    
    func startChat(with user: User) {
        showNewChat = false
        vm.searchText = ""
        let currentUser = AuthService.shared.currentUser
        let displayName = user.name
        Task {
            if let convId = try? await FirestoreService.shared.createOrGetConversation(with: user) {
                await MainActor.run {
                    navPath.append(ChatDestination(conversationId: convId, displayName: displayName))
                }
            }
        }
    }
    
    func deleteConversation(_ conversation: Conversation) {
        guard let uid = AuthService.shared.currentUser?.uid,
              let convId = conversation.id else { return }
        Task {
            try? await FirestoreService.shared.deleteConversation(convId, for: uid)
        }
    }
}

// NavigationPath uchun yordamchi struct
struct ChatDestination: Hashable {
    let conversationId: String
    let displayName: String
}

struct ConversationRowView: View {
    let conversation: Conversation
    @EnvironmentObject var authService: AuthService
    // TUZATISH: typing expire (5 soniya) uchun UI ni yangilab turuvchi timer
    @State private var tick = false
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        let uid = authService.currentUser?.uid ?? ""
        HStack(spacing: 12) {
            AvatarView(base64: nil, name: conversation.displayName(for: uid), size: 52)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.displayName(for: uid))
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(conversation.formattedTime)
                        .font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    // tick o'zgarishi view'ni yangilaydi → isOtherUserTyping qayta hisoblanadi
                    let _ = tick
                    if conversation.isOtherUserTyping(currentUserId: uid) {
                        Text("typing...").font(.subheadline).foregroundColor(.green).italic()
                    } else {
                        if conversation.lastMessageSenderId == uid {
                            MessageStatusIcon(status: .delivered)
                        }
                        Text(conversation.lastMessagePreview)
                            .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    let unread = conversation.unreadCount(for: uid)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.caption2.bold()).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.green).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .onReceive(timer) { _ in tick.toggle() }
    }
}

struct EmptyChatsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 80)).foregroundColor(.green.opacity(0.3))
            Text("No chats yet").font(.title2.bold()).foregroundColor(.secondary)
            Text("Tap the button above\nto start a new chat")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            Spacer()
        }
    }
}

struct NewChatView: View {
    let onSelect: (User) -> Void
    @State private var search = ""
    @State private var results: [User] = []
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            VStack {
                SearchBar(text: $search).padding()
                    .onChange(of: search) { q in
                        Task { results = (try? await AuthService.shared.searchUsers(query: q)) ?? [] }
                    }
                List(results) { user in
                    UserRowView(user: user)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(user); dismiss() }
                }.listStyle(.plain)
            }
            .navigationTitle("New Chat").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundColor(.green)
                }
            }
        }
    }
}

struct UserRowView: View {
    let user: User
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(base64: user.profileImageBase64, name: user.name, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name).font(.system(size: 16, weight: .semibold))
                Text(user.isOnline ? "Online" : "last seen: \(user.lastSeenText)")
                    .font(.caption)
                    .foregroundColor(user.isOnline ? .green : .secondary)
            }
        }.padding(.vertical, 4)
    }
}

// MARK: - AvatarView (Base64 asosida — Storage yo'q)

struct AvatarView: View {
    let base64: String?
    let name: String
    let size: CGFloat
    
    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [.green.opacity(0.7), .teal],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: size, height: size)
            
            if let b64 = base64,
               !b64.isEmpty,
               let data = Data(base64Encoded: b64),
               let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

struct SearchBar: View {
    @Binding var text: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Search...", text: $text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(10).background(Color(.systemGray6)).cornerRadius(12)
    }
}

struct MessageStatusIcon: View {
    let status: MessageStatus
    var body: some View {
        Group {
            switch status {
            case .sending:   Image(systemName: "clock")
            case .sent:      Image(systemName: "checkmark")
            case .delivered: Image(systemName: "checkmark")
            case .read:      Image(systemName: "checkmark.circle.fill").foregroundColor(.blue.opacity(0.9))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white.opacity(0.75))
    }
}
