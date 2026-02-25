//
//  Services.swift
//  FireChat
//
//  Created by Sunnatbek on 26/02/26.
//

// MARK: - AuthService.swift
import Foundation
import FirebaseAuth
import FirebaseFirestore
import Combine

class AuthService: ObservableObject {
    static let shared = AuthService()
    
    @Published var currentUser: User?
    @Published var isAuthenticated = false
    
    private var authStateListener: AuthStateDidChangeListenerHandle?
    private let db = Firestore.firestore()
    
    init() {
        authStateListener = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            if let user = firebaseUser {
                self?.fetchUser(uid: user.uid)
                self?.isAuthenticated = true
            } else {
                self?.currentUser = nil
                self?.isAuthenticated = false
            }
        }
    }
    
    func fetchUser(uid: String) {
        db.collection("users").document(uid).addSnapshotListener { [weak self] snapshot, _ in
            guard let data = snapshot, data.exists else { return }
            self?.currentUser = try? data.data(as: User.self)
        }
    }
    
    func register(email: String, password: String, name: String, phone: String) async throws {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        let user = User(uid: result.user.uid, name: name, phone: phone, email: email)
        try db.collection("users").document(result.user.uid).setData(from: user)
    }
    
    func login(email: String, password: String) async throws {
        try await Auth.auth().signIn(withEmail: email, password: password)
    }
    
    func signOut() throws {
        if let uid = Auth.auth().currentUser?.uid {
            db.collection("users").document(uid).updateData([
                "isOnline": false,
                "lastSeen": Timestamp(date: Date())
            ])
        }
        try Auth.auth().signOut()
    }
    
    func updateProfile(name: String, status: String, base64Image: String?) {
        guard let uid = currentUser?.uid else { return }
        var data: [String: Any] = ["name": name, "status": status]
        if let img = base64Image { data["profileImageBase64"] = img }
        db.collection("users").document(uid).updateData(data)
    }
    
    func setOnlineStatus(_ isOnline: Bool) {
        guard let uid = currentUser?.uid else { return }
        db.collection("users").document(uid).updateData([
            "isOnline": isOnline,
            "lastSeen": Timestamp(date: Date())
        ])
    }
    
    func searchUsers(query: String) async throws -> [User] {
        guard !query.isEmpty else { return [] }
        let snapshot = try await db.collection("users")
            .whereField("name", isGreaterThanOrEqualTo: query)
            .whereField("name", isLessThan: query + "\u{f8ff}")
            .limit(to: 20)
            .getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: User.self) }
    }
    
    func deleteAccount(password: String) async throws {
        guard let firebaseUser = Auth.auth().currentUser,
              let email = firebaseUser.email,
              let uid = currentUser?.uid else {
            throw NSError(domain: "AuthError", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "User not found"])
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await firebaseUser.reauthenticate(with: credential)
        try await FirestoreService.shared.deleteAllConversations(for: uid)
        try await db.collection("users").document(uid).delete()
        try await firebaseUser.delete()
    }
}

// MARK: - FirestoreService.swift
import FirebaseFirestore
import Combine

class FirestoreService: ObservableObject {
    static let shared = FirestoreService()
    private let db = Firestore.firestore()
    
    private var listeners:   [String: ListenerRegistration] = [:]
    private var msgSubjects:  [String: CurrentValueSubject<[Message], Never>] = [:]
    private var convSubjects: [String: CurrentValueSubject<[Conversation], Never>] = [:]
    
    // MARK: - Conversations
    
    func conversationsPublisher(userId: String) -> AnyPublisher<[Conversation], Never> {
        listeners["conv_\(userId)"]?.remove()
        
        let subject = CurrentValueSubject<[Conversation], Never>([])
        convSubjects[userId] = subject
        
        let listener = db.collection("conversations")
            .whereField("participantIds", arrayContains: userId)
            .addSnapshotListener { snapshot, error in
                if let error = error {
                    print("Conversations listener error: \(error.localizedDescription)")
                    return
                }
                let conversations = (snapshot?.documents
                    .compactMap { try? $0.data(as: Conversation.self) }
                    .filter { $0.isVisible(for: userId) }
                    ?? [])
                    .sorted { $0.lastMessageTime.dateValue() > $1.lastMessageTime.dateValue() }
                subject.send(conversations)
            }
        
        listeners["conv_\(userId)"] = listener
        return subject.eraseToAnyPublisher()
    }
    
