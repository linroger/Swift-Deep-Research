import SwiftUI
import MarkdownUI

struct ChatBubbleView: View {
    let message: ChatMessage
    @State private var isCopied = false
    
    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            // Role indicator
            HStack(spacing: 4) {
                if !message.isUser {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                    Text("Assistant")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("You")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Image(systemName: "person.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
            
            // Message bubble
            Group {
                if message.isStreaming && message.text.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 6, height: 6)
                                .opacity(0.5)
                                .animation(
                                    .easeInOut(duration: 0.5)
                                    .repeatForever()
                                    .delay(Double(i) * 0.15),
                                    value: message.isStreaming
                                )
                        }
                    }
                    .padding()
                    .background(bubbleBackground)
                    .cornerRadius(16)
                } else if message.isUser {
                    Text(message.text)
                        .padding(12)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(16, corners: [.topLeft, .topRight, .bottomLeft])
                        .textSelection(.enabled)
                } else {
                    Markdown(message.text)
                        .markdownTheme(.gitHub)
                        .padding(12)
                        .background(bubbleBackground)
                        .cornerRadius(16, corners: [.topLeft, .topRight, .bottomRight])
                        .textSelection(.enabled)
                }
            }
            .contextMenu {
                Button {
                    copyToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                
                if !message.isUser {
                    Button {
                        // Regenerate would be handled by view model
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
    
    private var bubbleBackground: Color {
        Color(NSColor.controlBackgroundColor)
    }
    
    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        isCopied = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}

// MARK: - Corner Radius Extension

extension View {
    func cornerRadius(_ radius: CGFloat, corners: NSRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: NSRectCorner
    
    func path(in rect: CGRect) -> Path {
        let path = NSBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: NSSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - NSBezierPath Extension

extension NSBezierPath {
    convenience init(roundedRect rect: CGRect, byRoundingCorners corners: NSRectCorner, cornerRadii: NSSize) {
        self.init()
        
        let topLeft = corners.contains(.topLeft) ? cornerRadii : .zero
        let topRight = corners.contains(.topRight) ? cornerRadii : .zero
        let bottomLeft = corners.contains(.bottomLeft) ? cornerRadii : .zero
        let bottomRight = corners.contains(.bottomRight) ? cornerRadii : .zero
        
        move(to: CGPoint(x: rect.minX + topLeft.width, y: rect.minY))
        
        // Top edge and top-right corner
        line(to: CGPoint(x: rect.maxX - topRight.width, y: rect.minY))
        if corners.contains(.topRight) {
            curve(to: CGPoint(x: rect.maxX, y: rect.minY + topRight.height),
                  controlPoint1: CGPoint(x: rect.maxX, y: rect.minY),
                  controlPoint2: CGPoint(x: rect.maxX, y: rect.minY))
        }
        
        // Right edge and bottom-right corner
        line(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight.height))
        if corners.contains(.bottomRight) {
            curve(to: CGPoint(x: rect.maxX - bottomRight.width, y: rect.maxY),
                  controlPoint1: CGPoint(x: rect.maxX, y: rect.maxY),
                  controlPoint2: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        
        // Bottom edge and bottom-left corner
        line(to: CGPoint(x: rect.minX + bottomLeft.width, y: rect.maxY))
        if corners.contains(.bottomLeft) {
            curve(to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft.height),
                  controlPoint1: CGPoint(x: rect.minX, y: rect.maxY),
                  controlPoint2: CGPoint(x: rect.minX, y: rect.maxY))
        }
        
        // Left edge and top-left corner
        line(to: CGPoint(x: rect.minX, y: rect.minY + topLeft.height))
        if corners.contains(.topLeft) {
            curve(to: CGPoint(x: rect.minX + topLeft.width, y: rect.minY),
                  controlPoint1: CGPoint(x: rect.minX, y: rect.minY),
                  controlPoint2: CGPoint(x: rect.minX, y: rect.minY))
        }
        
        close()
    }
    
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }
        
        return path
    }
}

// MARK: - NSRectCorner

struct NSRectCorner: OptionSet {
    let rawValue: Int
    
    static let topLeft = NSRectCorner(rawValue: 1 << 0)
    static let topRight = NSRectCorner(rawValue: 1 << 1)
    static let bottomLeft = NSRectCorner(rawValue: 1 << 2)
    static let bottomRight = NSRectCorner(rawValue: 1 << 3)
    static let allCorners: NSRectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

// MARK: - Preview

struct ChatBubbleView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            ChatBubbleView(message: ChatMessage(text: "Hello, how can I help you today?", isUser: false))
            ChatBubbleView(message: ChatMessage(text: "I want to research climate change impacts", isUser: true))
            ChatBubbleView(message: ChatMessage(text: "", isUser: false, isStreaming: true))
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
