//
//  ViewModels.swift
//  FireChat
//
//  Created by Sunnatbek on 26/02/26.
//

// MARK: - AuthViewModel.swift
import Foundation
import FirebaseCore

class AuthViewModel: ObservableObject {
    @Published var email    = ""
    @Published var password = ""
    @Published var name     = ""
    @Published var phone    = ""
    @Published var isLoading  = false
    @Published var errorMessage = ""
    @Published var showError    = false
    
    func login() {
        guard !email.isEmpty, !password.isEmpty else {
            show("Please enter email and password"); return
        }
        isLoading = true
        Task {
            do {
                try await AuthService.shared.login(email: email, password: password)
            } catch {
                await MainActor.run { self.show(error.localizedDescription) }
            }
            await MainActor.run { self.isLoading = false }
        }
    }
    
    func register() {
        guard !name.isEmpty, !email.isEmpty, !password.isEmpty else {
            show("Please fill in all fields"); return
        }
        isLoading = true
        Task {
            do {
                try await AuthService.shared.register(
                    email: email, password: password, name: name, phone: phone
                )
            } catch {
                await MainActor.run { self.show(error.localizedDescription) }
            }
            await MainActor.run { self.isLoading = false }
        }
    }
    
    private func show(_ msg: String) {
        errorMessage = msg; showError = true
    }
}

// MARK: - ConversationListViewModel.swift
import Foundation
import Combine
import UIKit

class ConversationListViewModel: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var searchResults: [User] = []
    @Published var searchText = ""
    
    private var cancellables = Set<AnyCancellable>()
    private var conversationCancellable: AnyCancellable?
    
    init() {
        AuthService.shared.$currentUser
            .compactMap { $0?.uid }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uid in
                self?.subscribeToConversations(uid: uid)
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let uid = AuthService.shared.currentUser?.uid else { return }
                self?.subscribeToConversations(uid: uid)
            }
            .store(in: &cancellables)
        
        $searchText
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                guard !query.isEmpty else { self?.searchResults = []; return }
                self?.searchUsers(query: query)
            }
            .store(in: &cancellables)
    }
    
    private func subscribeToConversations(uid: String) {
        conversationCancellable?.cancel()
        conversationCancellable = FirestoreService.shared
            .conversationsPublisher(userId: uid)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] convs in
                self?.conversations = convs
            }
    }
    
    private func searchUsers(query: String) {
        Task {
            let users = (try? await AuthService.shared.searchUsers(query: query)) ?? []
            await MainActor.run {
                self.searchResults = users.filter { $0.uid != AuthService.shared.currentUser?.uid }
            }
        }
    }
    
    var totalUnread: Int {
        guard let uid = AuthService.shared.currentUser?.uid else { return 0 }
        return conversations.reduce(0) { $0 + $1.unreadCount(for: uid) }
    }
}

// MARK: - ChatViewModel.swift
import Foundation
import UIKit
import Combine

class ChatViewModel: ObservableObject {
    @Published var messages:       [Message] = []
    @Published var inputText       = ""
    @Published var isProcessing    = false
    @Published var errorMessage:   String?   = nil
    @Published var replyToMessage: Message?  = nil
    
    let conversationId: String
    
    // ✅ FIX: Is chat currently visible?
    // Controlled by ChatView onAppear/onDisappear.
    // Only markAsRead when chat is active — avoids unnecessary Firestore writes.
    var isChatActive = false {
        didSet {
            if isChatActive { markAsRead() }
        }
    }
    
    private var cancellables  = Set<AnyCancellable>()
    private var typingTimer:    Timer?
    private var isTypingActive = false
    