    func createOrGetConversation(with otherUser: User) async throws -> String {
        guard let currentUser = AuthService.shared.currentUser,
              let currentUid = currentUser.id,
              let otherUid = otherUser.id else { throw AppError.missingUser }
        
        let snapshot = try await db.collection("conversations")
            .whereField("participantIds", arrayContains: currentUid)
            .getDocuments()
        
        for doc in snapshot.documents {
            if let conv = try? doc.data(as: Conversation.self),
               conv.participantIds.contains(otherUid), !conv.isGroup {
                return doc.documentID
            }
        }
        
        let conv = Conversation(
            participantIds: [currentUid, otherUid],
            participantNames: [currentUid: currentUser.name, otherUid: otherUser.name],
            lastMessage: "",
            lastMessageType: .text,
            lastMessageTime: Timestamp(date: Date()),
            lastMessageSenderId: currentUid,
            unreadCounts: [currentUid: 0, otherUid: 0],
            isGroup: false,
            createdAt: Timestamp(date: Date()),
            typingInfo: [:],
            deletedFor: [:]
        )
        let ref = try db.collection("conversations").addDocument(from: conv)
        return ref.documentID
    }
    
    // MARK: - Messages
    // ✅ FIX: Race condition removed.
    // First we read the conversation document once to get clearDate (getDocument),
    // then we start the messages listener. This guarantees clearDate is never nil.
    
    func messagesPublisher(conversationId: String) -> AnyPublisher<[Message], Never> {
        // Remove old listeners
        listeners["msg_\(conversationId)"]?.remove()
        listeners["conv_clear_\(conversationId)"]?.remove()
        
        let subject = CurrentValueSubject<[Message], Never>([])
        msgSubjects[conversationId] = subject
        
        let uid = AuthService.shared.currentUser?.uid ?? ""
        let convRef = db.collection("conversations").document(conversationId)
        
        // ✅ MAIN FIX:
        // Store clearDate as atomic variable on main queue.
        // convListener and msgListener run on the same queue — no race condition.
        
        var clearDate: Date? = nil
        
        // Step 1: Read conversation document once before starting messages listener
        convRef.getDocument { snap, _ in
            if let conv = try? snap?.data(as: Conversation.self) {
                clearDate = conv.clearTimestamp(for: uid)
            }
            
            // Step 2: Start messages listener after clearDate is ready
            let msgListener = convRef.collection("messages")
                .order(by: "timestamp")
                .addSnapshotListener { [weak subject] snapshot, error in
                    if let error = error {
                        print("Messages error: \(error.localizedDescription)")
                        return
                    }
                    let messages = snapshot?.documents
                        .compactMap { try? $0.data(as: Message.self) }
                        .filter { msg in
                            guard let cd = clearDate else { return true }
                            return msg.timestamp.dateValue() > cd
                        } ?? []
                    subject?.send(messages)
                }
            
            self.listeners["msg_\(conversationId)"] = msgListener
        }
        
        // Step 3: Listen for conversation changes (e.g., deleteConversation) to update clearDate
        let convListener = convRef.addSnapshotListener { [weak self] snap, _ in
            guard let self else { return }
            let conv = try? snap?.data(as: Conversation.self)
            let newClearDate = conv?.clearTimestamp(for: uid)
            
            if newClearDate != clearDate {
                clearDate = newClearDate
                self.refreshMessages(conversationId: conversationId, uid: uid, clearDate: clearDate, subject: subject)
            }
        }
        
        listeners["conv_clear_\(conversationId)"] = convListener
        
        return subject.eraseToAnyPublisher()
    }
    
    /// Refresh messages when clearDate changes
    private func refreshMessages(
        conversationId: String,
        uid: String,
        clearDate: Date?,
        subject: CurrentValueSubject<[Message], Never>
    ) {
        db.collection("conversations")
            .document(conversationId)
            .collection("messages")
            .order(by: "timestamp")
            .getDocuments { snapshot, _ in
                let messages = snapshot?.documents
                    .compactMap { try? $0.data(as: Message.self) }
                    .filter { msg in
                        guard let cd = clearDate else { return true }
                        return msg.timestamp.dateValue() > cd
                    } ?? []
                subject.send(messages)
            }
    }
    
    // MARK: - Send Message
    
    func sendMessage(_ message: Message, to conversationId: String) async throws {
        guard let currentUid = AuthService.shared.currentUser?.uid else { return }
        
        let ref = try db.collection("conversations")
            .document(conversationId)
            .collection("messages")
            .addDocument(from: message)
        
        try await ref.updateData(["status": MessageStatus.sent.rawValue])
        
        var updateData: [String: Any] = [
            "lastMessage": message.previewContent,
            "lastMessageType": message.type.rawValue,
            "lastMessageTime": message.timestamp,
            "lastMessageSenderId": currentUid
        ]
        
        let convDoc = try await db.collection("conversations").document(conversationId).getDocument()
        if let conv = try? convDoc.data(as: Conversation.self) {
            var unreadCounts = conv.unreadCounts
            for uid in conv.participantIds where uid != currentUid {
                unreadCounts[uid] = (unreadCounts[uid] ?? 0) + 1
            }
            updateData["unreadCounts"] = unreadCounts
        }
        
        try await db.collection("conversations").document(conversationId).updateData(updateData)
    }
    
