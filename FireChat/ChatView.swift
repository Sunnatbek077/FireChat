//
//  ChatView.swift
//  FireChat
//
//  Created by Sunnatbek on 25/02/26.
//

// MARK: - ChatView.swift
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    let conversationId: String
    let displayName: String
    
    @StateObject private var vm: ChatViewModel
    @StateObject private var audioService = AudioService.shared
    @State private var showDeleteChatAlert = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    
    init(conversationId: String, displayName: String) {
        self.conversationId = conversationId
        self.displayName = displayName
        _vm = StateObject(wrappedValue: ChatViewModel(conversationId: conversationId))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // ---- Messages ----
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.groupedMessages, id: \.date) { group in
                            DateSeparatorView(text: group.date)
                            ForEach(group.messages) { message in
                                MessageBubble(message: message, audioService: audioService)
                                    .id(message.id)
                                    .contextMenu { contextMenuItems(for: message) }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: vm.messages.count) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(vm.messages.last?.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: vm.messages.last?.id) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(vm.messages.last?.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo(vm.messages.last?.id, anchor: .bottom)
                    }
                }
            }
            
            // ---- Processing indicator ----
            if vm.isProcessing {
                HStack(spacing: 10) {
                    ProgressView().tint(.green)
                    Text("Yuborilmoqda...").font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
            }
            
            // ---- Reply preview ----
            if let reply = vm.replyToMessage {
                ReplyPreviewView(message: reply) { vm.replyToMessage = nil }
            }
            
            // ---- Input bar ----
            ChatInputBar(
                text: $vm.inputText,
                onSendText:  vm.sendText,
                onSendImage: vm.sendImage,
                onSendAudio: vm.sendAudio,
                onSendFile:  vm.sendFile,
                onTyping:    vm.userIsTyping
            )
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    AvatarView(base64: nil, name: displayName, size: 36)
                    Text(displayName).font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {} label: { Label("Video qo'ng'iroq", systemImage: "video.fill") }
                    Button {} label: { Label("Ovozli qo'ng'iroq", systemImage: "phone.fill") }
                    Divider()
                    Button(role: .destructive) {
                        showDeleteChatAlert = true
                    } label: {
                        Label("Chatni o'chirish", systemImage: "trash.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundColor(.green)
                }
            }
        }
        .alert("Chatni o'chirish", isPresented: $showDeleteChatAlert) {
            Button("O'chirish", role: .destructive) {
                vm.deleteConversation { dismiss() }
            }
            Button("Bekor", role: .cancel) {}
        } message: {
            Text("Bu chat va barcha xabarlar o'chiriladi. Bu amalni qaytarib bo'lmaydi.")
        }
        .alert("Xato", isPresented: .init(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        // ✅ TUZATISH: Chat ochilganda isChatActive = true
        // Shunda yangi xabar kelsa darhol markAsRead ishlaydi
        .onAppear {
            vm.isChatActive = true
            vm.markAsRead()
        }
        // ✅ TUZATISH: Chat yopilganda isChatActive = false
        // Fon rejimida keraksiz markAsRead chaqirilmaydi
        .onDisappear {
            vm.isChatActive = false
            vm.stopTyping()
        }
        // App background ga tushganda ham isChatActive = false
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                vm.isChatActive = true
                vm.markAsRead()
            } else {
                vm.isChatActive = false
                vm.stopTyping()
            }
        }
    }
    
    @ViewBuilder
    func contextMenuItems(for message: Message) -> some View {
        if !message.isDeleted {
            Button {
                vm.replyToMessage = message
            } label: {
                Label("Javob berish", systemImage: "arrowshape.turn.up.left")
            }
            if message.type == .text {
                Button {
                    UIPasteboard.general.string = message.content
                } label: {
                    Label("Nusxa olish", systemImage: "doc.on.doc")
                }
            }
            if message.isFromCurrentUser {
                Divider()
                Button(role: .destructive) {
                    vm.deleteMessage(message)
                } label: {
                    Label("O'chirish", systemImage: "trash")
                }
            }
        }
    }
}

