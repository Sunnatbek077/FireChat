//
//  Models.swift
//  FireChat
//
//  Created by Sunnatbek on 26/02/26.
//

// MARK: - User.swift
import Foundation
import FirebaseFirestore

struct User: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var uid: String
    var name: String
    var phone: String
    var email: String
    
    // No Firebase Storage — image is stored as Base64 directly in Firestore
    var profileImageBase64: String?
    
    var status: String
    var isOnline: Bool
    var lastSeen: Timestamp
    
    init(uid: String, name: String, phone: String, email: String) {
        self.uid = uid
        self.name = name
        self.phone = phone
        self.email = email
        self.status = "Hey there! I am using FireChat"
        self.isOnline = true
        self.lastSeen = Timestamp(date: Date())
    }
    
    var lastSeenText: String {
        let date = lastSeen.dateValue()
        let formatter = DateFormatter()
        
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "today \(formatter.string(from: date))"
        } else if Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "HH:mm"
            return "yesterday \(formatter.string(from: date))"
        } else {
            formatter.dateFormat = "dd.MM.yyyy"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Message.swift

enum MessageType: String, Codable {
    case text
    case image
    case audio
    case file
}

enum MessageStatus: String, Codable {
    case sending
    case sent
    case delivered
    case read
}

struct Message: Identifiable, Codable {
    @DocumentID var id: String?
    var senderId: String
    var senderName: String
    
    // For text messages — plain text
    // For image/audio/file — "" (main data stored in base64Data)
    var content: String
    
    // Base64 data for image, audio, or file
    // (Be aware of Firestore document ≈ 1MB limit)
    var base64Data: String?
    
    var type: MessageType
    var status: MessageStatus
    var timestamp: Timestamp
    
    // File metadata
    var fileName: String?
    var fileSize: Int64?
    var fileMime: String?
    
    // Audio metadata
    var audioDuration: Double?
    
    // Reply metadata
    var replyToMessageId: String?
    var replyToContent: String?
    var replyToSenderName: String?
    
    var isDeleted: Bool
    
    init(senderId: String, senderName: String, content: String, type: MessageType) {
        self.senderId = senderId
        self.senderName = senderName
        self.content = content
        self.type = type
        self.status = .sending
        self.timestamp = Timestamp(date: Date())
        self.isDeleted = false
    }
    
    var isFromCurrentUser: Bool {
        senderId == AuthService.shared.currentUser?.uid
    }
    
    var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: timestamp.dateValue())
    }
    
    var formattedFileSize: String? {
        guard let size = fileSize else { return nil }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 {
            return String(format: "%.1f KB", Double(size) / 1024)
        }
        return String(format: "%.1f MB", Double(size) / 1_048_576)
    }
    
    /// Preview text for conversation list
    var previewContent: String {
        switch type {
        case .text:
            return content
        case .image:
            return "📷 Photo"
        case .audio:
            return "🎤 Voice message"
        case .file:
            return "📄 \(fileName ?? "File")"
        }
    }
}

// MARK: - Conversation.swift

struct Conversation: Identifiable, Codable, Hashable {
    @DocumentID var id: String?
    var participantIds: [String]
    var participantNames: [String: String]   // uid → name
    var lastMessage: String
    var lastMessageType: MessageType
    var lastMessageTime: Timestamp
    var lastMessageSenderId: String
    var unreadCounts: [String: Int]          // uid → unread count
    var isGroup: Bool
    var groupName: String?
    var createdAt: Timestamp
    
    // FIX: instead of typingUsers array, use timestamp dictionary —
    // automatically expires even if app crashes/force-quits (ignored after 5 seconds)
    var typingInfo: [String: Timestamp]      // uid → last typing time
    
    // Per-user "clear chat timestamp" [uid: Timestamp]
    // Messages before this time will not be shown for that user,
    // but conversation remains for the other participant
    var deletedFor: [String: Timestamp] = [:]
    
    func otherParticipantId(currentUserId: String) -> String? {
        participantIds.first { $0 != currentUserId }
    }
    
    /// Is the other user currently typing? (ignore if older than 5 seconds)
    func isOtherUserTyping(currentUserId: String) -> Bool {
        let cutoff = Date().addingTimeInterval(-5)
        return typingInfo.contains { uid, ts in
            uid != currentUserId && ts.dateValue() > cutoff
        }
    }
    
    func displayName(for userId: String) -> String {
        if isGroup { return groupName ?? "Group" }
        let otherId = otherParticipantId(currentUserId: userId)
        return participantNames[otherId ?? ""] ?? "Unknown"
    }
    
    func unreadCount(for userId: String) -> Int {
        unreadCounts[userId] ?? 0
    }
    
    /// Is this conversation visible for this user?
    func isVisible(for userId: String) -> Bool {
        // If no deletedFor[userId] — visible
        // If exists, but new message arrived after deletion — visible
        guard let deletedAt = deletedFor[userId] else { return true }
        return lastMessageTime.dateValue() > deletedAt.dateValue()
    }
    
    /// Used to filter messages after user's clear timestamp
    func clearTimestamp(for userId: String) -> Date? {
        deletedFor[userId]?.dateValue()
    }
    
    var lastMessagePreview: String {
        switch lastMessageType {
        case .text:
            return lastMessage
        case .image:
            return "📷 Photo"
        case .audio:
            return "🎤 Audio"
        case .file:
            return "📄 File"
        }
    }
    
    var formattedTime: String {
        let date = lastMessageTime.dateValue()
        let f = DateFormatter()
        
        if Calendar.current.isDateInToday(date) {
            f.dateFormat = "HH:mm"
        } else if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            f.dateFormat = "dd.MM.yy"
        }
        return f.string(from: date)
    }
    
    // Hashable conformance for NavigationStack
    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        // Prefer comparing by Firestore document id when available
        if let lid = lhs.id, let rid = rhs.id {
            return lid == rid
        }
        
        // Fallback for newly created unsaved instances
        return lhs.participantIds.sorted() == rhs.participantIds.sorted()
            && lhs.createdAt == rhs.createdAt
    }
    
    func hash(into hasher: inout Hasher) {
        if let id = id {
            hasher.combine(id)
        } else {
            hasher.combine(participantIds.sorted())
            hasher.combine(createdAt.seconds)
            hasher.combine(createdAt.nanoseconds)
        }
    }
}