    // MARK: - Mark as Read
    
    func markAsRead(conversationId: String, userId: String) {
        db.collection("conversations").document(conversationId).updateData([
            "unreadCounts.\(userId)": 0
        ])
        db.collection("conversations").document(conversationId)
            .collection("messages")
            .whereField("senderId", isNotEqualTo: userId)
            .getDocuments { snapshot, _ in
                snapshot?.documents.forEach { doc in
                    let status = doc.data()["status"] as? String ?? ""
                    if status != MessageStatus.read.rawValue {
                        doc.reference.updateData(["status": MessageStatus.read.rawValue])
                    }
                }
            }
    }
    
    // MARK: - Delete Message
    
    func deleteMessage(messageId: String, conversationId: String) {
        db.collection("conversations").document(conversationId)
            .collection("messages").document(messageId)
            .updateData([
                "isDeleted": true,
                "content": "",
                "base64Data": FieldValue.delete()
            ])
    }
    
    // MARK: - Typing
    
    func setTyping(_ isTyping: Bool, conversationId: String, userId: String) {
        let ref = db.collection("conversations").document(conversationId)
        if isTyping {
            ref.updateData(["typingInfo.\(userId)": Timestamp(date: Date())])
        } else {
            ref.updateData(["typingInfo.\(userId)": FieldValue.delete()])
        }
    }
    
    // MARK: - Delete Conversation (only for me)
    
    func deleteConversation(_ conversationId: String, for userId: String) async throws {
        let now = Timestamp(date: Date())
        
        try await db.collection("conversations").document(conversationId).updateData([
            "deletedFor.\(userId)": now
        ])
        
        listeners["msg_\(conversationId)"]?.remove()
        listeners["msg_\(conversationId)"] = nil
        listeners["conv_clear_\(conversationId)"]?.remove()
        listeners["conv_clear_\(conversationId)"] = nil
    }
    
    // MARK: - Delete All Conversations (when deleting account)
    
    func deleteAllConversations(for userId: String) async throws {
        let snapshot = try await db.collection("conversations")
            .whereField("participantIds", arrayContains: userId)
            .getDocuments()
        
        for convDoc in snapshot.documents {
            guard let conv = try? convDoc.data(as: Conversation.self) else { continue }
            
            let isOnlyParticipant = conv.participantIds.count == 1 ||
                conv.participantIds.allSatisfy { $0 == userId }
            
            if isOnlyParticipant {
                let messagesSnapshot = try await convDoc.reference.collection("messages").getDocuments()
                let batch = db.batch()
                messagesSnapshot.documents.forEach { batch.deleteDocument($0.reference) }
                batch.deleteDocument(convDoc.reference)
                try await batch.commit()
            } else {
                try await convDoc.reference.updateData([
                    "participantIds": FieldValue.arrayRemove([userId]),
                    "deletedFor.\(userId)": Timestamp(date: Date())
                ])
            }
        }
        
        listeners.forEach { $0.value.remove() }
        listeners.removeAll()
    }
}

// MARK: - MediaService.swift
import UIKit
import AVFoundation

enum AppError: Error, LocalizedError {
    case missingUser
    case imageTooLarge(Int)
    case audioTooLong(Double)
    case fileTooLarge(Int)
    case encodingFailed
    
    var errorDescription: String? {
        switch self {
        case .missingUser:
            return "User not found"
        case .imageTooLarge(let kb):
            return "Image is too large (\(kb) KB). Please select a smaller image."
        case .audioTooLong(let seconds):
            return "Audio is too long (\(Int(seconds))s). Maximum 60 seconds allowed."
        case .fileTooLarge(let kb):
            return "File is too large (\(kb) KB). Maximum 700 KB allowed."
        case .encodingFailed:
            return "Encoding failed"
        }
    }
}

class MediaService {
    static let shared = MediaService()
    
    static let maxImageKB   = 200
    static let maxAudioSecs = 60.0
    static let maxFileKB    = 700
    
    // MARK: - Image ↔ Base64
    