struct DateSeparatorView: View {
    let text: String
    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color(.systemGray5).opacity(0.8))
                .cornerRadius(10)
            Spacer()
        }.padding(.vertical, 8)
    }
}

struct ReplyPreviewView: View {
    let message: Message
    let onDismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color.green).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.senderName).font(.caption.bold()).foregroundColor(.green)
                Text(message.isDeleted ? "Xabar o'chirildi" : message.previewContent)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(.systemGray6))
    }
}

// MARK: - MessageBubble.swift

struct MessageBubble: View {
    let message: Message
    @ObservedObject var audioService: AudioService
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if message.isFromCurrentUser { Spacer(minLength: 60) }
            
            Group {
                if message.isDeleted {
                    DeletedBubble()
                } else {
                    switch message.type {
                    case .text:  TextBubble(message: message)
                    case .image: ImageBubble(message: message)
                    case .audio: AudioMessageView(message: message, audioService: audioService)
                    case .file:  FileMessageView(message: message)
                    }
                }
            }
            
            if !message.isFromCurrentUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
    }
}

// MARK: - TextBubble

struct TextBubble: View {
    let message: Message
    
    var bubbleColor: Color { message.isFromCurrentUser ? .green.opacity(0.85) : Color(.systemGray5) }
    var textColor:   Color { message.isFromCurrentUser ? .white : .primary }
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let name = message.replyToSenderName, let content = message.replyToContent {
                ReplyBubble(senderName: name, content: content, isFromCurrentUser: message.isFromCurrentUser)
            }
            Text(message.content).font(.system(size: 16)).foregroundColor(textColor)
            HStack(spacing: 4) {
                Text(message.formattedTime)
                    .font(.system(size: 11))
                    .foregroundColor(message.isFromCurrentUser ? .white.opacity(0.7) : .secondary)
                if message.isFromCurrentUser { MessageStatusIcon(status: message.status) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(bubbleColor)
        .cornerRadius(18, corners: message.isFromCurrentUser
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight])
    }
}

// MARK: - ImageBubble

struct ImageBubble: View {
    let message: Message
    @State private var showFull = false
    
    var uiImage: UIImage? {
        guard let b64 = message.base64Data else { return nil }
        return MediaService.shared.decodeImage(b64)
    }
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 220, height: 180)
                    .clipped()
                    .cornerRadius(16)
                    .onTapGesture { showFull = true }
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 220, height: 180)
                    .overlay(Image(systemName: "photo").foregroundColor(.gray))
            }
            HStack(spacing: 4) {
                Text(message.formattedTime)
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if message.isFromCurrentUser { MessageStatusIcon(status: message.status) }
            }.padding(.horizontal, 4)
        }
        .sheet(isPresented: $showFull) {
            if let img = uiImage { FullScreenImageView(image: img) }
        }
    }
}

struct FullScreenImageView: View {
    let image: UIImage
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Image(uiImage: image).resizable().scaledToFit()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                }
        }
    }
}

// MARK: - AudioMessageView

struct AudioMessageView: View {
    let message: Message
    @ObservedObject var audioService: AudioService
    
    var isPlaying: Bool { audioService.playingMessageId == message.id }
    var isFromMe:  Bool { message.isFromCurrentUser }
    
    var body: some View {
        HStack(spacing: 12) {
            Button { togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(isFromMe ? Color.white.opacity(0.2) : Color.green.opacity(0.15))
                        .frame(width: 42, height: 42)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(isFromMe ? .white : .green)
                        .font(.system(size: 16))
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                WaveformView(progress: isPlaying ? audioService.playbackProgress : 0,
                             isFromMe: isFromMe)
                    .frame(height: 28)
                
                HStack {
                    let totalDuration = message.audioDuration ?? 0
                    let shown = isPlaying
                        ? audioService.playbackProgress * totalDuration
                        : totalDuration
                    Text(audioService.formattedDuration(shown))
                        .font(.system(size: 11))
                        .foregroundColor(isFromMe ? .white.opacity(0.7) : .secondary)
                    Spacer()
                    Text(message.formattedTime)
                        .font(.system(size: 11))
                        .foregroundColor(isFromMe ? .white.opacity(0.7) : .secondary)
                    if isFromMe { MessageStatusIcon(status: message.status) }
                }
            }
        }
        .padding(12).frame(width: 240)
        .background(isFromMe ? Color.green.opacity(0.85) : Color(.systemGray5))
        .cornerRadius(18, corners: isFromMe
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight])
    }
    
    func togglePlayback() {
        if isPlaying {
            audioService.stopPlayback()
        } else if let b64 = message.base64Data {
            audioService.playFromBase64(b64, messageId: message.id ?? "")
        }
    }
}