    init(conversationId: String) {
        self.conversationId = conversationId
        
        FirestoreService.shared.messagesPublisher(conversationId: conversationId)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMessages in
                guard let self else { return }
                self.messages = newMessages
                if self.isChatActive {
                    self.markAsRead()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Send Text
    func sendText() {
        guard !inputText.trimmingCharacters(in: .whitespaces).isEmpty,
              let user = AuthService.shared.currentUser else { return }
        
        var msg = Message(senderId: user.uid, senderName: user.name,
                          content: inputText, type: .text)
        applyReply(&msg)
        inputText = ""
        replyToMessage = nil
        stopTyping()
        
        Task { try? await FirestoreService.shared.sendMessage(msg, to: conversationId) }
    }
    
    // MARK: - Send Image
    func sendImage(_ image: UIImage) {
        guard let user = AuthService.shared.currentUser else { return }
        isProcessing = true
        Task {
            do {
                let base64 = try MediaService.shared.encodeImage(image)
                var msg = Message(senderId: user.uid, senderName: user.name,
                                  content: "", type: .image)
                msg.base64Data = base64
                applyReply(&msg)
                try await FirestoreService.shared.sendMessage(msg, to: conversationId)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run { self.isProcessing = false }
        }
    }
    
    // MARK: - Send Audio
    func sendAudio(url: URL, duration: Double) {
        guard let user = AuthService.shared.currentUser else { return }
        isProcessing = true
        Task {
            do {
                let base64 = try MediaService.shared.encodeAudio(url: url, duration: duration)
                var msg = Message(senderId: user.uid, senderName: user.name,
                                  content: "", type: .audio)
                msg.base64Data    = base64
                msg.audioDuration = duration
                applyReply(&msg)
                try await FirestoreService.shared.sendMessage(msg, to: conversationId)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run { self.isProcessing = false }
        }
    }
    
    // MARK: - Send File
    func sendFile(url: URL) {
        guard let user = AuthService.shared.currentUser else { return }
        isProcessing = true
        Task {
            do {
                let (base64, name, size, mime) = try MediaService.shared.encodeFile(url: url)
                var msg = Message(senderId: user.uid, senderName: user.name,
                                  content: "", type: .file)
                msg.base64Data = base64
                msg.fileName   = name
                msg.fileSize   = size
                msg.fileMime   = mime
                applyReply(&msg)
                try await FirestoreService.shared.sendMessage(msg, to: conversationId)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
            await MainActor.run { self.isProcessing = false }
        }
    }
    
    // MARK: - Delete
    func deleteMessage(_ message: Message) {
        guard let id = message.id else { return }
        FirestoreService.shared.deleteMessage(messageId: id, conversationId: conversationId)
    }
    
    func deleteConversation(completion: @escaping () -> Void) {
        guard let uid = AuthService.shared.currentUser?.uid else { return }
        stopTyping()
        isProcessing = true
        Task {
            do {
                try await FirestoreService.shared.deleteConversation(conversationId, for: uid)
                await MainActor.run {
                    self.isProcessing = false
                    completion()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
    
    // MARK: - Typing
    func userIsTyping() {
        guard let uid = AuthService.shared.currentUser?.uid else { return }
        if !isTypingActive {
            isTypingActive = true
            FirestoreService.shared.setTyping(true, conversationId: conversationId, userId: uid)
        }
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.stopTyping()
        }
    }
    
    func stopTyping() {
        typingTimer?.invalidate()
        typingTimer = nil
        guard let uid = AuthService.shared.currentUser?.uid else { return }
        isTypingActive = false
        FirestoreService.shared.setTyping(false, conversationId: conversationId, userId: uid)
    }
    
    private func forceRemoveTypingFromFirestore() {
        guard let uid = AuthService.shared.currentUser?.uid else { return }
        typingTimer?.invalidate()
        typingTimer = nil
        isTypingActive = false
        FirestoreService.shared.setTyping(false, conversationId: conversationId, userId: uid)
    }
    
    deinit {
        forceRemoveTypingFromFirestore()
    }
    
    // MARK: - Mark as Read
    func markAsRead() {
        guard let uid = AuthService.shared.currentUser?.uid else { return }
        FirestoreService.shared.markAsRead(conversationId: conversationId, userId: uid)
    }
    
    // MARK: - Helpers
    private func applyReply(_ msg: inout Message) {
        if let reply = replyToMessage {
            msg.replyToMessageId  = reply.id
            msg.replyToContent    = reply.isDeleted ? "Message deleted" : reply.previewContent
            msg.replyToSenderName = reply.senderName
        }
    }
    
    var groupedMessages: [(date: String, messages: [Message])] {
        var groups: [String: [Message]] = [:]
        let f = DateFormatter()
        f.dateFormat = "dd MMMM yyyy"
        f.locale = Locale(identifier: "en_US")
        for msg in messages {
            let key = f.string(from: msg.timestamp.dateValue())
            groups[key, default: []].append(msg)
        }
        return groups.keys
            .sorted { f.date(from: $0)! < f.date(from: $1)! }
            .map { (date: $0, messages: groups[$0]!) }
    }
}

// MARK: - ProfileViewModel.swift
import Foundation
import UIKit

class ProfileViewModel: ObservableObject {
    @Published var name:          String   = ""
    @Published var status:        String   = ""
    @Published var selectedImage: UIImage? = nil
    @Published var isLoading      = false
    @Published var errorMessage:  String?  = nil
    
    init() {
        if let user = AuthService.shared.currentUser {
            name   = user.name
            status = user.status
        }
    }
    
    func saveProfile() {
        isLoading = true
        Task {
            var base64: String? = nil
            if let image = selectedImage {
                base64 = MediaService.shared.encodeProfileImage(image)
                if base64 == nil {
                    await MainActor.run {
                        self.errorMessage = "Image is too large. Please select a smaller image (max 80KB)."
                        self.isLoading = false
                    }
                    return
                }
            }
            AuthService.shared.updateProfile(name: name, status: status, base64Image: base64)
            await MainActor.run {
                self.selectedImage = nil
                self.isLoading = false
            }
        }
    }
    
    func signOut() {
        try? AuthService.shared.signOut()
    }
    
    func deleteAccount(password: String) {
        guard !password.isEmpty else {
            errorMessage = "Please enter your password"
            return
        }
        isLoading = true
        Task {
            do {
                try await AuthService.shared.deleteAccount(password: password)
            } catch {
                await MainActor.run {
                    self.errorMessage = "Error: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}