    func encodeImage(_ image: UIImage) throws -> String {
        let resized = resizeImage(image, maxDimension: 800)
        var quality: CGFloat = 0.7
        var data = resized.jpegData(compressionQuality: quality) ?? Data()
        
        while data.count > Self.maxImageKB * 1024 && quality > 0.1 {
            quality -= 0.1
            data = resized.jpegData(compressionQuality: quality) ?? Data()
        }
        guard data.count <= Self.maxImageKB * 1024 else {
            throw AppError.imageTooLarge(data.count / 1024)
        }
        return data.base64EncodedString()
    }
    
    func decodeImage(_ base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return UIImage(data: data)
    }
    
    // MARK: - Audio ↔ Base64
    
    func encodeAudio(url: URL, duration: Double) throws -> String {
        guard duration <= Self.maxAudioSecs else {
            throw AppError.audioTooLong(duration)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxFileKB * 1024 else {
            throw AppError.fileTooLarge(data.count / 1024)
        }
        return data.base64EncodedString()
    }
    
    func decodeAudioToTempFile(_ base64: String) -> URL? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        try? data.write(to: url)
        return url
    }
    
    // MARK: - File ↔ Base64
    
    func encodeFile(url: URL) throws -> (base64: String, name: String, size: Int64, mime: String) {
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxFileKB * 1024 else {
            throw AppError.fileTooLarge(data.count / 1024)
        }
        return (
            base64: data.base64EncodedString(),
            name:   url.lastPathComponent,
            size:   Int64(data.count),
            mime:   mimeType(for: url.pathExtension.lowercased())
        )
    }
    
    func decodeFileToTemp(_ base64: String, fileName: String) -> URL? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? data.write(to: url)
        return url
    }
    
    // MARK: - Profile image
    
    func encodeProfileImage(_ image: UIImage) -> String? {
        let resized = resizeImage(image, maxDimension: 300)
        guard let data = resized.jpegData(compressionQuality: 0.5),
              data.count <= 80 * 1024 else { return nil }
        return data.base64EncodedString()
    }
    
    // MARK: - Helpers
    
    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return image }
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
    
    private func mimeType(for ext: String) -> String {
        switch ext {
        case "pdf":         return "application/pdf"
        case "doc","docx":  return "application/msword"
        case "xls","xlsx":  return "application/vnd.ms-excel"
        case "txt":         return "text/plain"
        case "png":         return "image/png"
        case "jpg","jpeg":  return "image/jpeg"
        case "zip":         return "application/zip"
        default:            return "application/octet-stream"
        }
    }
}

// MARK: - AudioService.swift
import AVFoundation
import Combine

class AudioService: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    static let shared = AudioService()
    
    @Published var isRecording       = false
    @Published var isPlaying         = false
    @Published var recordingDuration: Double = 0
    @Published var playbackProgress:  Double = 0
    @Published var playingMessageId: String? = nil
    
    private var recorder:      AVAudioRecorder?
    private var player:        AVAudioPlayer?
    private var recordingURL:  URL?
    private var timer:         Timer?
    private var playbackTimer: Timer?
    
    override init() {
        super.init()
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    func startRecording() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey:            Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          22050,
            AVNumberOfChannelsKey:    1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey:      32000
        ]
        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.record()
        recordingURL      = url
        isRecording       = true
        recordingDuration = 0
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordingDuration += 0.1
            if self.recordingDuration >= MediaService.maxAudioSecs {
                self.timer?.invalidate()
            }
        }
    }
    
    func stopRecording() -> (url: URL, duration: Double)? {
        timer?.invalidate()
        recorder?.stop()
        isRecording = false
        guard let url = recordingURL, recordingDuration > 0.5 else { return nil }
        return (url, recordingDuration)
    }
    
    func cancelRecording() {
        timer?.invalidate()
        recorder?.stop()
        recorder?.deleteRecording()
        isRecording       = false
        recordingDuration = 0
    }
    
    func playFromBase64(_ base64: String, messageId: String) {
        if let url = MediaService.shared.decodeAudioToTempFile(base64) {
            playAudio(url: url, messageId: messageId)
        }
    }
    
    func playAudio(url: URL, messageId: String) {
        stopPlayback()
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            isPlaying        = true
            playingMessageId = messageId
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let p = self.player else { return }
                self.playbackProgress = p.currentTime / p.duration
            }
        } catch { print("Playback error: \(error)") }
    }
    
    func stopPlayback() {
        playbackTimer?.invalidate()
        player?.stop()
        isPlaying        = false
        playingMessageId = nil
        playbackProgress = 0
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying        = false
            self.playingMessageId = nil
            self.playbackProgress = 0
        }
    }
    
    func formattedDuration(_ duration: Double) -> String {
        String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60)
    }
}