struct WaveformView: View {
    let progress: Double
    let isFromMe: Bool
    private let bars = 28
    private let heights: [CGFloat] = [0.3,0.5,0.8,0.6,1.0,0.4,0.7,0.9,0.5,0.3,0.6,0.8,0.4,0.7]
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let p = Double(i) / Double(bars)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(p <= progress
                              ? (isFromMe ? Color.white : Color.green)
                              : (isFromMe ? Color.white.opacity(0.35) : Color.gray.opacity(0.35)))
                        .frame(
                            width: (geo.size.width - CGFloat(bars-1)*2) / CGFloat(bars),
                            height: geo.size.height * heights[i % heights.count]
                        )
                }
            }
        }
    }
}

// MARK: - FileMessageView

struct FileMessageView: View {
    let message: Message
    
    var fileIcon: String {
        switch (message.fileName ?? "").split(separator: ".").last?.lowercased() ?? "" {
        case "pdf":        return "doc.fill"
        case "doc","docx": return "doc.text.fill"
        case "xls","xlsx": return "tablecells.fill"
        case "zip","rar":  return "archivebox.fill"
        case "txt":        return "text.alignleft"
        default:           return "doc.fill"
        }
    }
    var iconColor: Color {
        switch (message.fileName ?? "").split(separator: ".").last?.lowercased() ?? "" {
        case "pdf":        return .red
        case "doc","docx": return .blue
        case "xls","xlsx": return .green
        default:           return .orange
        }
    }
    
    var isFromMe: Bool { message.isFromCurrentUser }
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFromMe ? Color.white.opacity(0.2) : Color.green.opacity(0.1))
                    .frame(width: 48, height: 48)
                Image(systemName: fileIcon)
                    .foregroundColor(isFromMe ? .white : iconColor)
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.fileName ?? "File")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isFromMe ? .white : .primary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let s = message.formattedFileSize {
                        Text(s).font(.caption)
                            .foregroundColor(isFromMe ? .white.opacity(0.7) : .secondary)
                    }
                    Text(message.formattedTime).font(.caption)
                        .foregroundColor(isFromMe ? .white.opacity(0.7) : .secondary)
                }
            }
            Spacer()
            Button { openFile() } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(isFromMe ? .white.opacity(0.8) : .green)
                    .font(.title2)
            }
        }
        .padding(12).frame(maxWidth: 280)
        .background(isFromMe ? Color.green.opacity(0.85) : Color(.systemGray5))
        .cornerRadius(16)
    }
    
    func openFile() {
        guard let b64 = message.base64Data,
              let url = MediaService.shared.decodeFileToTemp(b64, fileName: message.fileName ?? "file") else { return }
        let dc = UIDocumentInteractionController(url: url)
        if let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first?.windows.first?.rootViewController {
            dc.presentPreview(animated: true)
            _ = dc.presentOpenInMenu(from: .zero, in: rootVC.view, animated: true)
        }
    }
}

// MARK: - DeletedBubble

struct DeletedBubble: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "slash.circle").foregroundColor(.secondary).font(.footnote)
            Text("This message was deleted").italic().foregroundColor(.secondary).font(.system(size: 14))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.systemGray5).opacity(0.5))
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(.systemGray4), lineWidth: 1))
    }
}

struct ReplyBubble: View {
    let senderName: String
    let content: String
    let isFromCurrentUser: Bool
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(isFromCurrentUser ? Color.white.opacity(0.6) : Color.green)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(senderName).font(.caption.bold())
                    .foregroundColor(isFromCurrentUser ? .white.opacity(0.9) : .green)
                Text(content).font(.caption)
                    .foregroundColor(isFromCurrentUser ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background((isFromCurrentUser ? Color.white : Color.green).opacity(0.15))
        .cornerRadius(8)
    }
}

// MARK: - ChatInputBar.swift

struct ChatInputBar: View {
    @Binding var text: String
    let onSendText:  () -> Void
    let onSendImage: (UIImage) -> Void
    let onSendAudio: (URL, Double) -> Void
    let onSendFile:  (URL) -> Void
    let onTyping:    () -> Void
    
    @StateObject private var audioService = AudioService.shared
    @State private var showAttachMenu = false
    @State private var selectedPhoto: PhotosPickerItem? = nil
    @State private var showDocPicker = false
    @State private var isHoldingRecord = false
    @State private var isCancelling    = false
    
    var canSend: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                Button { showAttachMenu = true } label: {
                    Image(systemName: "paperclip")
                        .font(.title3).foregroundColor(.secondary)
                        .frame(width: 36, height: 36)
                }
                .confirmationDialog("Send item", isPresented: $showAttachMenu) {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("Gallery (max 200KB)", systemImage: "photo")
                    }
                    Button("File (max 700KB)") { showDocPicker = true }
                    Button("Cancel", role: .cancel) {}
                }
                
                if audioService.isRecording {
                    RecordingIndicator(duration: audioService.recordingDuration, isCancelling: isCancelling)
                } else {
                    TextField("Message...", text: $text, axis: .vertical)
                        .lineLimit(5)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.systemGray6)).cornerRadius(22)
                        .onChange(of: text) { _ in onTyping() }
                }
                
                if canSend {
                    Button(action: onSendText) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.white).font(.system(size: 16, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.green).clipShape(Circle())
                    }
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: audioService.isRecording ? "waveform" : "mic.fill")
                        .foregroundColor(audioService.isRecording ? .red : .secondary)
                        .font(.title3).frame(width: 36, height: 36)
                        .scaleEffect(isHoldingRecord ? 1.25 : 1.0)
                        .animation(.spring(response: 0.25), value: isHoldingRecord)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    if !audioService.isRecording { startRecording() }
                                    isHoldingRecord = true
                                    isCancelling = v.translation.width < -50
                                }
                                .onEnded { v in
                                    isHoldingRecord = false; isCancelling = false
                                    if v.translation.width < -50 { cancelRecording() }
                                    else { stopRecording() }
                                }
                        )
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .animation(.spring(response: 0.25), value: canSend)
        }
        .background(Color(.systemBackground))
        .onChange(of: selectedPhoto) { item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    onSendImage(img)
                }
            }
        }
        .sheet(isPresented: $showDocPicker) {
            DocumentPickerView { url in onSendFile(url) }
        }
    }
    
    func startRecording() {
        try? audioService.startRecording()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    func stopRecording() {
        if let result = audioService.stopRecording() {
            onSendAudio(result.url, result.duration)
        }
    }
    func cancelRecording() {
        audioService.cancelRecording()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

struct RecordingIndicator: View {
    let duration: Double
    let isCancelling: Bool
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(isCancelling ? Color.gray : Color.red)
                .frame(width: 10, height: 10)
                .opacity(duration.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: duration)
            Text(String(format: "%02d:%02d", Int(duration)/60, Int(duration)%60))
                .font(.system(size: 16, weight: .medium)).monospacedDigit()
                .foregroundColor(isCancelling ? .secondary : .primary)
            Spacer()
            Text(isCancelling ? "< Cancel" : "< Swipe left: Cancel")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(.systemGray6)).cornerRadius(22)
    }
}

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.pdf, .spreadsheet, .presentation, .text, .data, .archive]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: temp)
            onPick(temp)
        }
    }
}

// MARK: - Corner radius helper
import UIKit

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}
struct RoundedCorner: Shape {
    var radius: CGFloat; var corners: UIRectCorner
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(
            roundedRect: rect, byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        ).cgPath)
    }
}
